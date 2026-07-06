// Native-state boxing and payload-slot field sets for the LLVM C-API backend.
// Split out of backend_capi_aggregate.zig (Core Law #5). Free functions over
// *FunctionCodegen, matching the aggregate module's style.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const utils = @import("backend_utils.zig");
const drop = @import("backend_capi_drop.zig");
const FunctionCodegen = @import("backend_capi_codegen.zig").FunctionCodegen;

pub fn lowerAllocNativeState(fc: *FunctionCodegen, v: ir.AllocNativeState) !void {
    const api = fc.api;
    const b = fc.builder;
    const type_decl = utils.findTypeDecl(fc.request.program.programPtr(), v.type_name) orelse return error.UnsupportedExecutableFeature;
    const struct_ty = fc.struct_types.get(v.type_name) orelse return error.UnsupportedExecutableFeature;
    const payload_arr_ty = api.LLVMArrayType2(fc.types.bridge_ty, type_decl.fields.len);
    const size = api.LLVMSizeOf(payload_arr_ty);
    var alloc_args = [_]llvm.c.LLVMValueRef{ api.LLVMConstInt(fc.types.i64, v.type_id, 0), size };
    const box = api.LLVMBuildCall2(b, fc.runtime_decls.state_alloc.ty, fc.runtime_decls.state_alloc.fn_value, &alloc_args, alloc_args.len, "state.box");
    var pl_args = [_]llvm.c.LLVMValueRef{box};
    const payload = api.LLVMBuildCall2(b, fc.runtime_decls.state_payload.ty, fc.runtime_decls.state_payload.fn_value, &pl_args, pl_args.len, "state.payload");
    const src = api.LLVMBuildIntToPtr(b, fc.registers[v.src], fc.types.ptr_ty, "state.src");
    for (type_decl.fields, 0..) |field_decl, index| {
        var f_idx = [_]llvm.c.LLVMValueRef{ api.LLVMConstInt(fc.types.i32, 0, 0), api.LLVMConstInt(fc.types.i32, @intCast(index), 0) };
        const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, src, &f_idx, f_idx.len, "state.field.ptr");
        var field_value = if (field_decl.ty.kind == .ffi_struct)
            api.LLVMBuildPtrToInt(b, field_ptr, fc.types.i64, "state.field.struct")
        else
            try fc.loadConverted(field_ptr, field_decl.ty);
        // An enum field is a heap {tag,payload} block referenced by pointer. The
        // source struct that supplied it is dropped after this allocation, freeing
        // that block; copying only the pointer would leave the native-state payload
        // referencing freed memory (a use-after-free that reads a garbage tag on
        // recovery). Clone the block so the native state owns independent storage,
        // matching the borrowed-enum rule in lowerStoreIndirect.
        if (field_decl.ty.kind == .enum_instance and fc.drop_enabled and (fc.request.mode == .llvm_native or fc.request.mode == .hybrid)) {
            const sptr = api.LLVMBuildIntToPtr(b, field_value, fc.types.ptr_ty, "state.enum.src");
            const clone_fn = fc.dtors.enumCloneFn(field_decl.ty);
            var cargs = [_]llvm.c.LLVMValueRef{sptr};
            const clone = api.LLVMBuildCall2(b, clone_fn.ty, clone_fn.fn_value, &cargs, cargs.len, "state.enum.clone");
            field_value = api.LLVMBuildPtrToInt(b, clone, fc.types.i64, "state.enum.cloneint");
        }
        // Same aliasing hazard for a nested ffi_struct field: it is embedded INLINE
        // in the source struct's heap block, so storing `ptrtoint(field_ptr)` makes
        // the payload point INTO the source allocation. The source temp (e.g.
        // `nativeState(FoundationRetainedScratch {})`) is dropped at scope exit,
        // freeing that block — the box's field pointer dangles from birth, and the
        // next field access/replace is a use-after-free/double-free (the
        // FoundationRetainedFlatAcc crash in leak-harness/liquid-glass with
        // ownership free enabled). Deep-clone the sub-struct so the box owns an
        // independent heap struct, mirroring the enum and array cases below.
        if (field_decl.ty.kind == .ffi_struct and fc.drop_enabled and (fc.request.mode == .llvm_native or fc.request.mode == .hybrid)) {
            if (field_decl.ty.name) |field_type_name| {
                if (fc.dtors.map.get(field_type_name)) |helpers| {
                    var cargs = [_]llvm.c.LLVMValueRef{field_value};
                    field_value = api.LLVMBuildCall2(b, helpers.clone.ty, helpers.clone.fn_value, &cargs, cargs.len, "state.struct.clone");
                }
            }
        }
        // Same aliasing hazard for array fields: the source struct is dropped after
        // this allocation and its destructor releases the array, so copying only the
        // pointer would leave the payload referencing freed storage (the
        // glyphHashKeys use-after-free that crashed liquid-glass with ownership
        // free enabled). Deep-clone so the native state owns independent storage —
        // this also matches the VM, whose allocateNativeState deep-preserves array
        // fields via copyArrayToNativeLayout.
        if (field_decl.ty.kind == .array and fc.drop_enabled and (fc.request.mode == .llvm_native or fc.request.mode == .hybrid)) {
            const sptr = api.LLVMBuildIntToPtr(b, field_value, fc.types.ptr_ty, "state.arr.src");
            const elem = fc.dtors.elementClone(fc.request.program.programPtr(), field_decl.ty);
            var cargs = [_]llvm.c.LLVMValueRef{ sptr, elem orelse api.LLVMConstNull(fc.types.ptr_ty) };
            const clone = api.LLVMBuildCall2(b, fc.runtime_decls.array_clone.ty, fc.runtime_decls.array_clone.fn_value, &cargs, cargs.len, "state.arr.clone");
            field_value = api.LLVMBuildPtrToInt(b, clone, fc.types.i64, "state.arr.cloneint");
        }
        // Same aliasing hazard for string fields: the source struct's destructor
        // frees its string buffers (release_contents), so the payload must own an
        // independent clone (strings are deep values).
        if (field_decl.ty.kind == .string and fc.drop_enabled) {
            field_value = drop.cloneStringValue(fc, field_value);
        }
        const bv = try fc.packBridge(field_decl.ty, field_value);
        var s_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(fc.types.i64, @intCast(index), 0)};
        const slot = api.LLVMBuildInBoundsGEP2(b, fc.types.bridge_ty, payload, &s_idx, s_idx.len, "state.slot");
        _ = api.LLVMBuildStore(b, bv, slot);
    }
    fc.registers[v.dst] = api.LLVMBuildPtrToInt(b, box, fc.types.i64, "state.box.int");
}

// `state.field = value` on a recovered native state. Scalar fields are a plain
// bridge-value store. Array fields follow the owned-field rules of
// lowerStoreIndirect (the payload owns its arrays, mirroring the VM's
// nativeStateFieldSet which destroys the replaced value and clones borrowed
// sources): release the replaced array unless it is a self-store, deep-clone a
// borrowed source so the state owns independent storage, and escape an owned
// source's cleanup slot so function-exit cleanup does not free what the state
// now owns.
pub fn lowerNativeStateFieldSet(fc: *FunctionCodegen, v: ir.NativeStateFieldSet) !void {
    const api = fc.api;
    const b = fc.builder;
    const payload = api.LLVMBuildIntToPtr(b, fc.registers[v.state], fc.types.ptr_ty, "state.set.payload");
    var idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(fc.types.i64, v.field_index, 0)};
    const slot = api.LLVMBuildInBoundsGEP2(b, fc.types.bridge_ty, payload, &idx, idx.len, "state.set.slot");
    const owned_modes = fc.request.mode == .llvm_native or fc.request.mode == .hybrid;
    if (v.field_ty.kind == .array and fc.drop_enabled and owned_modes) {
        const old_bv = api.LLVMBuildLoad2(b, fc.types.bridge_ty, slot, "state.set.oldbv");
        const old_int = try fc.unpackBridge(v.field_ty, old_bv);
        const old = api.LLVMBuildIntToPtr(b, old_int, fc.types.ptr_ty, "state.set.old");
        const newp = api.LLVMBuildIntToPtr(b, fc.registers[v.src], fc.types.ptr_ty, "state.set.newp");
        // Self-store (`var x = state.arr; ...; state.arr = x`) must neither release
        // nor clone: the field already holds this exact array.
        const same = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, old, newp, "state.set.same");
        const work_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "state.set.work");
        const done_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "state.set.done");
        _ = api.LLVMBuildCondBr(b, same, done_block, work_block);
        api.LLVMPositionBuilderAtEnd(b, work_block);
        const reldtor = fc.dtors.elementDestroy(fc.request.program.programPtr(), v.field_ty);
        var rargs = [_]llvm.c.LLVMValueRef{ old, reldtor orelse api.LLVMConstNull(fc.types.ptr_ty) };
        _ = api.LLVMBuildCall2(b, fc.runtime_decls.array_release.ty, fc.runtime_decls.array_release.fn_value, &rargs, rargs.len, "");
        var stored = fc.registers[v.src];
        if (!drop.isOwned(fc, v.src)) {
            const elem = fc.dtors.elementClone(fc.request.program.programPtr(), v.field_ty);
            var cargs = [_]llvm.c.LLVMValueRef{ newp, elem orelse api.LLVMConstNull(fc.types.ptr_ty) };
            const clone = api.LLVMBuildCall2(b, fc.runtime_decls.array_clone.ty, fc.runtime_decls.array_clone.fn_value, &cargs, cargs.len, "state.set.clone");
            stored = api.LLVMBuildPtrToInt(b, clone, fc.types.i64, "state.set.cloneint");
        } else {
            drop.onEscape(fc, v.src);
        }
        const bv = try fc.packBridge(v.field_ty, stored);
        _ = api.LLVMBuildStore(b, bv, slot);
        _ = api.LLVMBuildBr(b, done_block);
        api.LLVMPositionBuilderAtEnd(b, done_block);
        return;
    }
    // An ffi_struct field follows the same owned-field rules: the payload owns
    // its struct (heap shell + contents). Destroy the replaced struct unless it
    // is a self-store, deep-clone a borrowed source, and escape an owned
    // source's cleanup slot so exit cleanup does not destroy the tree the state
    // now holds (the cachedLayoutTree use-after-free: `state.cachedLayoutTree =
    // run(...)` left the owned call result slot-tracked, so function exit freed
    // the LayoutTree the state still referenced).
    if (v.field_ty.kind == .ffi_struct and fc.drop_enabled and owned_modes) blk: {
        const name = v.field_ty.name orelse break :blk;
        const helpers = fc.dtors.map.get(name) orelse break :blk;
        const old_bv = api.LLVMBuildLoad2(b, fc.types.bridge_ty, slot, "state.set.oldbv");
        const old_int = try fc.unpackBridge(v.field_ty, old_bv);
        const old = api.LLVMBuildIntToPtr(b, old_int, fc.types.ptr_ty, "state.set.old");
        const newp = api.LLVMBuildIntToPtr(b, fc.registers[v.src], fc.types.ptr_ty, "state.set.newp");
        const same = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, old, newp, "state.set.same");
        const work_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "state.set.swork");
        const done_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "state.set.sdone");
        _ = api.LLVMBuildCondBr(b, same, done_block, work_block);
        api.LLVMPositionBuilderAtEnd(b, work_block);
        // kira_destroy_<T> null-checks its argument, so the first store into a
        // zeroed payload slot is a safe no-op destroy.
        var dargs = [_]llvm.c.LLVMValueRef{old};
        _ = api.LLVMBuildCall2(b, helpers.destroy.ty, helpers.destroy.fn_value, &dargs, dargs.len, "");
        var stored = fc.registers[v.src];
        if (!drop.isOwned(fc, v.src)) {
            var cargs = [_]llvm.c.LLVMValueRef{newp};
            const clone = api.LLVMBuildCall2(b, helpers.clone.ty, helpers.clone.fn_value, &cargs, cargs.len, "state.set.sclone");
            stored = api.LLVMBuildPtrToInt(b, clone, fc.types.i64, "state.set.scloneint");
        } else {
            drop.onEscape(fc, v.src);
        }
        const bv = try fc.packBridge(v.field_ty, stored);
        _ = api.LLVMBuildStore(b, bv, slot);
        _ = api.LLVMBuildBr(b, done_block);
        api.LLVMPositionBuilderAtEnd(b, done_block);
        return;
    }
    // A string payload slot owns a deep clone of every stored value. Free the
    // replaced buffer first (pure-native only — a hybrid payload slot may hold a
    // VM-written buffer), then store a fresh clone; the source register keeps
    // ownership of its own buffer. calloc'd payloads start as tag VOID with a
    // null string pointer, so the first set frees null (a no-op).
    if (v.field_ty.kind == .string and fc.drop_enabled) {
        if (fc.request.mode == .llvm_native) {
            const old_bv = api.LLVMBuildLoad2(b, fc.types.bridge_ty, slot, "state.set.stroldbv");
            const old_val = try fc.unpackBridge(v.field_ty, old_bv);
            const old_buf = api.LLVMBuildExtractValue(b, old_val, 0, "state.set.stroldbuf");
            var fargs = [_]llvm.c.LLVMValueRef{old_buf};
            _ = api.LLVMBuildCall2(b, fc.runtime_decls.free.ty, fc.runtime_decls.free.fn_value, &fargs, fargs.len, "");
        }
        const cloned = drop.cloneStringValue(fc, fc.registers[v.src]);
        const bv = try fc.packBridge(v.field_ty, cloned);
        _ = api.LLVMBuildStore(b, bv, slot);
        return;
    }
    // A closure / type-erased (Any) payload slot owns an independent DEEP CLONE,
    // and the replaced value is destroyed first (self-store guarded) — the same
    // deep-value rule as strings above. Both primitives are tag-/id-safe: plain
    // FFI pointers and unknown shells pass through and are never freed. This is
    // what lets kira_capi_state_interior_release reclaim these slots when the
    // state token is freed. Native only.
    const heap_src_kind = if (v.src < fc.register_types.len) fc.register_types[v.src].kind else ir.ValueType.Kind.integer;
    if ((v.field_ty.kind == .raw_ptr or v.field_ty.kind == .construct_any) and
        (heap_src_kind == .raw_ptr or heap_src_kind == .construct_any) and
        fc.drop_enabled and fc.request.mode == .llvm_native)
    {
        const is_any = v.field_ty.kind == .construct_any;
        const destroy_fn = if (is_any) fc.dtors.dynamic_destroy else fc.dtors.destroy_closure;
        const clone_fn = if (is_any) fc.dtors.dynamic_clone else fc.dtors.closure_clone;
        var pay_idx = [_]llvm.c.LLVMValueRef{ api.LLVMConstInt(fc.types.i32, 0, 0), api.LLVMConstInt(fc.types.i32, 2, 0) };
        const pay_ptr = api.LLVMBuildInBoundsGEP2(b, fc.types.bridge_ty, slot, &pay_idx, pay_idx.len, "state.set.heappay");
        const old = api.LLVMBuildLoad2(b, fc.types.i64, pay_ptr, "state.set.heapold");
        const same = api.LLVMBuildICmp(b, llvm.c.LLVMIntEQ, old, fc.registers[v.src], "state.set.heapsame");
        const work_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "state.set.heapwork");
        const done_block = api.LLVMAppendBasicBlockInContext(fc.types.context, fc.function_value, "state.set.heapdone");
        _ = api.LLVMBuildCondBr(b, same, done_block, work_block);
        api.LLVMPositionBuilderAtEnd(b, work_block);
        var dargs = [_]llvm.c.LLVMValueRef{old};
        _ = api.LLVMBuildCall2(b, destroy_fn.ty, destroy_fn.fn_value, &dargs, dargs.len, "");
        var cargs = [_]llvm.c.LLVMValueRef{fc.registers[v.src]};
        const cloned = api.LLVMBuildCall2(b, clone_fn.ty, clone_fn.fn_value, &cargs, cargs.len, "state.set.heapclone");
        const bv = try fc.packBridge(v.field_ty, cloned);
        _ = api.LLVMBuildStore(b, bv, slot);
        _ = api.LLVMBuildBr(b, done_block);
        api.LLVMPositionBuilderAtEnd(b, done_block);
        return;
    }
    const bv = try fc.packBridge(fc.register_types[v.src], fc.registers[v.src]);
    _ = api.LLVMBuildStore(b, bv, slot);
}

