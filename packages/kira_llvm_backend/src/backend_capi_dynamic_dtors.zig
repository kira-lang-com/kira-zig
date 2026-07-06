// Runtime-typed destroy/deep-clone for values whose static type is erased
// (construct_any — `Any` / construct-interface values such as widget trees)
// and for native-state payload interiors (leak class #3).
//
// Every kira_struct_alloc shell carries a u64 type-id header
// (ir.nativeStateTypeId(type_name), read back by kira_struct_type_id), and a
// KiraNativeState token records the same id — so a runtime switch over the
// program's declared struct types recovers the static destructor/clone:
//
//   kira_capi_dynamic_destroy(i64)   — high-bit value: closure teardown
//     (kira_destroy_closure). Otherwise a struct shell: switch on its type-id
//     header to kira_destroy_<T> (shell + contents). Unknown id / non-heap
//     value: NO-OP (conservative leak — pairs with the alias fallback below).
//   kira_capi_dynamic_clone(i64) -> i64 — high-bit value: closure deep clone.
//     Otherwise switch on the type-id to kira_clone_<T>. Unknown id: returns
//     the value UNCHANGED (alias) — sound because the destroy above also
//     no-ops for unknown ids: a value is deep-cloned everywhere iff it is
//     deep-destroyed everywhere, decided by the same id lookup.
//   kira_capi_state_interior_release(ptr) — switch on KiraNativeState.type_id
//     to kira_release_contents_<T>(payload), installed as the
//     kira_native_state_free interior hook (VM parity: freeNativeState
//     destroys interiors).
//
// NATIVE only — hybrid values may be VM-owned; no constructor is emitted and
// none of these functions is referenced there.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const capi = @import("backend_capi.zig");
const destructors = @import("backend_capi_destructors.zig");

// Build the bodies for the three dispatchers declared in Destructors.
pub fn build(
    api: *const llvm.Api,
    types: capi.Types,
    program: *const ir.Program,
    runtime: capi.RuntimeDecls,
    dtors: *const destructors.Destructors,
) !void {
    const builder = api.LLVMCreateBuilderInContext(types.context);
    defer api.LLVMDisposeBuilder(builder);
    buildDynamicDestroy(api, builder, types, program, dtors);
    buildDynamicClone(api, builder, types, program, dtors);
    buildStateInteriorRelease(api, builder, types, program, runtime, dtors);
}

// Shared guard: value is a plausible heap pointer (not null/sentinel, aligned).
fn guardPlausiblePointer(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    value: llvm.c.LLVMValueRef,
    ok_block: llvm.c.LLVMBasicBlockRef,
    bail_block: llvm.c.LLVMBasicBlockRef,
) void {
    const too_low = api.LLVMBuildICmp(b, llvm.c.LLVMIntULT, value, api.LLVMConstInt(types.i64, 0x1000, 0), "dd.low");
    const misaligned = api.LLVMBuildICmp(
        b,
        llvm.c.LLVMIntNE,
        api.LLVMBuildAnd(b, value, api.LLVMConstInt(types.i64, 0x7, 0), "dd.alignbits"),
        api.LLVMConstInt(types.i64, 0, 0),
        "dd.misaligned",
    );
    const bad = api.LLVMBuildOr(b, too_low, misaligned, "dd.bad");
    _ = api.LLVMBuildCondBr(b, bad, bail_block, ok_block);
}

fn buildDynamicDestroy(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    program: *const ir.Program,
    dtors: *const destructors.Destructors,
) void {
    const fn_value = dtors.dynamic_destroy.fn_value;
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    const closure_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "closure");
    const struct_check = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "struct.check");
    const dispatch = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "dispatch");
    const done = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "done");

    const tag_bit = api.LLVMConstInt(types.i64, 0x8000000000000000, 0);

    api.LLVMPositionBuilderAtEnd(b, entry);
    const value = api.LLVMGetParam(fn_value, 0);
    const tag = api.LLVMBuildAnd(b, value, tag_bit, "dd.tag");
    const is_closure = api.LLVMBuildICmp(b, llvm.c.LLVMIntNE, tag, api.LLVMConstInt(types.i64, 0, 0), "dd.isclosure");
    _ = api.LLVMBuildCondBr(b, is_closure, closure_block, struct_check);

    api.LLVMPositionBuilderAtEnd(b, closure_block);
    var cl_args = [_]llvm.c.LLVMValueRef{value};
    _ = api.LLVMBuildCall2(b, dtors.destroy_closure.ty, dtors.destroy_closure.fn_value, &cl_args, cl_args.len, "");
    _ = api.LLVMBuildBr(b, done);

    api.LLVMPositionBuilderAtEnd(b, struct_check);
    guardPlausiblePointer(api, b, types, value, dispatch, done);

    api.LLVMPositionBuilderAtEnd(b, dispatch);
    const shell = api.LLVMBuildIntToPtr(b, value, types.ptr_ty, "dd.shell");
    var id_args = [_]llvm.c.LLVMValueRef{shell};
    const type_id = api.LLVMBuildCall2(b, dtors.struct_type_id.ty, dtors.struct_type_id.fn_value, &id_args, id_args.len, "dd.typeid");
    const switch_inst = api.LLVMBuildSwitch(b, type_id, done, @intCast(program.types.len));
    var it = dtors.map.iterator();
    while (it.next()) |entry_kv| {
        const case_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "dd.case");
        api.LLVMAddCase(switch_inst, api.LLVMConstInt(types.i64, ir.nativeStateTypeId(entry_kv.key_ptr.*), 0), case_block);
        api.LLVMPositionBuilderAtEnd(b, case_block);
        var args = [_]llvm.c.LLVMValueRef{shell};
        _ = api.LLVMBuildCall2(b, entry_kv.value_ptr.destroy.ty, entry_kv.value_ptr.destroy.fn_value, &args, args.len, "");
        _ = api.LLVMBuildBr(b, done);
    }

    api.LLVMPositionBuilderAtEnd(b, done);
    _ = api.LLVMBuildRetVoid(b);
}

fn buildDynamicClone(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    program: *const ir.Program,
    dtors: *const destructors.Destructors,
) void {
    const fn_value = dtors.dynamic_clone.fn_value;
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    const closure_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "closure");
    const struct_check = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "struct.check");
    const dispatch = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "dispatch");
    const passthrough = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "passthrough");

    const tag_bit = api.LLVMConstInt(types.i64, 0x8000000000000000, 0);

    api.LLVMPositionBuilderAtEnd(b, entry);
    const value = api.LLVMGetParam(fn_value, 0);
    const tag = api.LLVMBuildAnd(b, value, tag_bit, "dc.tag");
    const is_closure = api.LLVMBuildICmp(b, llvm.c.LLVMIntNE, tag, api.LLVMConstInt(types.i64, 0, 0), "dc.isclosure");
    _ = api.LLVMBuildCondBr(b, is_closure, closure_block, struct_check);

    api.LLVMPositionBuilderAtEnd(b, closure_block);
    var cl_args = [_]llvm.c.LLVMValueRef{value};
    const cl = api.LLVMBuildCall2(b, dtors.closure_clone.ty, dtors.closure_clone.fn_value, &cl_args, cl_args.len, "dc.closure");
    _ = api.LLVMBuildRet(b, cl);

    api.LLVMPositionBuilderAtEnd(b, struct_check);
    guardPlausiblePointer(api, b, types, value, dispatch, passthrough);

    api.LLVMPositionBuilderAtEnd(b, passthrough);
    _ = api.LLVMBuildRet(b, value);

    api.LLVMPositionBuilderAtEnd(b, dispatch);
    const shell = api.LLVMBuildIntToPtr(b, value, types.ptr_ty, "dc.shell");
    var id_args = [_]llvm.c.LLVMValueRef{shell};
    const type_id = api.LLVMBuildCall2(b, dtors.struct_type_id.ty, dtors.struct_type_id.fn_value, &id_args, id_args.len, "dc.typeid");
    const switch_inst = api.LLVMBuildSwitch(b, type_id, passthrough, @intCast(program.types.len));
    var it = dtors.map.iterator();
    while (it.next()) |entry_kv| {
        const case_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "dc.case");
        api.LLVMAddCase(switch_inst, api.LLVMConstInt(types.i64, ir.nativeStateTypeId(entry_kv.key_ptr.*), 0), case_block);
        api.LLVMPositionBuilderAtEnd(b, case_block);
        var args = [_]llvm.c.LLVMValueRef{value};
        const cloned = api.LLVMBuildCall2(b, entry_kv.value_ptr.clone.ty, entry_kv.value_ptr.clone.fn_value, &args, args.len, "dc.cloned");
        _ = api.LLVMBuildRet(b, cloned);
    }
}

fn buildStateInteriorRelease(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    program: *const ir.Program,
    runtime: capi.RuntimeDecls,
    dtors: *const destructors.Destructors,
) void {
    const fn_value = dtors.state_interior_release.fn_value;
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    const dispatch = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "dispatch");
    const done = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "done");

    api.LLVMPositionBuilderAtEnd(b, entry);
    const state = api.LLVMGetParam(fn_value, 0);
    const is_null = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, state, api.LLVMConstNull(types.ptr_ty), "sir.isnull");
    _ = api.LLVMBuildCondBr(b, is_null, done, dispatch);

    api.LLVMPositionBuilderAtEnd(b, dispatch);
    // KiraNativeState layout (runtime_helpers.c): { u64 type_id; void *payload;
    // void *runtime_payload } — read the first two words directly. The payload
    // is [n_fields x KiraBridgeValue] (see lowerNativeStateFieldSet).
    const type_id = api.LLVMBuildLoad2(b, types.i64, state, "sir.typeid");
    var payload_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(types.i64, 1, 0)};
    const payload_slot = api.LLVMBuildInBoundsGEP2(b, types.i64, state, &payload_idx, payload_idx.len, "sir.payload.slot");
    const payload = api.LLVMBuildLoad2(b, types.ptr_ty, payload_slot, "sir.payload");
    const payload_null = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, payload, api.LLVMConstNull(types.ptr_ty), "sir.payload.isnull");
    const switch_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "sir.switch");
    _ = api.LLVMBuildCondBr(b, payload_null, done, switch_block);

    api.LLVMPositionBuilderAtEnd(b, switch_block);
    const switch_inst = api.LLVMBuildSwitch(b, type_id, done, @intCast(program.types.len));
    for (program.types) |type_decl| {
        if (type_decl.ffi) |ffi_info| {
            if (ffi_info != .ffi_struct) continue;
        }
        var owns_any = false;
        for (type_decl.fields) |field| {
            switch (field.ty.kind) {
                .string, .array, .ffi_struct, .raw_ptr, .construct_any, .enum_instance => owns_any = true,
                else => {},
            }
        }
        if (!owns_any) continue; // default (no interior heap): nothing to release
        const case_block = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "sir.case");
        api.LLVMAddCase(switch_inst, api.LLVMConstInt(types.i64, ir.nativeStateTypeId(type_decl.name), 0), case_block);
        api.LLVMPositionBuilderAtEnd(b, case_block);
        for (type_decl.fields, 0..) |field, index| {
            var slot_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(types.i64, @intCast(index), 0)};
            const slot = api.LLVMBuildInBoundsGEP2(b, types.bridge_ty, payload, &slot_idx, slot_idx.len, "sir.slot");
            var pay_idx = [_]llvm.c.LLVMValueRef{ api.LLVMConstInt(types.i32, 0, 0), api.LLVMConstInt(types.i32, 2, 0) };
            const pay_ptr = api.LLVMBuildInBoundsGEP2(b, types.bridge_ty, slot, &pay_idx, pay_idx.len, "sir.slot.payload");
            const pay = api.LLVMBuildLoad2(b, types.i64, pay_ptr, "sir.slot.val");
            switch (field.ty.kind) {
                .string => {
                    // The slot owns a clone (lowerNativeStateFieldSet); free it.
                    const buf = api.LLVMBuildIntToPtr(b, pay, types.ptr_ty, "sir.strbuf");
                    var args = [_]llvm.c.LLVMValueRef{buf};
                    _ = api.LLVMBuildCall2(b, runtime.free.ty, runtime.free.fn_value, &args, args.len, "");
                },
                .array => {
                    const ptr = api.LLVMBuildIntToPtr(b, pay, types.ptr_ty, "sir.arr");
                    const elem = dtors.elementDestroy(program, field.ty);
                    var args = [_]llvm.c.LLVMValueRef{ ptr, elem orelse api.LLVMConstNull(types.ptr_ty) };
                    _ = api.LLVMBuildCall2(b, runtime.array_release.ty, runtime.array_release.fn_value, &args, args.len, "");
                },
                .ffi_struct => {
                    const name = field.ty.name orelse continue;
                    const helpers = dtors.map.get(name) orelse continue;
                    const ptr = api.LLVMBuildIntToPtr(b, pay, types.ptr_ty, "sir.struct");
                    var args = [_]llvm.c.LLVMValueRef{ptr};
                    _ = api.LLVMBuildCall2(b, helpers.destroy.ty, helpers.destroy.fn_value, &args, args.len, "");
                },
                .raw_ptr => {
                    // Tag-safe closure teardown; plain FFI pointers no-op.
                    var args = [_]llvm.c.LLVMValueRef{pay};
                    _ = api.LLVMBuildCall2(b, dtors.destroy_closure.ty, dtors.destroy_closure.fn_value, &args, args.len, "");
                },
                .enum_instance => {
                    // The slot owns its block: alloc-time stores clone in
                    // (lowerAllocNativeState) and field sets destroy-replaced +
                    // move-or-clone (lowerNativeStateFieldSet) — VM parity with
                    // destroyPreservedNativeStateValue, which destroys enum
                    // slots. Typed destroy frees nested payload chains; null
                    // slots (moved-out fields zero the slot) no-op.
                    const destroy_fn = dtors.enumDestroyFn(field.ty);
                    const ptr = api.LLVMBuildIntToPtr(b, pay, types.ptr_ty, "sir.enum");
                    var args = [_]llvm.c.LLVMValueRef{ptr};
                    _ = api.LLVMBuildCall2(b, destroy_fn.ty, destroy_fn.fn_value, &args, args.len, "");
                },
                // Type-erased (Any) slots keep alias semantics on the state-set
                // default path — freeing here could double-free a value another
                // owner still holds (Any slots are not clone-in: deep-copying
                // widget trees per set is a memory explosion).
                else => {},
            }
        }
        _ = api.LLVMBuildBr(b, done);
    }

    api.LLVMPositionBuilderAtEnd(b, done);
    _ = api.LLVMBuildRetVoid(b);
}
