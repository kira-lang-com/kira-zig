// Typed enum teardown/deep-clone bodies for the LLVM C-API backend (leak
// class #4). An enum value is a heap 16-byte block { i64 tag, i64 payload }; a
// String payload is a 16-byte heap BOX holding a %kira.string whose byte
// buffer is a deep clone (see enumPayloadAsI64). The generic pair —
// kira_destroy_raw_ptr (frees only the block) and kira_enum_clone (shallow
// 16-byte copy that SHARES the box) — therefore leaks one box + one buffer per
// string-payload enum and cannot free the box without double-freeing clones.
//
// The typed pair generated here switches on the tag with the enum's statically
// known variants:
//   kira_destroy_enum_<T>(block)   — string-payload variants free the buffer
//                                    and the box, then the block.
//   kira_clone_enum_<T>(block)->ptr — string-payload variants get a fresh box
//                                    holding a deep buffer clone; other
//                                    payloads copy verbatim (same sharing as
//                                    the generic clone — they are also still
//                                    destroyed shallowly, so the pairing holds).
//
// Every call site selects typed-or-generic through Destructors.enumDestroyFn /
// enumCloneFn with the SAME map, so a type is deep-cloned everywhere iff it is
// deep-destroyed everywhere — the invariant that makes freeing the box sound.
// Native only: in hybrid the map is empty and everything stays shallow.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const capi = @import("backend_capi.zig");
const destructors = @import("backend_capi_destructors.zig");

pub fn build(
    api: *const llvm.Api,
    types: capi.Types,
    program: *const ir.Program,
    runtime: capi.RuntimeDecls,
    dtors: *const destructors.Destructors,
) !void {
    const builder = api.LLVMCreateBuilderInContext(types.context);
    defer api.LLVMDisposeBuilder(builder);

    for (program.enums) |enum_decl| {
        const helpers = dtors.enum_map.get(enum_decl.name) orelse continue;
        buildDestroy(api, builder, types, runtime, dtors, program, enum_decl, helpers.destroy.fn_value);
        buildClone(api, builder, types, runtime, dtors, program, enum_decl, helpers.clone.fn_value);
    }
}

fn payloadSlot(api: *const llvm.Api, b: llvm.c.LLVMBuilderRef, types: capi.Types, block: llvm.c.LLVMValueRef) llvm.c.LLVMValueRef {
    var idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(types.i64, 1, 0)};
    return api.LLVMBuildInBoundsGEP2(b, types.i64, block, &idx, idx.len, "ed.payload.slot");
}

fn buildDestroy(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    runtime: capi.RuntimeDecls,
    dtors: *const destructors.Destructors,
    program: *const ir.Program,
    enum_decl: ir.EnumTypeDecl,
    fn_value: llvm.c.LLVMValueRef,
) void {
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    const dispatch = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "dispatch");
    const free_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "free");
    const done = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "done");

    api.LLVMPositionBuilderAtEnd(b, entry);
    const block = api.LLVMGetParam(fn_value, 0);
    const is_null = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, block, api.LLVMConstNull(types.ptr_ty), "ed.isnull");
    _ = api.LLVMBuildCondBr(b, is_null, done, dispatch);

    api.LLVMPositionBuilderAtEnd(b, dispatch);
    const tag = api.LLVMBuildLoad2(b, types.i64, block, "ed.tag");
    const switch_inst = api.LLVMBuildSwitch(b, tag, free_block, @intCast(enum_decl.variants.len));
    for (enum_decl.variants) |variant| {
        const pt = variant.payload_ty orelse continue;
        if (!payloadOwnsHeap(pt.kind)) continue;
        const case_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "ed.case");
        api.LLVMAddCase(switch_inst, api.LLVMConstInt(types.i64, variant.discriminant, 0), case_block);
        api.LLVMPositionBuilderAtEnd(b, case_block);
        const payload = api.LLVMBuildLoad2(b, types.i64, payloadSlot(api, b, types, block), "ed.payload");
        const payload_ptr = api.LLVMBuildIntToPtr(b, payload, types.ptr_ty, "ed.payload.ptr");
        const payload_null = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, payload_ptr, api.LLVMConstNull(types.ptr_ty), "ed.payload.isnull");
        const payload_free = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "ed.payload.free");
        _ = api.LLVMBuildCondBr(b, payload_null, free_block, payload_free);
        api.LLVMPositionBuilderAtEnd(b, payload_free);
        switch (pt.kind) {
            .string => {
                // The box holds a %kira.string; its field 0 is the owned byte buffer.
                const str = api.LLVMBuildLoad2(b, types.string_ty, payload_ptr, "ed.str");
                const buf = api.LLVMBuildExtractValue(b, str, 0, "ed.str.ptr");
                var buf_args = [_]llvm.c.LLVMValueRef{buf};
                _ = api.LLVMBuildCall2(b, runtime.free.ty, runtime.free.fn_value, &buf_args, buf_args.len, "");
                var box_args = [_]llvm.c.LLVMValueRef{payload_ptr};
                _ = api.LLVMBuildCall2(b, runtime.free.ty, runtime.free.fn_value, &box_args, box_args.len, "");
            },
            .ffi_struct => {
                // A struct payload is stored as its shell pointer directly (moved in
                // by enumPayloadAsI64 + onEscape), so free the shell + contents via
                // the struct's typed destroy. Falls back to kira_destroy_raw_ptr
                // (block-only free) when no struct helper exists.
                const destroy = dtors.structDestroyFn(pt);
                var payload_args = [_]llvm.c.LLVMValueRef{payload_ptr};
                _ = api.LLVMBuildCall2(b, destroy.ty, destroy.fn_value, &payload_args, payload_args.len, "");
            },
            .construct_any => {
                // A type-erased payload (`some T`) is stored as its shell pointer
                // directly (moved in). Runtime-typed destroy reclaims the tree.
                // Sound because a contains-any enum is move-only (checker KIR002 at
                // every ownership edge) — it is never cloned, so the shell has a
                // single owner and the clone arm below traps.
                var any_args = [_]llvm.c.LLVMValueRef{payload};
                _ = api.LLVMBuildCall2(b, dtors.dynamic_destroy.ty, dtors.dynamic_destroy.fn_value, &any_args, any_args.len, "");
            },
            .array => {
                // An array payload is an owned KiraArray*, moved in like a struct
                // shell (e.g. Result<[Int], E>.Ok). Release it with its typed
                // element destructor so element boxes (structs, enums, nested
                // arrays) and string buffers free with it; paired with the deep
                // kira_array_clone arm in buildClone.
                const elem = dtors.elementDestroy(program, pt);
                var arr_args = [_]llvm.c.LLVMValueRef{ payload_ptr, elem orelse api.LLVMConstNull(types.ptr_ty) };
                _ = api.LLVMBuildCall2(b, runtime.array_release.ty, runtime.array_release.fn_value, &arr_args, arr_args.len, "");
            },
            else => {
                // Nested enum payload: its own block + whatever it owns.
                const destroy = dtors.enumDestroyFn(pt);
                var payload_args = [_]llvm.c.LLVMValueRef{payload_ptr};
                _ = api.LLVMBuildCall2(b, destroy.ty, destroy.fn_value, &payload_args, payload_args.len, "");
            },
        }
        _ = api.LLVMBuildBr(b, free_block);
    }

    api.LLVMPositionBuilderAtEnd(b, free_block);
    var free_args = [_]llvm.c.LLVMValueRef{block};
    _ = api.LLVMBuildCall2(b, runtime.free.ty, runtime.free.fn_value, &free_args, free_args.len, "");
    _ = api.LLVMBuildBr(b, done);

    api.LLVMPositionBuilderAtEnd(b, done);
    _ = api.LLVMBuildRetVoid(b);
}

fn buildClone(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    runtime: capi.RuntimeDecls,
    dtors: *const destructors.Destructors,
    program: *const ir.Program,
    enum_decl: ir.EnumTypeDecl,
    fn_value: llvm.c.LLVMValueRef,
) void {
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    const null_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "nullret");
    const copy_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "copy");

    api.LLVMPositionBuilderAtEnd(b, entry);
    const src = api.LLVMGetParam(fn_value, 0);
    const is_null = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, src, api.LLVMConstNull(types.ptr_ty), "ecl.isnull");
    _ = api.LLVMBuildCondBr(b, is_null, null_block, copy_block);

    api.LLVMPositionBuilderAtEnd(b, null_block);
    _ = api.LLVMBuildRet(b, api.LLVMConstNull(types.ptr_ty));

    api.LLVMPositionBuilderAtEnd(b, copy_block);
    var margs = [_]llvm.c.LLVMValueRef{types.sizeArg(b, api.LLVMConstInt(types.i64, 16, 0))};
    const dst = api.LLVMBuildCall2(b, runtime.malloc.ty, runtime.malloc.fn_value, &margs, margs.len, "ecl.dst");
    var cargs = [_]llvm.c.LLVMValueRef{ dst, src, types.sizeArg(b, api.LLVMConstInt(types.i64, 16, 0)) };
    _ = api.LLVMBuildCall2(b, runtime.memcpy.ty, runtime.memcpy.fn_value, &cargs, cargs.len, "");

    const ret_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "ecl.ret");
    const tag = api.LLVMBuildLoad2(b, types.i64, src, "ecl.tag");
    const switch_inst = api.LLVMBuildSwitch(b, tag, ret_block, @intCast(enum_decl.variants.len));
    for (enum_decl.variants) |variant| {
        const pt = variant.payload_ty orelse continue;
        if (!payloadOwnsHeap(pt.kind)) continue;
        const case_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "ecl.case");
        api.LLVMAddCase(switch_inst, api.LLVMConstInt(types.i64, variant.discriminant, 0), case_block);
        api.LLVMPositionBuilderAtEnd(b, case_block);
        // A construct_any payload cannot be deep-cloned (no kira_capi_dynamic_clone
        // call sites — see .codex/KIRA_MEMORY_MODEL.md §3), and it never needs to be: a
        // contains-any enum is move-only (checker KIR002 rejects every duplicating
        // ownership edge), so this clone helper is unreachable for it at runtime.
        // Trap to make that guarantee loud rather than silently share the shell into
        // two owners (which the typed destroy would then double-free).
        if (pt.kind == .construct_any) {
            _ = api.LLVMBuildUnreachable(b);
            continue;
        }
        const payload = api.LLVMBuildLoad2(b, types.i64, payloadSlot(api, b, types, src), "ecl.payload");
        const old_payload_ptr = api.LLVMBuildIntToPtr(b, payload, types.ptr_ty, "ecl.oldpayload");
        const payload_null = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, old_payload_ptr, api.LLVMConstNull(types.ptr_ty), "ecl.payload.isnull");
        const payload_clone = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "ecl.payload.clone");
        _ = api.LLVMBuildCondBr(b, payload_null, ret_block, payload_clone);
        api.LLVMPositionBuilderAtEnd(b, payload_clone);
        switch (pt.kind) {
            .string => {
                const str = api.LLVMBuildLoad2(b, types.string_ty, old_payload_ptr, "ecl.str");
                const old_buf = api.LLVMBuildExtractValue(b, str, 0, "ecl.str.ptr");
                const len = api.LLVMBuildExtractValue(b, str, 1, "ecl.str.len");
                var sc_args = [_]llvm.c.LLVMValueRef{ old_buf, len };
                const new_buf = api.LLVMBuildCall2(b, dtors.string_clone.ty, dtors.string_clone.fn_value, &sc_args, sc_args.len, "ecl.buf.clone");
                const new_str = api.LLVMBuildInsertValue(b, str, new_buf, 0, "ecl.str.clone");
                var bm_args = [_]llvm.c.LLVMValueRef{types.sizeArg(b, api.LLVMConstInt(types.i64, 16, 0))};
                const new_box = api.LLVMBuildCall2(b, runtime.malloc.ty, runtime.malloc.fn_value, &bm_args, bm_args.len, "ecl.newbox");
                _ = api.LLVMBuildStore(b, new_str, new_box);
                const new_box_int = api.LLVMBuildPtrToInt(b, new_box, types.i64, "ecl.newbox.int");
                _ = api.LLVMBuildStore(b, new_box_int, payloadSlot(api, b, types, dst));
            },
            .ffi_struct => {
                // Deep-copy the struct shell (kira_clone_<T>(i64)->i64) so the enum
                // copy owns it independently; paired with the struct destroy above.
                if (dtors.structCloneFn(pt)) |clone| {
                    var clone_args = [_]llvm.c.LLVMValueRef{payload};
                    const new_payload_int = api.LLVMBuildCall2(b, clone.ty, clone.fn_value, &clone_args, clone_args.len, "ecl.struct.clone");
                    _ = api.LLVMBuildStore(b, new_payload_int, payloadSlot(api, b, types, dst));
                }
                // else: no typed clone (should not happen for a declared struct) —
                // leave the shallow-copied shell pointer; structDestroyFn likewise
                // falls back to a block-only free, so the pairing stays balanced.
            },
            .array => {
                // Deep-copy the owned KiraArray* (elements included, via the typed
                // element cloner) so the enum copy owns it independently; paired
                // with the kira_array_release arm in buildDestroy.
                const elem = dtors.elementClone(program, pt);
                var clone_args = [_]llvm.c.LLVMValueRef{ old_payload_ptr, elem orelse api.LLVMConstNull(types.ptr_ty) };
                const new_arr = api.LLVMBuildCall2(b, runtime.array_clone.ty, runtime.array_clone.fn_value, &clone_args, clone_args.len, "ecl.arr.clone");
                const new_arr_int = api.LLVMBuildPtrToInt(b, new_arr, types.i64, "ecl.arr.clone.int");
                _ = api.LLVMBuildStore(b, new_arr_int, payloadSlot(api, b, types, dst));
            },
            else => {
                const clone = dtors.enumCloneFn(pt);
                var clone_args = [_]llvm.c.LLVMValueRef{old_payload_ptr};
                const new_payload_ptr = api.LLVMBuildCall2(b, clone.ty, clone.fn_value, &clone_args, clone_args.len, "ecl.payload.clone.ptr");
                const new_payload_int = api.LLVMBuildPtrToInt(b, new_payload_ptr, types.i64, "ecl.payload.clone.int");
                _ = api.LLVMBuildStore(b, new_payload_int, payloadSlot(api, b, types, dst));
            },
        }
        _ = api.LLVMBuildBr(b, ret_block);
    }

    api.LLVMPositionBuilderAtEnd(b, ret_block);
    _ = api.LLVMBuildRet(b, dst);
}

// A payload kind that owns heap beyond the enum's 16-byte block and therefore
// needs a typed destroy/clone arm: a String box + buffer, a nested enum block, a
// struct shell + contents, a type-erased (construct_any) tree, or an owned
// KiraArray* (moved in like a struct shell — e.g. Result<[Int], E>). Kept in one
// place so buildDestroy, buildClone, and the needs_typed gate in
// backend_capi_destructors.zig agree (deep-cloned <=> deep-destroyed pairing).
fn payloadOwnsHeap(kind: ir.ValueType.Kind) bool {
    return switch (kind) {
        .string, .enum_instance, .ffi_struct, .construct_any, .array => true,
        else => false,
    };
}
