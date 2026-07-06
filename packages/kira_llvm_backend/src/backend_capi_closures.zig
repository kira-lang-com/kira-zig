// Closure construction and closure-call lowering for the LLVM C-API backend. Split out
// of backend_capi_codegen.zig (Core Law #5). Free functions over *FunctionCodegen,
// matching backend_capi_aggregate.zig's style.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const drop = @import("backend_capi_drop.zig");
const dispatch = @import("backend_capi_dispatch.zig");
const FunctionCodegen = @import("backend_capi_codegen.zig").FunctionCodegen;

// A closure is a heap block { i64 fn_id; i64 count; [count x bridge] captures } whose
// i64 register carries the high bit set as a closure tag. The UNTAGGED heap pointer is
// recorded for drop (freeing the tagged value would corrupt the heap).
pub fn lowerConstClosure(fc: *FunctionCodegen, v: ir.ConstClosure) !void {
    const api = fc.api;
    const b = fc.builder;
    const n = v.captures.len;
    const captures_arr_ty = api.LLVMArrayType2(fc.types.bridge_ty, n);
    const captures_size = api.LLVMSizeOf(captures_arr_ty);
    const total = api.LLVMBuildAdd(b, api.LLVMConstInt(fc.types.i64, 16, 0), captures_size, "closure.size");
    var margs = [_]llvm.c.LLVMValueRef{total};
    const ptr = api.LLVMBuildCall2(b, fc.runtime_decls.malloc.ty, fc.runtime_decls.malloc.fn_value, &margs, margs.len, "closure.alloc");
    var id_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(fc.types.i64, 0, 0)};
    const id_slot = api.LLVMBuildInBoundsGEP2(b, fc.types.i64, ptr, &id_idx, id_idx.len, "closure.id.slot");
    _ = api.LLVMBuildStore(b, api.LLVMConstInt(fc.types.i64, v.function_id, 0), id_slot);
    var count_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(fc.types.i64, 1, 0)};
    const count_slot = api.LLVMBuildInBoundsGEP2(b, fc.types.i64, ptr, &count_idx, count_idx.len, "closure.count.slot");
    _ = api.LLVMBuildStore(b, api.LLVMConstInt(fc.types.i64, n, 0), count_slot);
    var slots_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(fc.types.i64, 16, 0)};
    const slots = api.LLVMBuildInBoundsGEP2(b, fc.types.i8, ptr, &slots_idx, slots_idx.len, "closure.slots");
    for (v.captures, 0..) |capture_reg, index| {
        var slot_idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(fc.types.i64, index, 0)};
        const slot = api.LLVMBuildInBoundsGEP2(b, fc.types.bridge_ty, slots, &slot_idx, slot_idx.len, "closure.slot");
        // Capture ownership mirrors the VM's allocateClosure (vm.zig):
        //   string      — always a deep CLONE (strings are deep values): the closure
        //                 may outlive the frame whose producer/local slots free the
        //                 source buffer at scope exit. The block owns the clone;
        //                 kira_capi_closure_release frees it.
        //   owned/move  — the value TRANSFERS into the block: escape the source so
        //                 the frame's scope-exit drop does not free storage the block
        //                 now owns.
        //   copy        — the block owns an independent DEEP CLONE (the VM clones
        //                 managed values for by-value captures; aliasing here would
        //                 leave the capture dangling once the frame drops the source).
        //   borrow      — a non-owning alias; release/clone never touch it.
        // Native only for the aggregate kinds: hybrid captures may be VM-managed and
        // keep the historical alias semantics (the VM hook tears them down).
        const ty = if (capture_reg < fc.register_types.len) fc.register_types[capture_reg] else ir.ValueType{ .kind = .raw_ptr };
        const ownership = if (index < v.capture_ownership.len) v.capture_ownership[index] else ir.OwnershipMode.borrow_read;
        var capture_value = fc.registers[capture_reg];
        if (fc.drop_enabled and ty.kind == .string) {
            capture_value = drop.cloneStringValue(fc, capture_value);
        } else if (fc.drop_enabled and fc.request.mode == .llvm_native) {
            switch (ty.kind) {
                .ffi_struct => switch (ownership) {
                    // moveOrCloneToHeap, not a plain escape: a struct source may be
                    // stack-backed (struct_contents) and must move into heap storage
                    // the block can own beyond this frame. Consumes the source.
                    .owned, .move => {
                        if (ty.name != null and fc.dtors.map.get(ty.name.?) != null) {
                            capture_value = drop.moveOrCloneToHeap(fc, capture_reg, ty.name.?);
                        }
                    },
                    .copy => capture_value = cloneCaptureValue(fc, ty, capture_value),
                    .borrow_read, .borrow_mut => {},
                },
                .array, .enum_instance, .raw_ptr => switch (ownership) {
                    .owned, .move => drop.onEscape(fc, capture_reg),
                    .copy => capture_value = cloneCaptureValue(fc, ty, capture_value),
                    .borrow_read, .borrow_mut => {},
                },
                else => {},
            }
        }
        const bv = try fc.packBridgeBoxed(ty, capture_value, false);
        _ = api.LLVMBuildStore(b, bv, slot);
    }
    const raw = api.LLVMBuildPtrToInt(b, ptr, fc.types.i64, "closure.raw");
    // Set the high bit (0x8000000000000000) to tag this i64 as a closure pointer.
    fc.registers[v.dst] = api.LLVMBuildOr(b, raw, api.LLVMConstInt(fc.types.i64, 0x8000000000000000, 0), "closure.tagged");
    if (fc.request.mode == .hybrid) {
        // Hybrid slot kind is .raw (plain free): record the UNTAGGED heap pointer
        // (freeing the tagged value would corrupt the heap).
        drop.onAllocPointer(fc, v.dst, ptr);
    } else {
        // Native slot kind is .closure: record the TAGGED value; the drop calls
        // kira_destroy_closure, which untags and runs the typed capture teardown.
        drop.onAlloc(fc, v.dst);
    }
}

// Deep-clone a by-value (.copy) capture so the closure block owns independent
// storage: kira_clone_<T> for structs, kira_array_clone for arrays,
// kira_enum_clone for enum blocks, kira_capi_closure_clone for nested closures
// (tag-safe: a plain FFI pointer passes through). A struct type without helpers
// falls back to the historical alias (conservative: never freed by release).
fn cloneCaptureValue(fc: *FunctionCodegen, ty: ir.ValueType, value: llvm.c.LLVMValueRef) llvm.c.LLVMValueRef {
    const api = fc.api;
    const b = fc.builder;
    switch (ty.kind) {
        .ffi_struct => {
            const name = ty.name orelse return value;
            const helpers = fc.dtors.map.get(name) orelse return value;
            var args = [_]llvm.c.LLVMValueRef{value};
            return api.LLVMBuildCall2(b, helpers.clone.ty, helpers.clone.fn_value, &args, args.len, "capture.struct.clone");
        },
        .array => {
            const ptr = api.LLVMBuildIntToPtr(b, value, fc.types.ptr_ty, "capture.arr.src");
            const elem = fc.dtors.elementClone(fc.request.program.programPtr(), ty);
            var args = [_]llvm.c.LLVMValueRef{ ptr, elem orelse api.LLVMConstNull(fc.types.ptr_ty) };
            const clone = api.LLVMBuildCall2(b, fc.runtime_decls.array_clone.ty, fc.runtime_decls.array_clone.fn_value, &args, args.len, "capture.arr.clone");
            return api.LLVMBuildPtrToInt(b, clone, fc.types.i64, "capture.arr.cloneint");
        },
        .enum_instance => {
            const ptr = api.LLVMBuildIntToPtr(b, value, fc.types.ptr_ty, "capture.enum.src");
            const clone_fn = fc.dtors.enumCloneFn(ty);
            var args = [_]llvm.c.LLVMValueRef{ptr};
            const clone = api.LLVMBuildCall2(b, clone_fn.ty, clone_fn.fn_value, &args, args.len, "capture.enum.clone");
            return api.LLVMBuildPtrToInt(b, clone, fc.types.i64, "capture.enum.cloneint");
        },
        .raw_ptr => {
            var args = [_]llvm.c.LLVMValueRef{value};
            return api.LLVMBuildCall2(b, fc.dtors.closure_clone.ty, fc.dtors.closure_clone.fn_value, &args, args.len, "capture.closure.clone");
        },
        else => return value,
    }
}

pub fn lowerCallValue(fc: *FunctionCodegen, v: ir.CallValue) !void {
    const api = fc.api;
    const b = fc.builder;
    const hash = dispatch.hashCallValueSignature(v.param_types, v.return_type);
    const decl = fc.dispatchers.get(hash) orelse return error.MissingFunctionDeclaration;
    const args = try fc.allocator.alloc(llvm.c.LLVMValueRef, v.args.len + 1);
    defer fc.allocator.free(args);
    args[0] = fc.registers[v.callee];
    // A closure body is an ordinary function: when an owned/move struct argument reaches it,
    // the callee fully owns and drops it (struct params are struct_heap in native mode), so
    // the closure call must move the struct in just like a direct Call — hand over a
    // caller-stable heap shell and relinquish it, or both sides free it (double free).
    // Closures-as-arguments and other kinds are still borrow-passed: the dispatcher does not
    // drop them, so escaping would leak.
    if (fc.drop_enabled and fc.request.mode == .llvm_native) {
        for (v.args, 0..) |arg, i| {
            const mode = if (i < v.param_ownership.len) v.param_ownership[i] else ir.OwnershipMode.owned;
            switch (mode) {
                .owned, .move => {},
                else => continue,
            }
            const pt = if (i < v.param_types.len) v.param_types[i] else continue;
            if (pt.kind != .ffi_struct) continue;
            const name = pt.name orelse continue;
            if (fc.dtors.map.get(name) == null) continue;
            fc.registers[arg] = drop.moveOrCloneToHeap(fc, arg, name);
        }
    }
    for (v.args, 0..) |arg, index| args[index + 1] = fc.registers[arg];
    const result = api.LLVMBuildCall2(b, decl.fn_ty, decl.fn_value, args.ptr, @intCast(args.len), "");
    // HYBRID: a call-value reaching its callee marshals owned/move AGGREGATE args across the
    // dispatcher, and the callee takes ownership of their nested heap and frees it — a VM
    // closure frees the bridge-shared storage, and a native closure body drops its owned
    // struct/array param at exit. The native caller must therefore relinquish these args, or
    // the same nested storage is freed twice: once by the callee, once by native scope-exit
    // cleanup. (Native mode already hands struct args over via moveOrCloneToHeap above.) Only
    // ffi_struct/array carry heap contents that double-free; enums are Copy across the
    // boundary and closure/raw args are borrow-passed by the dispatcher, so both stay tracked
    // (escaping them would leak — nothing else frees them). This is the `Graphics { backend:
    // GraphicsBackend.Metal }` moved into onInit/onFrame/onCleanup that aborted the Metal
    // backend's hybrid app on exit (POINTER_BEING_FREED_WAS_NOT_ALLOCATED: the backend enum
    // freed by the closure, then again by kira_release_contents_Graphics at scope exit).
    if (fc.drop_enabled and fc.request.mode == .hybrid) {
        for (v.args, 0..) |arg, i| {
            const mode = if (i < v.param_ownership.len) v.param_ownership[i] else ir.OwnershipMode.owned;
            switch (mode) {
                .owned, .move => {},
                else => continue,
            }
            const kind = if (arg < fc.register_types.len) fc.register_types[arg].kind else continue;
            switch (kind) {
                .ffi_struct, .array => drop.onEscape(fc, arg),
                else => {},
            }
        }
    }
    // Other argument kinds are intentionally NOT drop-escaped here. The call_value dispatcher
    // does not run a callee owned-param drop for them (e.g. a closure passed by value), so
    // escaping would leak — nothing would free it. The caller keeps ownership (borrow-pass);
    // conservative — never a double-free.
    if (v.dst) |dst| {
        fc.registers[dst] = result;
        // A native callback's owned-aggregate result is fresh caller-stable heap the caller
        // drops. In HYBRID, a call through a runtime callback returns a VM-OWNED value (the
        // VM allocated and still tracks it); tracking it for the native drop would free it
        // twice (native + VM). Skip tracking in hybrid — conservative: may leak, never
        // double-frees.
        if (fc.request.mode != .hybrid) {
            switch (v.return_type.kind) {
                .ffi_struct, .array => drop.onAlloc(fc, dst),
                // A returned string is always a fresh owned buffer (the callee's
                // `ret` clones untracked sources); record it for scope-exit free.
                .string => drop.trackStringRegister(fc, dst),
                // A returned closure is a fresh owned block (the callee's `ret`
                // clones untracked closure sources); tag-safe .closure drop.
                .raw_ptr => drop.onAlloc(fc, dst),
                else => {},
            }
        }
    }
}
