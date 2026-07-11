//! wasm32 C-ABI adapter thunks for user `@Native` functions handed to C as
//! callback function pointers — the FFI-struct callback fields a Kira program
//! fills in and passes across the boundary (sokol's `sapp_desc` init/frame/
//! event/cleanup callbacks and its logger func, libc `qsort` comparators, any
//! C API that calls back into Kira through a stored function pointer).
//!
//! A Kira function is emitted with the i64 register ABI (backend_capi_types
//! `llvmType`): every integer AND pointer parameter is an `i64`, regardless of
//! target. On 64-bit targets a C `void *` / `uint32_t` and an `i64` reduce to
//! the same call value type once the C side widens, so the raw function address
//! can be stored into the callback field and called by C directly. On wasm32 a
//! `void *` / `int32_t` / `uint32_t` / `const char *` is an `i32` — a distinct
//! wasm value type from `i64` — so when C invokes the callback through a
//! `call_indirect` typed to the C signature it traps with
//! `function signature mismatch` against the `(i64…) -> …` Kira callee. This is
//! the same class the array element-callback adapters
//! (backend_capi_wasm_cb_adapters.zig) fix for the runtime's fixed clone/destroy
//! helpers; here the shape is derived per-function from the callee's Kira
//! signature so arbitrary `@Native` callbacks work.
//!
//! The thunk's parameter/return types are the wasm32 C ABI for the callee's
//! Kira signature (pointer and sub-i64 integer params as their narrow C width,
//! `i64`/float params unchanged). Each incoming argument is widened to the i64
//! register value the callee expects (zero/sign-extend for integers, PtrToInt
//! for pointers, truncate an `i32` bool slot to `i1`) and the result is narrowed
//! back. Only built on wasm32 (`needed`); on 64-bit the raw callee address is
//! used unchanged, so behavior there is byte-identical.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const capi = @import("backend_capi.zig");

/// True when a C pointer/`int32_t` and the i64 register ABI are distinct value
/// types, i.e. the wasm32 targets whose pointers are 32-bit. Identity elsewhere.
pub fn needed(types: capi.Types) bool {
    return types.usize_ty != types.i64;
}

/// The wasm32 C-ABI LLVM type for a Kira callback parameter/return `ValueType`.
/// Pointers and aggregates map to `ptr` (an `i32` value on wasm32); a sub-i64
/// integer maps to its narrow C width; `i64`/floats/String pass through.
fn cAbiType(types: capi.Types, vt: ir.ValueType) llvm.c.LLVMTypeRef {
    return switch (vt.kind) {
        .void => types.void_ty,
        .float => if (vt.name != null and std.mem.eql(u8, vt.name.?, "F32")) types.float_ty else types.double_ty,
        .boolean => types.i32, // C passes `_Bool` in an i32 slot on wasm32
        .integer => intCType(types, vt.name),
        .string => types.string_ty, // a Kira String carried as a callback arg keeps its {ptr,len}
        .construct_any, .array, .raw_ptr, .ffi_struct, .enum_instance => types.ptr_ty, // void* == i32
    };
}

fn intCType(types: capi.Types, name: ?[]const u8) llvm.c.LLVMTypeRef {
    const n = name orelse return types.i64;
    if (std.mem.eql(u8, n, "I8") or std.mem.eql(u8, n, "U8")) return types.i8;
    if (std.mem.eql(u8, n, "I16") or std.mem.eql(u8, n, "U16")) return types.i16;
    if (std.mem.eql(u8, n, "I32") or std.mem.eql(u8, n, "U32")) return types.i32;
    return types.i64; // I64/U64/unnamed Int stay i64 on every target
}

fn isSignedInt(name: ?[]const u8) bool {
    const n = name orelse return true; // an unnamed `Int` is signed
    return n.len > 0 and n[0] == 'I';
}

/// Widen a C-ABI argument to the i64/native register value the callee expects.
fn cAbiToRegister(api: *const llvm.Api, b: llvm.c.LLVMBuilderRef, types: capi.Types, vt: ir.ValueType, arg: llvm.c.LLVMValueRef) llvm.c.LLVMValueRef {
    return switch (vt.kind) {
        .void, .float, .string => arg,
        .boolean => api.LLVMBuildTrunc(b, arg, types.bool_ty, "wcb.arg.bool"),
        .integer => blk: {
            if (intCType(types, vt.name) == types.i64) break :blk arg;
            break :blk if (isSignedInt(vt.name))
                api.LLVMBuildSExt(b, arg, types.i64, "wcb.arg.si")
            else
                api.LLVMBuildZExt(b, arg, types.i64, "wcb.arg.ui");
        },
        .construct_any, .array, .raw_ptr, .ffi_struct, .enum_instance => api.LLVMBuildPtrToInt(b, arg, types.i64, "wcb.arg.ptr"),
    };
}

/// Narrow the callee's register-ABI result back to the C-ABI return type.
fn registerToCAbi(api: *const llvm.Api, b: llvm.c.LLVMBuilderRef, types: capi.Types, vt: ir.ValueType, val: llvm.c.LLVMValueRef) llvm.c.LLVMValueRef {
    return switch (vt.kind) {
        .void, .float, .string => val,
        .boolean => api.LLVMBuildZExt(b, val, types.i32, "wcb.ret.bool"),
        .integer => blk: {
            const ct = intCType(types, vt.name);
            if (ct == types.i64) break :blk val;
            break :blk api.LLVMBuildTrunc(b, val, ct, "wcb.ret.i");
        },
        .construct_any, .array, .raw_ptr, .ffi_struct, .enum_instance => api.LLVMBuildIntToPtr(b, val, types.ptr_ty, "wcb.ret.ptr"),
    };
}

/// Build (or reuse) the wasm32 C-ABI adapter thunk for `fn_decl` in `module_ref`
/// and return its function value. `callee` is the i64-ABI Kira function (a
/// definition or extern declaration in the same module). The adapter has
/// internal linkage and is deduplicated per module by name, so per-function CGUs
/// that materialize the same callback each keep their own private copy.
pub fn buildAdapter(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    module_ref: llvm.c.LLVMModuleRef,
    types: capi.Types,
    fn_decl: ir.Function,
    callee: llvm.c.LLVMValueRef,
) !llvm.c.LLVMValueRef {
    var name_buf: [48]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "kira_wcb_{d}", .{fn_decl.id});
    if (api.LLVMGetNamedFunction(module_ref, name.ptr)) |existing| return existing;

    const params = try allocator.alloc(llvm.c.LLVMTypeRef, fn_decl.param_types.len);
    defer allocator.free(params);
    for (fn_decl.param_types, 0..) |pt, i| params[i] = cAbiType(types, pt);
    const c_ret = cAbiType(types, fn_decl.return_type);
    const adapter_ty = api.LLVMFunctionType(c_ret, params.ptr, @intCast(params.len), 0);
    const adapter = api.LLVMAddFunction(module_ref, name.ptr, adapter_ty);
    api.LLVMSetLinkage(adapter, llvm.c.LLVMInternalLinkage);

    const b = api.LLVMCreateBuilderInContext(types.context);
    defer api.LLVMDisposeBuilder(b);
    const entry = api.LLVMAppendBasicBlockInContext(types.context, adapter, "entry");
    api.LLVMPositionBuilderAtEnd(b, entry);

    const call_args = try allocator.alloc(llvm.c.LLVMValueRef, fn_decl.param_types.len);
    defer allocator.free(call_args);
    for (fn_decl.param_types, 0..) |pt, i| {
        call_args[i] = cAbiToRegister(api, b, types, pt, api.LLVMGetParam(adapter, @intCast(i)));
    }
    const callee_ty = try types.functionType(allocator, fn_decl);
    const ret = api.LLVMBuildCall2(b, callee_ty, callee, call_args.ptr, @intCast(call_args.len), "");
    if (fn_decl.return_type.kind == .void) {
        _ = api.LLVMBuildRetVoid(b);
    } else {
        _ = api.LLVMBuildRet(b, registerToCAbi(api, b, types, fn_decl.return_type, ret));
    }
    return adapter;
}
