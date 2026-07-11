// Per-struct destroy/release/clone body generation for the LLVM C-API backend.
// Extracted from backend_capi_destructors.zig (Core Law #5): the Destructors
// model, its accessors, and the build() orchestration stay there; the four
// per-type body builders it drives in pass 2 live here.
//
// The generated bodies mirror backend_text_ir_core's release/clone definitions:
//   kira_release_contents_<T>(ptr)  — free each owning field (array/struct/enum/
//                                     string/closure/Any) in place.
//   kira_destroy_<T>(ptr)           — release_contents then free the shell.
//   kira_clone_contents_<T>(ptr)    — deep-copy each owning field in place.
//   kira_clone_<T>(i64) -> i64      — struct_alloc a fresh shell, bitcopy, then
//                                     clone_contents.
// Each field edge is paired: a kind is deep-destroyed iff its store establishes
// ownership (KIRA_MEMORY_MODEL.md §7). Native/hybrid gating flows in through the
// Destructors flags (release_strings/deep_closures).
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const capi = @import("backend_capi.zig");
const utils = @import("backend_utils.zig");
const destructors = @import("backend_capi_destructors.zig");

const Destructors = destructors.Destructors;

// When `field_ty` is a named @FFI.Array type (lowered to .raw_ptr, losing the
// array-ness), the element-typed array view to feed elementDestroy/elementClone
// — the same view a plain `.array` field carries in `field.ty`. Null for every
// other raw_ptr field (plain FFI pointers, closures).
fn ffiArrayElement(program: *const ir.Program, field_ty: ir.ValueType) ?ir.ValueType {
    const name = field_ty.name orelse return null;
    for (program.types) |type_decl| {
        if (!std.mem.eql(u8, type_decl.name, name)) continue;
        const ffi_info = type_decl.ffi orelse return null;
        return switch (ffi_info) {
            .array => |info| .{ .kind = .array, .name = info.element.name },
            else => null,
        };
    }
    return null;
}

pub fn buildReleaseContents(api: *const llvm.Api, b: llvm.c.LLVMBuilderRef, types: capi.Types, runtime: capi.RuntimeDecls, dtors: Destructors, program: *const ir.Program, struct_ty: llvm.c.LLVMTypeRef, type_decl: ir.TypeDecl, fn_value: llvm.c.LLVMValueRef) !void {
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
                // An @FFI.Array field is INLINE [count x element] C storage (see
                // fieldStorageType), not an owned KiraArray*: element stores write
                // in place through lowerFfiFixedArraySet (release-replacing the old
                // element's contents), so there is nothing array-shaped to release
                // here — and the tag-safe closure release below must not load the
                // inline element bytes as if they were a pointer. Skip it.
                if (ffiArrayElement(program, field.ty) != null) continue;
                // A closure field owns its block + captures (every store into the field
                // clones, mirroring strings). kira_destroy_closure is TAG-SAFE: a plain
                // FFI pointer field (CString, userdata handle — high bit clear) is left
                // untouched, so this only reclaims real closure values. Native only.
                if (!dtors.deep_closures) continue;
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "rc.closfield");
                // A closure-typed field is a full i64 slot (fieldStorageType) so the
                // bit-63 tag survives on wasm32 — load the whole word. Other raw_ptr
                // fields are pointer-width: load at that width and widen — a raw i64
                // load would over-read the adjacent field on wasm32 and set garbage
                // tag bits, misfiring the tag-safe closure destroy (mirrors
                // value_repr.loadConverted).
                const closure_val = if (utils.isClosureValueType(field.ty))
                    api.LLVMBuildLoad2(b, types.i64, field_ptr, "rc.clos")
                else blk: {
                    const closure_ptr = api.LLVMBuildLoad2(b, types.ptr_ty, field_ptr, "rc.closptr");
                    break :blk api.LLVMBuildPtrToInt(b, closure_ptr, types.i64, "rc.clos");
                };
                var args = [_]llvm.c.LLVMValueRef{closure_val};
                _ = api.LLVMBuildCall2(b, dtors.destroy_closure.ty, dtors.destroy_closure.fn_value, &args, args.len, "");
            },
            .construct_any => {
                if (!dtors.deep_closures) continue;
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "rc.anyfield");
                // Pointer-width field load + widen (see the raw_ptr case above): a raw
                // i64 load over-reads the adjacent field on wasm32.
                const any_ptr = api.LLVMBuildLoad2(b, types.ptr_ty, field_ptr, "rc.anyptr");
                const any_val = api.LLVMBuildPtrToInt(b, any_ptr, types.i64, "rc.any");
                var args = [_]llvm.c.LLVMValueRef{any_val};
                _ = api.LLVMBuildCall2(b, dtors.dynamic_destroy.ty, dtors.dynamic_destroy.fn_value, &args, args.len, "");
            },
            else => {},
        }
    }
    _ = api.LLVMBuildBr(b, done);
    api.LLVMPositionBuilderAtEnd(b, done);
    _ = api.LLVMBuildRetVoid(b);
}

pub fn buildDestroy(api: *const llvm.Api, b: llvm.c.LLVMBuilderRef, types: capi.Types, runtime: capi.RuntimeDecls, struct_ty: llvm.c.LLVMTypeRef, rc: capi.RuntimeDecls.Decl, fn_value: llvm.c.LLVMValueRef) !void {
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

pub fn buildCloneContents(api: *const llvm.Api, b: llvm.c.LLVMBuilderRef, types: capi.Types, runtime: capi.RuntimeDecls, dtors: Destructors, program: *const ir.Program, struct_ty: llvm.c.LLVMTypeRef, type_decl: ir.TypeDecl, fn_value: llvm.c.LLVMValueRef) !void {
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
                // Inline @FFI.Array storage: the shallow bitcopy already duplicated
                // the [count x element] bytes; per-element owned contents are the
                // set path's responsibility (release-replace + clone_contents in
                // lowerFfiFixedArraySet). Mirror the release-side skip so the
                // tag-safe closure clone never reads element bytes as a pointer.
                if (ffiArrayElement(program, field.ty) != null) continue;
                // Deep-copy a closure field so the struct copy owns an independent block
                // (paired with the release above). kira_capi_closure_clone is TAG-SAFE:
                // plain FFI pointer fields pass through unchanged. Native only.
                if (!dtors.deep_closures) continue;
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "cc.closfield");
                // A closure-typed field is a full i64 slot (fieldStorageType): load and
                // store the whole word so the bit-63 tag survives on wasm32. Other
                // raw_ptr fields stay pointer-width: a raw i64 load on wasm32 (4-byte
                // ptr) over-reads the adjacent field and sets garbage tag bits, so the
                // tag-safe clone treats a plain RawPtr handle as a closure and reads a
                // bogus capture count -> multi-GB malloc/OOM. For those, widen the
                // pointer to the i64 tag representation for the clone, then truncate
                // the result back to storage width for the store.
                if (utils.isClosureValueType(field.ty)) {
                    const old = api.LLVMBuildLoad2(b, types.i64, field_ptr, "cc.closold");
                    var args = [_]llvm.c.LLVMValueRef{old};
                    const new = api.LLVMBuildCall2(b, dtors.closure_clone.ty, dtors.closure_clone.fn_value, &args, args.len, "cc.closnew");
                    _ = api.LLVMBuildStore(b, new, field_ptr);
                } else {
                    const old_ptr = api.LLVMBuildLoad2(b, types.ptr_ty, field_ptr, "cc.closoldptr");
                    const old = api.LLVMBuildPtrToInt(b, old_ptr, types.i64, "cc.closold");
                    var args = [_]llvm.c.LLVMValueRef{old};
                    const new = api.LLVMBuildCall2(b, dtors.closure_clone.ty, dtors.closure_clone.fn_value, &args, args.len, "cc.closnew");
                    const new_ptr = api.LLVMBuildIntToPtr(b, new, types.ptr_ty, "cc.closnewptr");
                    _ = api.LLVMBuildStore(b, new_ptr, field_ptr);
                }
            },
            .construct_any => {
                if (!dtors.deep_closures) continue;
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, value, &idx, idx.len, "cc.anyfield");
                // Pointer-width load/store + widen (see the raw_ptr case above).
                const old_ptr = api.LLVMBuildLoad2(b, types.ptr_ty, field_ptr, "cc.anyoldptr");
                const old = api.LLVMBuildPtrToInt(b, old_ptr, types.i64, "cc.anyold");
                var args = [_]llvm.c.LLVMValueRef{old};
                const new = api.LLVMBuildCall2(b, dtors.dynamic_clone.ty, dtors.dynamic_clone.fn_value, &args, args.len, "cc.anynew");
                const new_ptr = api.LLVMBuildIntToPtr(b, new, types.ptr_ty, "cc.anynewptr");
                _ = api.LLVMBuildStore(b, new_ptr, field_ptr);
            },
            else => {},
        }
    }
    _ = api.LLVMBuildRetVoid(b);
}

pub fn buildClone(api: *const llvm.Api, b: llvm.c.LLVMBuilderRef, types: capi.Types, runtime: capi.RuntimeDecls, struct_ty: llvm.c.LLVMTypeRef, type_name: []const u8, cc: capi.RuntimeDecls.Decl, fn_value: llvm.c.LLVMValueRef) !void {
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
        types.sizeArg(b, api.LLVMSizeOf(struct_ty)),
    };
    const dst = api.LLVMBuildCall2(b, runtime.struct_alloc.ty, runtime.struct_alloc.fn_value, &malloc_args, malloc_args.len, "clone.dst");
    const val = api.LLVMBuildLoad2(b, struct_ty, src, "clone.val");
    _ = api.LLVMBuildStore(b, val, dst);
    var cc_args = [_]llvm.c.LLVMValueRef{dst};
    _ = api.LLVMBuildCall2(b, cc.ty, cc.fn_value, &cc_args, cc_args.len, "");
    _ = api.LLVMBuildRet(b, api.LLVMBuildPtrToInt(b, dst, types.i64, "clone.dstint"));
}
