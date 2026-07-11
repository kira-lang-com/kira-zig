//! LLVM type and runtime-declaration scaffolding for the C-API backend: the cached
//! primitive/aggregate `Types` for a module context, and the `RuntimeDecls` set of
//! runtime helper function declarations every Kira module references. Extracted
//! from `backend_capi.zig` to keep that file under the Core Law #5 size limit; the
//! public surface is re-exported there as `capi.Types` / `capi.RuntimeDecls`.

const std = @import("std");
const ir = @import("kira_ir");
const backend_api = @import("kira_backend_api");
const llvm = @import("llvm_c.zig");
const runtime_symbols = @import("runtime_symbols.zig");

pub const Types = struct {
    api: *const llvm.Api,
    context: llvm.c.LLVMContextRef,
    bool_ty: llvm.c.LLVMTypeRef,
    i8: llvm.c.LLVMTypeRef,
    i16: llvm.c.LLVMTypeRef,
    i32: llvm.c.LLVMTypeRef,
    i64: llvm.c.LLVMTypeRef,
    // The C ABI's pointer-sized integer (`size_t` / `uintptr_t`) for the TARGET.
    // 64-bit on all native targets; 32-bit on wasm32 (emscripten), where a `ptr`
    // and `size_t` are 32-bit. Every C-boundary size/pointer-width parameter of a
    // libc or Kira runtime helper (malloc, memcpy, memcmp, strlen, kira_struct_alloc,
    // ...) must use this width, or the emitted call signature disagrees with the
    // wasm32 libc and wasm-ld traps with a `function signature mismatch`. Kira's
    // internal `Int`/pointer registers stay i64 regardless (see `llvmType`); this
    // type is ONLY for declaring/calling the C boundary.
    usize_ty: llvm.c.LLVMTypeRef,
    double_ty: llvm.c.LLVMTypeRef,
    float_ty: llvm.c.LLVMTypeRef,
    void_ty: llvm.c.LLVMTypeRef,
    ptr_ty: llvm.c.LLVMTypeRef,
    string_ty: llvm.c.LLVMTypeRef,
    bridge_ty: llvm.c.LLVMTypeRef,

    pub fn init(api: *const llvm.Api, context: llvm.c.LLVMContextRef, triple: []const u8) Types {
        const ptr_ty = api.LLVMPointerTypeInContext(context, 0);
        const i64_ty = api.LLVMInt64TypeInContext(context);
        const i8_ty = api.LLVMInt8TypeInContext(context);
        // wasm32-* targets have 32-bit pointers/size_t; everything else here is 64-bit.
        const usize_ty = if (std.mem.startsWith(u8, triple, "wasm32"))
            api.LLVMInt32TypeInContext(context)
        else
            i64_ty;
        var string_fields = [_]llvm.c.LLVMTypeRef{ ptr_ty, i64_ty };
        // Matches the runtime KiraBridgeValue: { tag:i8, pad:[7 x i8], payload:i64, extra:i64 }.
        var bridge_fields = [_]llvm.c.LLVMTypeRef{ i8_ty, api.LLVMArrayType2(i8_ty, 7), i64_ty, i64_ty };
        return .{
            .api = api,
            .context = context,
            .bool_ty = api.LLVMInt1TypeInContext(context),
            .i8 = i8_ty,
            .i16 = api.LLVMInt16TypeInContext(context),
            .i32 = api.LLVMInt32TypeInContext(context),
            .i64 = i64_ty,
            .usize_ty = usize_ty,
            .double_ty = api.LLVMDoubleTypeInContext(context),
            .float_ty = api.LLVMFloatTypeInContext(context),
            .void_ty = api.LLVMVoidTypeInContext(context),
            .ptr_ty = ptr_ty,
            .string_ty = api.LLVMStructTypeInContext(context, &string_fields, string_fields.len, 0),
            .bridge_ty = api.LLVMStructTypeInContext(context, &bridge_fields, bridge_fields.len, 0),
        };
    }

    // Mirrors backend_utils.llvmValueTypeText: Kira `Float` is 64-bit (double);
    // only the F32 named float is 32-bit. Pointers and aggregates are carried as
    // i64 in the register ABI, matching the text backend so cross-backend calls
    // and the runtime helpers stay binary-compatible.
    pub fn llvmType(self: Types, value_type: ir.ValueType) llvm.c.LLVMTypeRef {
        return switch (value_type.kind) {
            .void => self.void_ty,
            .integer => self.i64,
            .float => if (value_type.name != null and std.mem.eql(u8, value_type.name.?, "F32")) self.float_ty else self.double_ty,
            .string => self.string_ty,
            .boolean => self.bool_ty,
            .construct_any, .array, .raw_ptr, .ffi_struct, .enum_instance => self.i64,
        };
    }

    pub fn functionType(self: Types, allocator: std.mem.Allocator, function_decl: ir.Function) !llvm.c.LLVMTypeRef {
        const params = try allocator.alloc(llvm.c.LLVMTypeRef, function_decl.param_types.len);
        defer allocator.free(params);
        for (function_decl.param_types, 0..) |param_type, index| params[index] = self.llvmType(param_type);
        const ret = self.llvmType(function_decl.return_type);
        return self.api.LLVMFunctionType(ret, params.ptr, @intCast(params.len), 0);
    }

    // Narrow a Kira i64-register size/pointer value to the C ABI's `usize` width
    // for passing as a `size_t`/`uintptr_t` argument. Identity on 64-bit targets
    // (usize_ty aliases i64, so the same TypeRef — no instruction emitted); a
    // truncation to i32 on wasm32. The value is always a real byte count or a
    // 32-bit-representable pointer here, so the high bits dropped are zero.
    pub fn sizeArg(self: Types, b: llvm.c.LLVMBuilderRef, value: llvm.c.LLVMValueRef) llvm.c.LLVMValueRef {
        if (self.usize_ty == self.i64) return value;
        return self.api.LLVMBuildTrunc(b, value, self.usize_ty, "cabi.usize");
    }

    // Widen a C ABI `usize`-typed return (e.g. strlen's `size_t`) back to Kira's
    // i64 register width. Identity on 64-bit; a zero-extend on wasm32.
    pub fn sizeRet(self: Types, b: llvm.c.LLVMBuilderRef, value: llvm.c.LLVMValueRef) llvm.c.LLVMValueRef {
        if (self.usize_ty == self.i64) return value;
        return self.api.LLVMBuildZExt(b, value, self.i64, "cabi.usize.ret");
    }
};

pub const RuntimeDecls = struct {
    print_i64: Decl,
    print_f64: Decl,
    print_string: Decl,
    call_runtime: ?Decl,
    malloc: Decl,
    free: Decl,
    strlen: Decl,
    memcpy: Decl,
    memcmp: Decl,
    array_alloc: Decl,
    array_len: Decl,
    array_load: Decl,
    array_take: Decl,
    array_store: Decl,
    array_store_release: Decl,
    array_append: Decl,
    array_release: Decl,
    array_clone: Decl,
    state_alloc: Decl,
    state_payload: Decl,
    state_recover: Decl,
    state_free: Decl,
    struct_alloc: Decl,
    struct_type_id: Decl,
    struct_free: Decl,
    // No-newline writers for composing aggregate (struct/enum/array) output.
    write_i64: Decl,
    write_f64: Decl,
    write_string: Decl,
    write_ptr: Decl,
    write_newline: Decl,
    bool_true: llvm.c.LLVMValueRef,
    bool_false: llvm.c.LLVMValueRef,

    pub const Decl = struct { ty: llvm.c.LLVMTypeRef, fn_value: llvm.c.LLVMValueRef };

    pub fn declare(api: *const llvm.Api, module_ref: llvm.c.LLVMModuleRef, types: Types, mode: backend_api.BackendMode) RuntimeDecls {
        var i64_args = [_]llvm.c.LLVMTypeRef{types.i64};
        const print_i64_ty = api.LLVMFunctionType(types.void_ty, &i64_args, i64_args.len, 0);
        var f64_args = [_]llvm.c.LLVMTypeRef{types.double_ty};
        const print_f64_ty = api.LLVMFunctionType(types.void_ty, &f64_args, f64_args.len, 0);
        var str_args = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.i64 };
        const print_string_ty = api.LLVMFunctionType(types.void_ty, &str_args, str_args.len, 0);
        // kira_hybrid_call_runtime(i32 function_id, ptr args, i32 arg_count, ptr result)
        var rt_args = [_]llvm.c.LLVMTypeRef{ types.i32, types.ptr_ty, types.i32, types.ptr_ty };
        const call_runtime_ty = if (mode == .hybrid) api.LLVMFunctionType(types.void_ty, &rt_args, rt_args.len, 0) else null;
        // libc/runtime helpers whose C prototypes use size_t/uintptr_t take the
        // TARGET's pointer-width integer (i32 on wasm32, i64 elsewhere). Kira's own
        // register values stay i64 and are narrowed at each call site via
        // Types.sizeArg (identity on 64-bit).
        var malloc_args = [_]llvm.c.LLVMTypeRef{types.usize_ty};
        const malloc_ty = api.LLVMFunctionType(types.ptr_ty, &malloc_args, malloc_args.len, 0);
        var free_args = [_]llvm.c.LLVMTypeRef{types.ptr_ty};
        const free_ty = api.LLVMFunctionType(types.void_ty, &free_args, free_args.len, 0);
        var strlen_args = [_]llvm.c.LLVMTypeRef{types.ptr_ty};
        const strlen_ty = api.LLVMFunctionType(types.usize_ty, &strlen_args, strlen_args.len, 0);
        var memcpy_args = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.ptr_ty, types.usize_ty };
        const memcpy_ty = api.LLVMFunctionType(types.ptr_ty, &memcpy_args, memcpy_args.len, 0);
        var memcmp_args = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.ptr_ty, types.usize_ty };
        const memcmp_ty = api.LLVMFunctionType(types.i32, &memcmp_args, memcmp_args.len, 0);
        var alloc_args = [_]llvm.c.LLVMTypeRef{types.i64};
        const array_alloc_ty = api.LLVMFunctionType(types.ptr_ty, &alloc_args, alloc_args.len, 0);
        var len_args = [_]llvm.c.LLVMTypeRef{types.ptr_ty};
        const array_len_ty = api.LLVMFunctionType(types.i64, &len_args, len_args.len, 0);
        var load_args = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.i64, types.ptr_ty };
        const array_load_ty = api.LLVMFunctionType(types.void_ty, &load_args, load_args.len, 0);
        var store_args = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.i64, types.ptr_ty };
        const array_store_ty = api.LLVMFunctionType(types.void_ty, &store_args, store_args.len, 0);
        var store_release_args = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.i64, types.ptr_ty, types.ptr_ty };
        const array_store_release_ty = api.LLVMFunctionType(types.void_ty, &store_release_args, store_release_args.len, 0);
        var append_args = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.ptr_ty };
        const array_append_ty = api.LLVMFunctionType(types.void_ty, &append_args, append_args.len, 0);
        var release_args = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.ptr_ty };
        const array_release_ty = api.LLVMFunctionType(types.void_ty, &release_args, release_args.len, 0);
        var clone_args = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.ptr_ty };
        const array_clone_ty = api.LLVMFunctionType(types.ptr_ty, &clone_args, clone_args.len, 0);
        var state_alloc_args = [_]llvm.c.LLVMTypeRef{ types.i64, types.i64 };
        const state_alloc_ty = api.LLVMFunctionType(types.ptr_ty, &state_alloc_args, state_alloc_args.len, 0);
        var state_payload_args = [_]llvm.c.LLVMTypeRef{types.ptr_ty};
        const state_payload_ty = api.LLVMFunctionType(types.ptr_ty, &state_payload_args, state_payload_args.len, 0);
        var state_recover_args = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.i64 };
        const state_recover_ty = api.LLVMFunctionType(types.ptr_ty, &state_recover_args, state_recover_args.len, 0);
        var state_free_args = [_]llvm.c.LLVMTypeRef{types.ptr_ty};
        const state_free_ty = api.LLVMFunctionType(types.void_ty, &state_free_args, state_free_args.len, 0);
        // kira_struct_alloc(uint64_t type_id, size_t size): type_id is a Kira 64-bit
        // domain value, size is a C size_t (target width).
        var struct_alloc_args = [_]llvm.c.LLVMTypeRef{ types.i64, types.usize_ty };
        const struct_alloc_ty = api.LLVMFunctionType(types.ptr_ty, &struct_alloc_args, struct_alloc_args.len, 0);
        var struct_type_id_args = [_]llvm.c.LLVMTypeRef{types.ptr_ty};
        const struct_type_id_ty = api.LLVMFunctionType(types.i64, &struct_type_id_args, struct_type_id_args.len, 0);
        const struct_free_ty = api.LLVMFunctionType(types.void_ty, &struct_type_id_args, struct_type_id_args.len, 0);
        const write_newline_ty = api.LLVMFunctionType(types.void_ty, null, 0, 0);

        return .{
            .print_i64 = .{ .ty = print_i64_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.print_i64, print_i64_ty) },
            .print_f64 = .{ .ty = print_f64_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.print_f64, print_f64_ty) },
            .print_string = .{ .ty = print_string_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.print_string, print_string_ty) },
            .call_runtime = if (call_runtime_ty) |ty| .{ .ty = ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.call_runtime, ty) } else null,
            .malloc = .{ .ty = malloc_ty, .fn_value = api.LLVMAddFunction(module_ref, "malloc", malloc_ty) },
            .free = .{ .ty = free_ty, .fn_value = api.LLVMAddFunction(module_ref, "free", free_ty) },
            .strlen = .{ .ty = strlen_ty, .fn_value = api.LLVMAddFunction(module_ref, "strlen", strlen_ty) },
            .memcpy = .{ .ty = memcpy_ty, .fn_value = api.LLVMAddFunction(module_ref, "memcpy", memcpy_ty) },
            .memcmp = .{ .ty = memcmp_ty, .fn_value = api.LLVMAddFunction(module_ref, "memcmp", memcmp_ty) },
            .array_alloc = .{ .ty = array_alloc_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.array_alloc, array_alloc_ty) },
            .array_len = .{ .ty = array_len_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.array_len, array_len_ty) },
            .array_load = .{ .ty = array_load_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.array_load, array_load_ty) },
            .array_take = .{ .ty = array_load_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.array_take, array_load_ty) },
            .array_store = .{ .ty = array_store_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.array_store, array_store_ty) },
            .array_store_release = .{ .ty = array_store_release_ty, .fn_value = api.LLVMAddFunction(module_ref, "kira_array_store_release", array_store_release_ty) },
            .array_append = .{ .ty = array_append_ty, .fn_value = api.LLVMAddFunction(module_ref, "kira_array_append", array_append_ty) },
            .array_release = .{ .ty = array_release_ty, .fn_value = api.LLVMAddFunction(module_ref, "kira_array_release", array_release_ty) },
            .array_clone = .{ .ty = array_clone_ty, .fn_value = api.LLVMAddFunction(module_ref, "kira_array_clone", array_clone_ty) },
            .state_alloc = .{ .ty = state_alloc_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.native_state_alloc, state_alloc_ty) },
            .state_payload = .{ .ty = state_payload_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.native_state_payload, state_payload_ty) },
            .state_recover = .{ .ty = state_recover_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.native_state_recover, state_recover_ty) },
            .state_free = .{ .ty = state_free_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.native_state_free, state_free_ty) },
            .struct_alloc = .{ .ty = struct_alloc_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.struct_alloc, struct_alloc_ty) },
            .struct_type_id = .{ .ty = struct_type_id_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.struct_type_id, struct_type_id_ty) },
            .struct_free = .{ .ty = struct_free_ty, .fn_value = api.LLVMAddFunction(module_ref, runtime_symbols.struct_free, struct_free_ty) },
            .write_i64 = .{ .ty = print_i64_ty, .fn_value = api.LLVMAddFunction(module_ref, "kira_native_write_i64", print_i64_ty) },
            .write_f64 = .{ .ty = print_f64_ty, .fn_value = api.LLVMAddFunction(module_ref, "kira_native_write_f64", print_f64_ty) },
            .write_string = .{ .ty = print_string_ty, .fn_value = api.LLVMAddFunction(module_ref, "kira_native_write_string", print_string_ty) },
            .write_ptr = .{ .ty = print_i64_ty, .fn_value = api.LLVMAddFunction(module_ref, "kira_native_write_ptr", print_i64_ty) },
            .write_newline = .{ .ty = write_newline_ty, .fn_value = api.LLVMAddFunction(module_ref, "kira_native_write_newline", write_newline_ty) },
            .bool_true = boolGlobal(api, module_ref, types, "true", "kira.capi.bool.true"),
            .bool_false = boolGlobal(api, module_ref, types, "false", "kira.capi.bool.false"),
        };
    }
};

fn boolGlobal(api: *const llvm.Api, module_ref: llvm.c.LLVMModuleRef, types: Types, text: []const u8, name: [:0]const u8) llvm.c.LLVMValueRef {
    const array_ty = api.LLVMArrayType2(types.i8, text.len + 1);
    const global = api.LLVMAddGlobal(module_ref, array_ty, name.ptr);
    api.LLVMSetLinkage(global, llvm.c.LLVMPrivateLinkage);
    api.LLVMSetGlobalConstant(global, 1);
    api.LLVMSetInitializer(global, api.LLVMConstStringInContext2(types.context, text.ptr, text.len, 0));
    const zero = api.LLVMConstInt(types.i32, 0, 0);
    var indices = [_]llvm.c.LLVMValueRef{ zero, zero };
    const data_ptr = api.LLVMConstInBoundsGEP2(array_ty, global, &indices, indices.len);
    var fields = [_]llvm.c.LLVMValueRef{ data_ptr, api.LLVMConstInt(types.i64, text.len, 0) };
    return api.LLVMConstNamedStruct(types.string_ty, &fields, fields.len);
}
