// Per-type ownership helper generation for the LLVM C-API backend: emits
// kira_destroy_<T> / kira_release_contents_<T> and the deep-clone helpers
// kira_clone_<T> / kira_clone_contents_<T> (plus the shared kira_destroy_raw_ptr
// declaration and the kira_destroy_closure declaration), mirroring
// backend_text_ir_core's appendReleaseDefinitions / appendCloneDefinitions.
// Split out of backend_capi_drop.zig (Core Law #5); the runtime cleanup-slot drop
// driver that consumes these helpers stays in backend_capi_drop.zig.
const std = @import("std");
const ir = @import("kira_ir");
const backend_api = @import("kira_backend_api");
const llvm = @import("llvm_c.zig");
const utils = @import("backend_utils.zig");
const capi = @import("backend_capi.zig");

const findTypeDecl = utils.findTypeDecl;
const allocPrintZ = utils.allocPrintZ;
pub const TypeHelpers = struct {
    release_contents: capi.RuntimeDecls.Decl,
    destroy: capi.RuntimeDecls.Decl,
    clone_contents: capi.RuntimeDecls.Decl,
    clone: capi.RuntimeDecls.Decl,
};

// Typed enum teardown/deep-clone (leak class #4: the 16-byte string-payload box
// and its cloned buffer were shared by kira_enum_clone and never freed).
// Generated per enum type that has at least one String-payload variant; bodies
// live in backend_capi_enum_dtors.zig. Same signatures as kira_destroy_raw_ptr /
// kira_enum_clone, so every call site can substitute them 1:1.
pub const EnumHelpers = struct {
    destroy: capi.RuntimeDecls.Decl,
    clone: capi.RuntimeDecls.Decl,
};

pub const Destructors = struct {
    map: std.StringHashMapUnmanaged(TypeHelpers) = .{},
    // Per-enum typed helpers (string-payload enums, NATIVE only — a hybrid enum's
    // payload box may be VM-written and must not be freed/cloned with libc).
    // Empty in hybrid, so every accessor falls back to the generic shallow pair.
    enum_map: std.StringHashMapUnmanaged(EnumHelpers) = .{},
    destroy_raw_ptr: capi.RuntimeDecls.Decl,
    destroy_struct_ptr: capi.RuntimeDecls.Decl,
    // Tag-safe owned-closure drop (kira_destroy_closure(i64)): frees a heap closure
    // block, no-ops a callable-value function id. Used for owned closure parameters.
    destroy_closure: capi.RuntimeDecls.Decl,
    // Deep-copy a 16-byte heap enum block (kira_enum_clone(ptr)->ptr): null->null, else
    // malloc+memcpy. An owned enum field is cloned on struct copy and freed on struct
    // destroy, so each struct copy owns an independent enum (no aliasing/double-free).
    enum_clone: capi.RuntimeDecls.Decl,
    // Deep-copy a string byte buffer (kira_capi_string_clone(ptr, len) -> ptr):
    // null->null, else malloc+memcpy. Strings are deep values in the native
    // ownership model: every string entering an aggregate (struct field, array
    // element, native-state slot, enum payload, closure capture) is cloned so the
    // aggregate owns an independent buffer, and every string read out of an
    // aggregate is cloned so the reader owns one too. There are no string moves
    // and no aliasing — each buffer has exactly one owner.
    string_clone: capi.RuntimeDecls.Decl,
    // Per-closure typed capture teardown/deep-clone dispatchers (bodies built in
    // backend_capi_closure_dtors.zig after the type helpers exist, declared here
    // so release_contents/clone_contents can reference them). Both are TAG-SAFE:
    // only a value carrying the closure high bit is freed/copied, so calling them
    // on a plain FFI raw pointer (CString, userdata handle) is a no-op/pass-through.
    closure_release: capi.RuntimeDecls.Decl,
    closure_clone: capi.RuntimeDecls.Decl,
    // Whether string struct fields are freed by kira_release_contents_<T>. True on
    // the pure-native path. In HYBRID a native struct's string field may have been
    // written by the VM bridge with a VM-owned buffer, so release must not free it
    // (conservative: leak, never a cross-allocator free).
    release_strings: bool,
    // Whether closures are deep values on this path (fields/elements own their
    // blocks: release frees them, clone deep-copies them). Native only — hybrid
    // closure blocks may be VM-allocated and are torn down through the VM hook.
    deep_closures: bool,

    pub fn deinit(self: *Destructors, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.enum_map.deinit(allocator);
    }

    // Typed enum destroy for `ty` (frees a string-payload box + buffer with the
    // block), or the shallow kira_destroy_raw_ptr when no typed helper exists.
    // Fallback pairs with the shallow clone below: shallow-cloned enums share
    // their payload box, so only typed clones may be typed-destroyed.
    pub fn enumDestroyFn(self: Destructors, ty: ir.ValueType) capi.RuntimeDecls.Decl {
        if (ty.name) |name| {
            if (self.enum_map.get(name)) |helpers| return helpers.destroy;
        }
        return self.destroy_raw_ptr;
    }

    pub fn enumCloneFn(self: Destructors, ty: ir.ValueType) capi.RuntimeDecls.Decl {
        if (ty.name) |name| {
            if (self.enum_map.get(name)) |helpers| return helpers.clone;
        }
        return self.enum_clone;
    }

    // The per-element destroy function for an array type, or null for primitive
    // elements (whose buffer is freed without a per-element callback). When the
    // element type is not a struct decl, fall back to the tag-safe closure release
    // (native only): the runtime invokes the callback only on RAW_PTR-tagged
    // elements, and the release itself frees only values carrying the closure high
    // bit — so [Callback] element blocks are reclaimed while integer/float/FFI
    // pointer elements are untouched.
    pub fn elementDestroy(self: Destructors, program: *const ir.Program, array_ty: ir.ValueType) ?llvm.c.LLVMValueRef {
        if (self.structHelpers(program, array_ty)) |helpers| return helpers.destroy.fn_value;
        // kira_destroy_closure (not closure_release): the element payload is the
        // TAGGED closure value; destroy_closure untags and dispatches to the hook.
        if (self.deep_closures) return self.destroy_closure.fn_value;
        return null;
    }

    pub fn elementClone(self: Destructors, program: *const ir.Program, array_ty: ir.ValueType) ?llvm.c.LLVMValueRef {
        if (self.structHelpers(program, array_ty)) |helpers| return helpers.clone.fn_value;
        if (self.deep_closures) return self.closure_clone.fn_value;
        return null;
    }

    fn structHelpers(self: Destructors, program: *const ir.Program, array_ty: ir.ValueType) ?TypeHelpers {
        const name = array_ty.name orelse return null;
        const type_decl = findTypeDecl(program, name) orelse return null;
        if (type_decl.ffi) |ffi_info| {
            switch (ffi_info) {
                .ffi_struct => {},
                else => return null,
            }
        }
        return self.map.get(type_decl.name);
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    module_ref: llvm.c.LLVMModuleRef,
    types: capi.Types,
    struct_types: *const std.StringHashMapUnmanaged(llvm.c.LLVMTypeRef),
    program: *const ir.Program,
    runtime: capi.RuntimeDecls,
    mode: backend_api.BackendMode,
) !Destructors {
    var ptr_param = [_]llvm.c.LLVMTypeRef{types.ptr_ty};
    const void_ptr_ty = api.LLVMFunctionType(types.void_ty, &ptr_param, ptr_param.len, 0);

    const destroy_raw = api.LLVMAddFunction(module_ref, "kira_destroy_raw_ptr", void_ptr_ty);
    const destroy_struct = api.LLVMAddFunction(module_ref, "kira_destroy_struct_ptr", void_ptr_ty);
    var closure_param = [_]llvm.c.LLVMTypeRef{types.i64};
    const void_i64_ty = api.LLVMFunctionType(types.void_ty, &closure_param, closure_param.len, 0);
    const destroy_closure = api.LLVMAddFunction(module_ref, "kira_destroy_closure", void_i64_ty);
    const ptr_ptr_ty = api.LLVMFunctionType(types.ptr_ty, &ptr_param, ptr_param.len, 0);
    const enum_clone = api.LLVMAddFunction(module_ref, "kira_enum_clone", ptr_ptr_ty);
    var sclone_params = [_]llvm.c.LLVMTypeRef{ types.ptr_ty, types.i64 };
    const sclone_ty = api.LLVMFunctionType(types.ptr_ty, &sclone_params, sclone_params.len, 0);
    const string_clone = api.LLVMAddFunction(module_ref, "kira_capi_string_clone", sclone_ty);
    // Per-closure capture teardown/deep-clone dispatchers. Declared here so the
    // type helpers below can reference them; bodies are generated afterwards in
    // backend_capi_closure_dtors.zig (they need this map's kira_destroy_<T> /
    // kira_clone_<T> declarations for typed captures).
    const closure_release = api.LLVMAddFunction(module_ref, "kira_capi_closure_release", void_ptr_ty);
    var cclone_param = [_]llvm.c.LLVMTypeRef{types.i64};
    const cclone_ty = api.LLVMFunctionType(types.i64, &cclone_param, cclone_param.len, 0);
    const closure_clone = api.LLVMAddFunction(module_ref, "kira_capi_closure_clone", cclone_ty);
    var result = Destructors{
        .destroy_raw_ptr = .{ .ty = void_ptr_ty, .fn_value = destroy_raw },
        .destroy_struct_ptr = .{ .ty = void_ptr_ty, .fn_value = destroy_struct },
        .destroy_closure = .{ .ty = void_i64_ty, .fn_value = destroy_closure },
        .enum_clone = .{ .ty = ptr_ptr_ty, .fn_value = enum_clone },
        .string_clone = .{ .ty = sclone_ty, .fn_value = string_clone },
        .closure_release = .{ .ty = void_ptr_ty, .fn_value = closure_release },
        .closure_clone = .{ .ty = cclone_ty, .fn_value = closure_clone },
        .release_strings = mode != .hybrid,
        .deep_closures = mode != .hybrid,
    };

    const builder = api.LLVMCreateBuilderInContext(types.context);
    defer api.LLVMDisposeBuilder(builder);

    {
        const entry = api.LLVMAppendBasicBlockInContext(types.context, destroy_raw, "entry");
        api.LLVMPositionBuilderAtEnd(builder, entry);
        var args = [_]llvm.c.LLVMValueRef{api.LLVMGetParam(destroy_raw, 0)};
        _ = api.LLVMBuildCall2(builder, runtime.free.ty, runtime.free.fn_value, &args, args.len, "");
        _ = api.LLVMBuildRetVoid(builder);
    }
    {
        const entry = api.LLVMAppendBasicBlockInContext(types.context, destroy_struct, "entry");
        api.LLVMPositionBuilderAtEnd(builder, entry);
        var args = [_]llvm.c.LLVMValueRef{api.LLVMGetParam(destroy_struct, 0)};
        _ = api.LLVMBuildCall2(builder, runtime.struct_free.ty, runtime.struct_free.fn_value, &args, args.len, "");
        _ = api.LLVMBuildRetVoid(builder);
    }

    // kira_enum_clone: an enum value is a heap 16-byte block { i64 tag, i64 payload }
    // (see lowerAllocEnum). Deep-copy it so a struct copy owns an independent enum; a
    // null field clones to null. The payload is copied verbatim (a heap string/struct
    // payload would still be shared — enums in the layout corpus carry inline payloads).
    {
        const entry = api.LLVMAppendBasicBlockInContext(types.context, enum_clone, "entry");
        const copy_block = api.LLVMAppendBasicBlockInContext(types.context, enum_clone, "copy");
        const null_block = api.LLVMAppendBasicBlockInContext(types.context, enum_clone, "nullret");
        api.LLVMPositionBuilderAtEnd(builder, entry);
        const src = api.LLVMGetParam(enum_clone, 0);
        const is_null = api.LLVMBuildICmp(builder, llvm.c.LLVMIntEQ, src, api.LLVMConstNull(types.ptr_ty), "ec.isnull");
        _ = api.LLVMBuildCondBr(builder, is_null, null_block, copy_block);
        api.LLVMPositionBuilderAtEnd(builder, null_block);
        _ = api.LLVMBuildRet(builder, api.LLVMConstNull(types.ptr_ty));
        api.LLVMPositionBuilderAtEnd(builder, copy_block);
        var margs = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(types.i64, 16, 0)};
        const dst = api.LLVMBuildCall2(builder, runtime.malloc.ty, runtime.malloc.fn_value, &margs, margs.len, "ec.dst");
        var cargs = [_]llvm.c.LLVMValueRef{ dst, src, api.LLVMConstInt(types.i64, 16, 0) };
        _ = api.LLVMBuildCall2(builder, runtime.memcpy.ty, runtime.memcpy.fn_value, &cargs, cargs.len, "");
        _ = api.LLVMBuildRet(builder, dst);
    }

    // kira_capi_string_clone(ptr, len) -> ptr: heap-duplicate a string byte buffer.
    // null -> null (an unset field); len 0 -> malloc(1) so the result is a real
    // allocation that free() accepts. The single deep-copy primitive behind the
    // strings-are-deep-values ownership model.
    {
        const entry = api.LLVMAppendBasicBlockInContext(types.context, string_clone, "entry");
        const copy_block = api.LLVMAppendBasicBlockInContext(types.context, string_clone, "copy");
        const null_block = api.LLVMAppendBasicBlockInContext(types.context, string_clone, "nullret");
        api.LLVMPositionBuilderAtEnd(builder, entry);
        const src = api.LLVMGetParam(string_clone, 0);
        const len = api.LLVMGetParam(string_clone, 1);
        const is_null = api.LLVMBuildICmp(builder, llvm.c.LLVMIntEQ, src, api.LLVMConstNull(types.ptr_ty), "sc.isnull");
        _ = api.LLVMBuildCondBr(builder, is_null, null_block, copy_block);
        api.LLVMPositionBuilderAtEnd(builder, null_block);
        _ = api.LLVMBuildRet(builder, api.LLVMConstNull(types.ptr_ty));
        api.LLVMPositionBuilderAtEnd(builder, copy_block);
        const is_zero = api.LLVMBuildICmp(builder, llvm.c.LLVMIntEQ, len, api.LLVMConstInt(types.i64, 0, 0), "sc.zero");
        const alloc_len = api.LLVMBuildSelect(builder, is_zero, api.LLVMConstInt(types.i64, 1, 0), len, "sc.alloclen");
        var margs = [_]llvm.c.LLVMValueRef{alloc_len};
        const dst = api.LLVMBuildCall2(builder, runtime.malloc.ty, runtime.malloc.fn_value, &margs, margs.len, "sc.dst");
        var cargs = [_]llvm.c.LLVMValueRef{ dst, src, len };
        _ = api.LLVMBuildCall2(builder, runtime.memcpy.ty, runtime.memcpy.fn_value, &cargs, cargs.len, "");
        _ = api.LLVMBuildRet(builder, dst);
    }

    // Pass 1: declare all type helpers so bodies can reference each other.
    for (program.types) |type_decl| {
        if (type_decl.ffi) |ffi_info| {
            if (ffi_info != .ffi_struct) continue;
        }
        const rc_name = try allocPrintZ(allocator, "kira_release_contents_{s}", .{type_decl.name});
        defer allocator.free(rc_name);
        const d_name = try allocPrintZ(allocator, "kira_destroy_{s}", .{type_decl.name});
        defer allocator.free(d_name);
        const cc_name = try allocPrintZ(allocator, "kira_clone_contents_{s}", .{type_decl.name});
        defer allocator.free(cc_name);
        const c_name = try allocPrintZ(allocator, "kira_clone_{s}", .{type_decl.name});
        defer allocator.free(c_name);
        var i64_param = [_]llvm.c.LLVMTypeRef{types.i64};
        const clone_ty = api.LLVMFunctionType(types.i64, &i64_param, i64_param.len, 0);
        try result.map.put(allocator, type_decl.name, .{
            .release_contents = .{ .ty = void_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, rc_name.ptr, void_ptr_ty) },
            .destroy = .{ .ty = void_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, d_name.ptr, void_ptr_ty) },
            .clone_contents = .{ .ty = void_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, cc_name.ptr, void_ptr_ty) },
            .clone = .{ .ty = clone_ty, .fn_value = api.LLVMAddFunction(module_ref, c_name.ptr, clone_ty) },
        });
    }

    // Typed enum helper declarations (bodies in backend_capi_enum_dtors.zig):
    // one destroy/clone pair per enum with a String-payload variant, so the
    // struct helpers below (and every other enum site) can substitute them for
    // the shallow kira_destroy_raw_ptr / kira_enum_clone pair. Native only —
    // hybrid keeps the shallow pair (payload boxes may be VM-managed).
    if (mode != .hybrid) {
        for (program.enums) |enum_decl| {
            var has_string_payload = false;
            for (enum_decl.variants) |variant| {
                const pt = variant.payload_ty orelse continue;
                if (pt.kind == .string) has_string_payload = true;
            }
            if (!has_string_payload) continue;
            const ed_name = try allocPrintZ(allocator, "kira_destroy_enum_{s}", .{enum_decl.name});
            defer allocator.free(ed_name);
            const ecl_name = try allocPrintZ(allocator, "kira_clone_enum_{s}", .{enum_decl.name});
            defer allocator.free(ecl_name);
            try result.enum_map.put(allocator, enum_decl.name, .{
                .destroy = .{ .ty = void_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, ed_name.ptr, void_ptr_ty) },
                .clone = .{ .ty = ptr_ptr_ty, .fn_value = api.LLVMAddFunction(module_ref, ecl_name.ptr, ptr_ptr_ty) },
            });
        }
    }

    // Pass 2: build bodies.
    for (program.types) |type_decl| {
        if (type_decl.ffi) |ffi_info| {
            if (ffi_info != .ffi_struct) continue;
        }
        const struct_ty = struct_types.get(type_decl.name) orelse continue;
        const helpers = result.map.get(type_decl.name).?;
        try buildReleaseContents(api, builder, types, runtime, result, program, struct_ty, type_decl, helpers.release_contents.fn_value);
        try buildDestroy(api, builder, types, runtime, struct_ty, helpers.release_contents, helpers.destroy.fn_value);
        try buildCloneContents(api, builder, types, runtime, result, program, struct_ty, type_decl, helpers.clone_contents.fn_value);
        try buildClone(api, builder, types, runtime, struct_ty, type_decl.name, helpers.clone_contents, helpers.clone.fn_value);
    }

    return result;
}

fn buildReleaseContents(api: *const llvm.Api, b: llvm.c.LLVMBuilderRef, types: capi.Types, runtime: capi.RuntimeDecls, dtors: Destructors, program: *const ir.Program, struct_ty: llvm.c.LLVMTypeRef, type_decl: ir.TypeDecl, fn_value: llvm.c.LLVMValueRef) !void {
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    const body = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "body");
    const done = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "done");
    api.LLVMPositionBuilderAtEnd(b, entry);
    const value = api.LLVMGetParam(fn_value, 0);
    // Null guard: a moved-out / escaped backing is passed as null and must be a no-op
    // (callers release a struct's contents only when it still owns them).
    const is_null = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, value, api.LLVMConstNull(types.ptr_ty), "rc.isnull");
    _ = api.LLVMBuildCondBr(b, is_null, done, body);
    api.LLVMPositionBuilderAtEnd(b, body);
    for (type_decl.fields, 0..) |field, index| {
        var idx = [_]llvm.c.LLVMValueRef{ api.LLVMConstInt(types.i32, 0, 0), api.LLVMConstInt(types.i32, @intCast(index), 0) };
        switch (field.ty.kind) {
            .ffi_struct => {
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "rc.field");
                const fh = dtors.map.get(field.ty.name orelse continue) orelse continue;
                var args = [_]llvm.c.LLVMValueRef{field_ptr};
                _ = api.LLVMBuildCall2(b, fh.release_contents.ty, fh.release_contents.fn_value, &args, args.len, "");
            },
            .array => {
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "rc.arrfield");
                const arr = api.LLVMBuildLoad2(b, types.ptr_ty, field_ptr, "rc.arr");
                const elem = dtors.elementDestroy(program, field.ty);
                var args = [_]llvm.c.LLVMValueRef{ arr, elem orelse api.LLVMConstNull(types.ptr_ty) };
                _ = api.LLVMBuildCall2(b, runtime.array_release.ty, runtime.array_release.fn_value, &args, args.len, "");
            },
            .enum_instance => {
                // An owned enum field is a heap block the struct owns; free it (free(null)
                // is a safe no-op for an unset field). Paired with the enum clone below so
                // every struct copy owns its enum and the frees stay balanced. A typed
                // helper (string-payload enum, native) frees the payload box + buffer too.
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "rc.enumfield");
                const enum_ptr = api.LLVMBuildLoad2(b, types.ptr_ty, field_ptr, "rc.enum");
                const destroy = dtors.enumDestroyFn(field.ty);
                var args = [_]llvm.c.LLVMValueRef{enum_ptr};
                _ = api.LLVMBuildCall2(b, destroy.ty, destroy.fn_value, &args, args.len, "");
            },
            .string => {
                // A string field owns its byte buffer (every store into the field clones,
                // see the strings-are-deep-values model in backend_capi_drop.zig); free it
                // with the struct. free(null) covers a zero-initialized field. Native path
                // only: in hybrid the VM may have written a VM-owned buffer into this field
                // through the borrow-mut bridge, which must not be freed with libc.
                if (!dtors.release_strings) continue;
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "rc.strfield");
                const str = api.LLVMBuildLoad2(b, types.string_ty, field_ptr, "rc.str");
                const buf = api.LLVMBuildExtractValue(b, str, 0, "rc.str.ptr");
                var args = [_]llvm.c.LLVMValueRef{buf};
                _ = api.LLVMBuildCall2(b, runtime.free.ty, runtime.free.fn_value, &args, args.len, "");
            },
            .raw_ptr => {
                // A closure field owns its block + captures (every store into the field
                // clones, mirroring strings). kira_destroy_closure is TAG-SAFE: a plain
                // FFI pointer field (CString, userdata handle — high bit clear) is left
                // untouched, so this only reclaims real closure values. Native only.
                if (!dtors.deep_closures) continue;
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "rc.closfield");
                const closure_val = api.LLVMBuildLoad2(b, types.i64, field_ptr, "rc.clos");
                var args = [_]llvm.c.LLVMValueRef{closure_val};
                _ = api.LLVMBuildCall2(b, dtors.destroy_closure.ty, dtors.destroy_closure.fn_value, &args, args.len, "");
            },
            else => {},
        }
    }
    _ = api.LLVMBuildBr(b, done);
    api.LLVMPositionBuilderAtEnd(b, done);
    _ = api.LLVMBuildRetVoid(b);
}

fn buildDestroy(api: *const llvm.Api, b: llvm.c.LLVMBuilderRef, types: capi.Types, runtime: capi.RuntimeDecls, struct_ty: llvm.c.LLVMTypeRef, rc: capi.RuntimeDecls.Decl, fn_value: llvm.c.LLVMValueRef) !void {
    _ = struct_ty;
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    const body = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "body");
    const done = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "done");
    api.LLVMPositionBuilderAtEnd(b, entry);
    const value = api.LLVMGetParam(fn_value, 0);
    const is_null = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, value, api.LLVMConstNull(types.ptr_ty), "isnull");
    _ = api.LLVMBuildCondBr(b, is_null, done, body);
    api.LLVMPositionBuilderAtEnd(b, body);
    var rc_args = [_]llvm.c.LLVMValueRef{value};
    _ = api.LLVMBuildCall2(b, rc.ty, rc.fn_value, &rc_args, rc_args.len, "");
    var free_args = [_]llvm.c.LLVMValueRef{value};
    _ = api.LLVMBuildCall2(b, runtime.struct_free.ty, runtime.struct_free.fn_value, &free_args, free_args.len, "");
    _ = api.LLVMBuildBr(b, done);
    api.LLVMPositionBuilderAtEnd(b, done);
    _ = api.LLVMBuildRetVoid(b);
}

fn buildCloneContents(api: *const llvm.Api, b: llvm.c.LLVMBuilderRef, types: capi.Types, runtime: capi.RuntimeDecls, dtors: Destructors, program: *const ir.Program, struct_ty: llvm.c.LLVMTypeRef, type_decl: ir.TypeDecl, fn_value: llvm.c.LLVMValueRef) !void {
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    api.LLVMPositionBuilderAtEnd(b, entry);
    const value = api.LLVMGetParam(fn_value, 0);
    for (type_decl.fields, 0..) |field, index| {
        var idx = [_]llvm.c.LLVMValueRef{ api.LLVMConstInt(types.i32, 0, 0), api.LLVMConstInt(types.i32, @intCast(index), 0) };
        switch (field.ty.kind) {
            .ffi_struct => {
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "cc.field");
                const fh = dtors.map.get(field.ty.name orelse continue) orelse continue;
                var args = [_]llvm.c.LLVMValueRef{field_ptr};
                _ = api.LLVMBuildCall2(b, fh.clone_contents.ty, fh.clone_contents.fn_value, &args, args.len, "");
            },
            .array => {
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "cc.arrfield");
                const old = api.LLVMBuildLoad2(b, types.ptr_ty, field_ptr, "cc.old");
                const elem = dtors.elementClone(program, field.ty);
                var args = [_]llvm.c.LLVMValueRef{ old, elem orelse api.LLVMConstNull(types.ptr_ty) };
                const new = api.LLVMBuildCall2(b, runtime.array_clone.ty, runtime.array_clone.fn_value, &args, args.len, "cc.new");
                _ = api.LLVMBuildStore(b, new, field_ptr);
            },
            .enum_instance => {
                // Deep-copy the owned enum block so the copy owns it independently
                // (paired with the free in release_contents; typed clones also give
                // the copy its own string-payload box). clone(null) = null.
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "cc.enumfield");
                const old = api.LLVMBuildLoad2(b, types.ptr_ty, field_ptr, "cc.enumold");
                const clone_fn = dtors.enumCloneFn(field.ty);
                var args = [_]llvm.c.LLVMValueRef{old};
                const new = api.LLVMBuildCall2(b, clone_fn.ty, clone_fn.fn_value, &args, args.len, "cc.enumnew");
                _ = api.LLVMBuildStore(b, new, field_ptr);
            },
            .string => {
                // Deep-copy the string buffer so the struct copy owns it independently
                // (paired with the free in release_contents). Runs in hybrid too: the
                // clone is a fresh native buffer, safe regardless of who owned the source.
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "cc.strfield");
                const old = api.LLVMBuildLoad2(b, types.string_ty, field_ptr, "cc.strold");
                const old_buf = api.LLVMBuildExtractValue(b, old, 0, "cc.strold.ptr");
                const len = api.LLVMBuildExtractValue(b, old, 1, "cc.strold.len");
                var args = [_]llvm.c.LLVMValueRef{ old_buf, len };
                const new_buf = api.LLVMBuildCall2(b, dtors.string_clone.ty, dtors.string_clone.fn_value, &args, args.len, "cc.strnew");
                const new = api.LLVMBuildInsertValue(b, old, new_buf, 0, "cc.strval");
                _ = api.LLVMBuildStore(b, new, field_ptr);
            },
            .raw_ptr => {
                // Deep-copy a closure field so the struct copy owns an independent block
                // (paired with the release above). kira_capi_closure_clone is TAG-SAFE:
                // plain FFI pointer fields pass through unchanged. Native only.
                if (!dtors.deep_closures) continue;
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "cc.closfield");
                const old = api.LLVMBuildLoad2(b, types.i64, field_ptr, "cc.closold");
                var args = [_]llvm.c.LLVMValueRef{old};
                const new = api.LLVMBuildCall2(b, dtors.closure_clone.ty, dtors.closure_clone.fn_value, &args, args.len, "cc.closnew");
                _ = api.LLVMBuildStore(b, new, field_ptr);
            },
            else => {},
        }
    }
    _ = api.LLVMBuildRetVoid(b);
}

fn buildClone(api: *const llvm.Api, b: llvm.c.LLVMBuilderRef, types: capi.Types, runtime: capi.RuntimeDecls, struct_ty: llvm.c.LLVMTypeRef, type_name: []const u8, cc: capi.RuntimeDecls.Decl, fn_value: llvm.c.LLVMValueRef) !void {
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    const nullret = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "nullret");
    const body = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "body");
    api.LLVMPositionBuilderAtEnd(b, entry);
    const srcint = api.LLVMGetParam(fn_value, 0);
    const src = api.LLVMBuildIntToPtr(b, srcint, types.ptr_ty, "clone.src");
    const is_null = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, src, api.LLVMConstNull(types.ptr_ty), "clone.isnull");
    _ = api.LLVMBuildCondBr(b, is_null, nullret, body);
    api.LLVMPositionBuilderAtEnd(b, nullret);
    _ = api.LLVMBuildRet(b, api.LLVMConstInt(types.i64, 0, 0));
    api.LLVMPositionBuilderAtEnd(b, body);
    var malloc_args = [_]llvm.c.LLVMValueRef{
        api.LLVMConstInt(types.i64, ir.nativeStateTypeId(type_name), 0),
        api.LLVMSizeOf(struct_ty),
    };
    const dst = api.LLVMBuildCall2(b, runtime.struct_alloc.ty, runtime.struct_alloc.fn_value, &malloc_args, malloc_args.len, "clone.dst");
    const val = api.LLVMBuildLoad2(b, struct_ty, src, "clone.val");
    _ = api.LLVMBuildStore(b, val, dst);
    var cc_args = [_]llvm.c.LLVMValueRef{dst};
    _ = api.LLVMBuildCall2(b, cc.ty, cc.fn_value, &cc_args, cc_args.len, "");
    _ = api.LLVMBuildRet(b, api.LLVMBuildPtrToInt(b, dst, types.i64, "clone.dstint"));
}
