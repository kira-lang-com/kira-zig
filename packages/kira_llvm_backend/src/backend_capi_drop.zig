// Owned-value cleanup-slot drop driver for the LLVM C-API backend. Consumes the
// per-type destructor/clone helpers generated in backend_capi_destructors.zig and
// implements the runtime ownership model over FunctionCodegen: move/clone into
// caller-stable storage, owned-param drop, call-result tracking, loop-body and
// overwrite drops, and owned-closure-param drop.
//
// Cleanup slots are entry-block allocas, so they dominate every basic block — this
// is what lets the C-API backend free owned values without the "instruction does not
// dominate all uses" problem that defeated the textual writer's clone attempts.
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const destructors = @import("backend_capi_destructors.zig");

// Per-type destructor/clone generation lives in backend_capi_destructors.zig; re-export
// the public surface so callers (and this driver) keep using `drop.Destructors`/`drop.build`.
pub const TypeHelpers = destructors.TypeHelpers;
pub const Destructors = destructors.Destructors;
pub const build = destructors.build;

// ----- owned-value cleanup-slot drop (gated behind FunctionCodegen.drop_enabled) -----
// A cleanup slot is an entry-block `alloca ptr` (init null) holding a live owned
// heap pointer. At function exit every non-null slot is freed with the right
// destructor. Slots dominate all blocks, so this is free of the "does not dominate"
// problem; moves/escapes null the slot so each value is freed at most once.
const FunctionCodegen = @import("backend_capi_codegen.zig").FunctionCodegen;

// string_buf: the slot holds a string's malloc'd BYTE BUFFER (field 0 of the
// {ptr,len} register value), freed with plain free(). Strings are deep values:
// every producer (CString coercion, concat, aggregate read, call result) owns a
// fresh buffer tracked by its own slot; every consumer (aggregate store, capture,
// enum payload) clones; there are no string moves and no aliasing. Strings are
// deliberately EXCLUDED from the local_slot register<->local mapping — with
// clone-always consumers a producer slot is the buffer's sole owner, and mapping
// through locals would re-create the branch-reassignment F1 bug (exit cleanup
// freeing the buffer of whichever branch's slot was lowered last).
pub const OwnedKind = enum { array, struct_heap, struct_ptr, raw, struct_contents, closure, string_buf };
pub const OwnedSlot = struct {
    alloca: llvm.c.LLVMValueRef,
    kind: OwnedKind,
    ty: ir.ValueType,
};

// The entry-block cleanup-slot pre-scan lives in backend_capi_drop_slots.zig
// (Core Law #5); re-export its surface so callers keep using `drop.setup(...)`.
const slots = @import("backend_capi_drop_slots.zig");
pub const setup = slots.setup;
pub const seedOwnedParams = slots.seedOwnedParams;
pub const teardown = slots.teardown;

// Record the runtime pointer of a freshly heap-allocated owned value into its
// pre-allocated cleanup slot (slot index was seeded in setup).
pub fn onAlloc(fc: *FunctionCodegen, dst: u32) void {
    if (!fc.drop_enabled) return;
    if (dst >= fc.register_slot.len) return;
    const index = fc.register_slot[dst] orelse return;
    const api = fc.api;
    dropPriorOccupant(fc, index);
    const ptr = api.LLVMBuildIntToPtr(fc.builder, fc.registers[dst], fc.types.ptr_ty, "drop.own");
    _ = api.LLVMBuildStore(fc.builder, ptr, fc.drop_slots.items[index].alloca);
}

// Like onAlloc but records a caller-supplied ptr-typed value instead of the dst
// register. Closures carry a high-bit tag in their register, so the real heap
// pointer (the untagged malloc result) must be recorded — freeing the tagged
// value would corrupt the heap.
pub fn onAllocPointer(fc: *FunctionCodegen, dst: u32, pointer: llvm.c.LLVMValueRef) void {
    if (!fc.drop_enabled) return;
    if (dst >= fc.register_slot.len) return;
    const index = fc.register_slot[dst] orelse return;
    dropPriorOccupant(fc, index);
    _ = fc.api.LLVMBuildStore(fc.builder, pointer, fc.drop_slots.items[index].alloca);
}

fn nullSlot(fc: *FunctionCodegen, index: u32) void {
    _ = fc.api.LLVMBuildStore(fc.builder, fc.api.LLVMConstNull(fc.types.ptr_ty), fc.drop_slots.items[index].alloca);
}

// `reg`'s value escapes the function (returned / consumed): stop tracking it.
pub fn onEscape(fc: *FunctionCodegen, reg: u32) void {
    if (!fc.drop_enabled) return;
    if (reg < fc.register_slot.len) {
        if (fc.register_slot[reg]) |index| nullSlot(fc, index);
    }
}

fn moveStructToHeap(fc: *FunctionCodegen, src_val: llvm.c.LLVMValueRef, name: ?[]const u8) llvm.c.LLVMValueRef {
    const api = fc.api;
    const b = fc.builder;
    const struct_ty = if (name) |n| fc.struct_types.get(n) orelse return src_val else return src_val;
    var margs = [_]llvm.c.LLVMValueRef{
        api.LLVMConstInt(fc.types.i64, ir.nativeStateTypeId(name.?), 0),
        fc.types.sizeArg(b, api.LLVMSizeOf(struct_ty)),
    };
    const heap = api.LLVMBuildCall2(b, fc.runtime_decls.struct_alloc.ty, fc.runtime_decls.struct_alloc.fn_value, &margs, margs.len, "ret.heap");
    const src_ptr = api.LLVMBuildIntToPtr(b, src_val, fc.types.ptr_ty, "ret.src");
    const val = api.LLVMBuildLoad2(b, struct_ty, src_ptr, "ret.val");
    _ = api.LLVMBuildStore(b, val, heap);
    return api.LLVMBuildPtrToInt(b, heap, fc.types.i64, "ret.heapint");
}

// Lower the value of an ffi_struct `return src`. The caller must receive storage that
// outlives the callee frame and that it solely owns. Three cases by how `src` is
// tracked, cheapest first:
//   struct_heap     — already caller-stable heap (a call result or alloc_struct):
//                     hand the pointer over and escape the slot (no copy).
//   struct_contents — stack-backed local: move the shell into fresh heap storage (a
//                     shallow field copy; the owned arrays move with it) and escape,
//                     so exit cleanup does not release the contents now owned by heap.
//   untracked       — a borrow or a directly-returned owned param: deep-clone into
//                     independent heap storage (the only safe option when the source
//                     is not a tracked owned temporary).
// In every case the returned pointer is an owned heap struct the caller frees.
pub fn prepareStructReturn(fc: *FunctionCodegen, src_reg: u32) llvm.c.LLVMValueRef {
    return moveOrCloneToHeap(fc, src_reg, fc.function_decl.return_type.name);
}

// Produce a caller-stable owned heap pointer for the ffi_struct in `src_reg`, consuming
// the source. Shared by struct returns and Rust-style array-element moves. `type_name`
// is the destination struct type (used only for the borrow->clone fallback). Cases:
//   struct_heap     — already owned heap: hand the pointer over, escape the slot.
//   struct_contents — stack-backed owned local: move the shell into fresh heap storage
//                     (arrays move with it), escape the slot.
//   untracked       — a borrow: deep-clone into independent heap storage (source intact).
pub fn moveOrCloneToHeap(fc: *FunctionCodegen, src_reg: u32, type_name: ?[]const u8) llvm.c.LLVMValueRef {
    const api = fc.api;
    const b = fc.builder;
    const src_val = fc.registers[src_reg];
    if (src_reg < fc.register_slot.len) {
        if (fc.register_slot[src_reg]) |idx| {
            switch (fc.drop_slots.items[idx].kind) {
                .struct_heap => {
                    nullSlot(fc, idx);
                    return src_val;
                },
                // A tracked type-erased value (fresh-Any call result, moved-out
                // Any field) is already an owned heap shell: MOVE it. Cloning
                // here would deep-copy a widget tree per consuming dispatch —
                // the exact unbounded copy the memory model forbids — and leak
                // the interior clones (Any fields alias on struct copy).
                .struct_ptr => {
                    nullSlot(fc, idx);
                    return src_val;
                },
                .struct_contents => {
                    const heap = moveStructToHeap(fc, src_val, fc.drop_slots.items[idx].ty.name);
                    nullSlot(fc, idx);
                    return heap;
                },
                else => {},
            }
        }
    }
    if (type_name) |name| {
        if (fc.dtors.map.get(name)) |h| {
            var ca = [_]llvm.c.LLVMValueRef{src_val};
            return api.LLVMBuildCall2(b, h.clone.ty, h.clone.fn_value, &ca, ca.len, "heap.clone");
        }
    }
    return src_val;
}

pub fn onStoreLocal(fc: *FunctionCodegen, local: u32, src: u32, borrow: bool) void {
    if (!fc.drop_enabled) return;
    // Owned enum local: move ownership of the stored enum block into the local's
    // dedicated per-local cleanup slot (allocated in setup). This is the analogue of
    // onCopyDest for structs. Only a tracked, owned, non-reborrow source transfers:
    // a reborrow (`borrow`) or an untracked source (a borrow has no producer slot)
    // must not be recorded, or exit cleanup would free storage the local does not own.
    if (!borrow and local < fc.enum_local_slot.len) {
        if (fc.enum_local_slot[local]) |index| {
            if (src < fc.register_slot.len and fc.register_slot[src] != null) {
                // Drop the local's prior live value before overwriting it (reassignment /
                // loop re-entry); null-safe on the first store.
                dropPriorOccupant(fc, index);
                const ptr = fc.api.LLVMBuildIntToPtr(fc.builder, fc.registers[src], fc.types.ptr_ty, "drop.enumlocal");
                _ = fc.api.LLVMBuildStore(fc.builder, ptr, fc.drop_slots.items[index].alloca);
                // Ownership moved out of the source's slot (a fresh alloc_enum producer,
                // a call result, or another enum local) into this per-local slot.
                onEscape(fc, src);
                fc.local_slot[local] = index;
                return;
            }
        }
    }
    // Strings never flow through the register<->local map. The map is COMPILE-TIME
    // state: a `var s` reassigned in two branches would leave local_slot pointing at
    // whichever branch was lowered last, and exit cleanup would free the OTHER
    // branch's live buffer when `s` is returned (the enum F1 bug, re-created).
    // Strings don't need the map — consumers always clone and `ret` clones any
    // untracked source, so a producer slot freeing its own buffer at exit is
    // always correct.
    if (local < fc.function_decl.local_types.len and fc.function_decl.local_types[local].kind == .string) return;
    if (src < fc.register_slot.len and local < fc.local_slot.len) fc.local_slot[local] = fc.register_slot[src];
}

// A string local was just assigned `cloned` (a fresh deep copy made at the
// store_local site): drop the local's prior clone (reassignment / loop re-entry;
// free(null) no-ops the first store) and record the new buffer in the per-local
// slot. Does NOT touch the register<->local map — string registers stay tracked
// by their own producer slots.
pub fn onStoreLocalString(fc: *FunctionCodegen, local: u32, cloned: llvm.c.LLVMValueRef) void {
    if (!fc.drop_enabled) return;
    if (local >= fc.string_local_slot.len) return;
    const index = fc.string_local_slot[local] orelse return;
    dropPriorOccupant(fc, index);
    const buf = fc.api.LLVMBuildExtractValue(fc.builder, cloned, 0, "drop.strlocal");
    _ = fc.api.LLVMBuildStore(fc.builder, buf, fc.drop_slots.items[index].alloca);
}

// Does this string local own its stored clones (i.e. was a per-local slot created)?
pub fn hasStringLocalSlot(fc: *FunctionCodegen, local: u32) bool {
    return fc.drop_enabled and local < fc.string_local_slot.len and fc.string_local_slot[local] != null;
}

pub fn onLoadLocal(fc: *FunctionCodegen, dst: u32, local: u32) void {
    if (!fc.drop_enabled) return;
    // See onStoreLocal: strings are excluded from the register<->local map.
    if (local < fc.function_decl.local_types.len and fc.function_decl.local_types[local].kind == .string) return;
    if (dst < fc.register_slot.len and local < fc.local_slot.len) fc.register_slot[dst] = fc.local_slot[local];
}

pub fn onMoveLocal(fc: *FunctionCodegen, local: u32) void {
    if (!fc.drop_enabled) return;
    if (local >= fc.local_slot.len) return;
    const index = fc.local_slot[local] orelse return;
    nullSlot(fc, index);
}

// A copy_indirect moved a struct local's CONTENTS out (`var next = move tree`).
// When the source local is tracked as an owned heap shell (.struct_heap — an
// owned param the caller normalized to heap, or an alloc/call result), the
// shallow copy transfers the contents but leaves the empty 8-byte-header shell
// with no owner: onMoveLocal nulls the slot (correct — exit cleanup must not
// deep-destroy the moved contents) and nothing else references the shell — one
// leaked shell per move (the rebuild(move tree) loop). Free the SHELL ONLY
// (kira_struct_free, no contents destroy) before the slot is nulled. A
// .struct_contents source is stack-backed — nothing to free.
pub fn onMoveLocalHeapShell(fc: *FunctionCodegen, local: u32, src_ptr: llvm.c.LLVMValueRef) void {
    if (!fc.drop_enabled) return;
    if (local >= fc.local_slot.len) return;
    const index = fc.local_slot[local] orelse return;
    if (fc.drop_slots.items[index].kind != .struct_heap) return;
    var args = [_]llvm.c.LLVMValueRef{src_ptr};
    _ = fc.api.LLVMBuildCall2(fc.builder, fc.runtime_decls.struct_free.ty, fc.runtime_decls.struct_free.fn_value, &args, args.len, "");
}

// Is `reg` a tracked, owned (freshly allocated, not borrowed) value?
pub fn isOwned(fc: *FunctionCodegen, reg: u32) bool {
    return fc.drop_enabled and reg < fc.register_slot.len and fc.register_slot[reg] != null;
}

// Deep-copy a {ptr,len} string register value via kira_capi_string_clone; the
// result carries a fresh malloc'd buffer (null buffer clones to null). This is
// the one primitive every string consumer uses: aggregate stores, closure
// captures, enum payload boxing, borrowed returns, and clone-on-read.
pub fn cloneStringValue(fc: *FunctionCodegen, value: llvm.c.LLVMValueRef) llvm.c.LLVMValueRef {
    const api = fc.api;
    const b = fc.builder;
    const buf = api.LLVMBuildExtractValue(b, value, 0, "str.clone.src");
    const len = api.LLVMBuildExtractValue(b, value, 1, "str.clone.len");
    var args = [_]llvm.c.LLVMValueRef{ buf, len };
    const clone = api.LLVMBuildCall2(b, fc.dtors.string_clone.ty, fc.dtors.string_clone.fn_value, &args, args.len, "str.clone");
    return api.LLVMBuildInsertValue(b, value, clone, 0, "str.clone.val");
}

// Record dst's string buffer (field 0 of the {ptr,len} value) into its
// pre-allocated string_buf cleanup slot. No-op when dst has no slot (drop off,
// or the instruction was not a string producer).
pub fn trackStringRegister(fc: *FunctionCodegen, dst: u32) void {
    if (!fc.drop_enabled) return;
    if (dst >= fc.register_slot.len or fc.register_slot[dst] == null) return;
    const buf = fc.api.LLVMBuildExtractValue(fc.builder, fc.registers[dst], 0, "str.own");
    onAllocPointer(fc, dst, buf);
}

// Free every still-live owned value. Emitted at each function return + fallthrough.
// Free the value currently held in cleanup slot `index` with its kind's destructor.
// Every destructor is null-safe, so calling this on an already-null / escaped slot is
// a no-op. Used both at exit and for drop-before-overwrite (loop re-production).
fn freeSlot(fc: *FunctionCodegen, index: u32) void {
    const api = fc.api;
    const b = fc.builder;
    const owned = fc.drop_slots.items[index];
    const ptr = api.LLVMBuildLoad2(b, fc.types.ptr_ty, owned.alloca, "drop.load");
    switch (owned.kind) {
        .array => {
            const elem = fc.dtors.elementDestroy(fc.request.program.programPtr(), owned.ty);
            var args = [_]llvm.c.LLVMValueRef{ ptr, elem orelse api.LLVMConstNull(fc.types.ptr_ty) };
            _ = api.LLVMBuildCall2(b, fc.runtime_decls.array_release.ty, fc.runtime_decls.array_release.fn_value, &args, args.len, "");
        },
        .struct_heap => {
            const destroy = if (owned.ty.name) |n| (if (fc.dtors.map.get(n)) |h| h.destroy else fc.dtors.destroy_struct_ptr) else fc.dtors.destroy_struct_ptr;
            var args = [_]llvm.c.LLVMValueRef{ptr};
            _ = api.LLVMBuildCall2(b, destroy.ty, destroy.fn_value, &args, args.len, "");
        },
        .struct_ptr => {
            // Runtime-typed full destroy on the native path (the shell's type-id
            // header recovers kira_destroy_<T>, so contents free too — the old
            // shell-only kira_destroy_struct_ptr leaked every field). Unknown ids
            // no-op (consistent with dynamic clone's alias fallback). Hybrid keeps
            // the shell-only free.
            if (fc.dtors.deep_closures) {
                const as_int = api.LLVMBuildPtrToInt(b, ptr, fc.types.i64, "drop.any.int");
                var args = [_]llvm.c.LLVMValueRef{as_int};
                _ = api.LLVMBuildCall2(b, fc.dtors.dynamic_destroy.ty, fc.dtors.dynamic_destroy.fn_value, &args, args.len, "");
            } else {
                var args = [_]llvm.c.LLVMValueRef{ptr};
                _ = api.LLVMBuildCall2(b, fc.dtors.destroy_struct_ptr.ty, fc.dtors.destroy_struct_ptr.fn_value, &args, args.len, "");
            }
        },
        .raw => {
            // Typed enum slots (string-payload enums, native) free the payload
            // box + buffer with the block; everything else keeps plain free.
            const destroy = if (owned.ty.kind == .enum_instance) fc.dtors.enumDestroyFn(owned.ty) else fc.dtors.destroy_raw_ptr;
            var args = [_]llvm.c.LLVMValueRef{ptr};
            _ = api.LLVMBuildCall2(b, destroy.ty, destroy.fn_value, &args, args.len, "");
        },
        .closure => {
            // The slot holds the (possibly tag-bit-set) closure value as a pointer;
            // pass it back as i64 to the tag-safe destructor.
            const as_int = api.LLVMBuildPtrToInt(b, ptr, fc.types.i64, "drop.closure.int");
            var args = [_]llvm.c.LLVMValueRef{as_int};
            _ = api.LLVMBuildCall2(b, fc.dtors.destroy_closure.ty, fc.dtors.destroy_closure.fn_value, &args, args.len, "");
        },
        .struct_contents => {
            // Stack-backed struct copy: release its nested fields (arrays/sub-structs)
            // but do NOT free the shell — the backing storage is an entry-block alloca.
            if (owned.ty.name) |n| {
                if (fc.dtors.map.get(n)) |h| {
                    var args = [_]llvm.c.LLVMValueRef{ptr};
                    _ = api.LLVMBuildCall2(b, h.release_contents.ty, h.release_contents.fn_value, &args, args.len, "");
                }
            }
        },
        .string_buf => {
            // The slot holds the string's malloc'd byte buffer; plain free
            // (free(null) no-ops an unproduced/escaped slot).
            var args = [_]llvm.c.LLVMValueRef{ptr};
            _ = api.LLVMBuildCall2(b, fc.runtime_decls.free.ty, fc.runtime_decls.free.fn_value, &args, args.len, "");
        },
    }
}

pub fn emitExitCleanup(fc: *FunctionCodegen, returned: ?u32) void {
    if (!fc.drop_enabled) return;
    const returned_slot: ?u32 = if (returned) |r| (if (r < fc.register_slot.len) fc.register_slot[r] else null) else null;
    for (fc.drop_slots.items, 0..) |_, index| {
        if (returned_slot != null and returned_slot.? == @as(u32, @intCast(index))) continue;
        freeSlot(fc, @intCast(index));
    }
}

// Drop-before-overwrite: a value produced into cleanup slot `index` inside a loop
// overwrites the previous iteration's value. Free the prior occupant first so each
// iteration's value is reclaimed (the cleanup-slot model otherwise only frees the
// final occupant at function exit — the loop-body leak). Null-safe on first entry.
fn dropPriorOccupant(fc: *FunctionCodegen, index: u32) void {
    freeSlot(fc, index);
}

// Record a register->local association (from load_local / local_ptr) so a later
// copy_indirect can resolve which local its destination backing belongs to.
pub fn recordRegLocal(fc: *FunctionCodegen, reg: u32, local: u32) void {
    if (!fc.drop_enabled) return;
    if (reg < fc.reg_local.len) fc.reg_local[reg] = local;
}

// A copy_indirect deep-cloned `type_name` into the stack backing addressed by
// `dst_ptr` (the register), `dst_ptr_value` (its ptr value). The destination local
// now owns the cloned contents; track them so they are released at exit unless the
// local later escapes (a move/return/store nulls the slot through register_slot).
pub fn onCopyDest(fc: *FunctionCodegen, dst_ptr_reg: u32, dst_ptr_value: llvm.c.LLVMValueRef, type_name: []const u8) void {
    if (!fc.drop_enabled) return;
    if (fc.dtors.map.get(type_name) == null) return;
    const local = if (dst_ptr_reg < fc.reg_local.len) fc.reg_local[dst_ptr_reg] orelse return else return;
    const index = if (local < fc.copy_dest_slot.len) fc.copy_dest_slot[local] orelse return else return;
    _ = fc.api.LLVMBuildStore(fc.builder, dst_ptr_value, fc.drop_slots.items[index].alloca);
    fc.local_slot[local] = index;
}

// Drop-before-overwrite for a copy_indirect destination. A `copy_indirect` shallow-
// copies the source over the destination's stack shell, discarding whatever array
// pointers that shell already held; in a loop (`var x = ...` reassigned each
// iteration) the prior occupant's cloned contents would leak. Release them BEFORE the
// shallow store overwrites the shell. Null-safe on the first assignment (slot empty).
pub fn releasePriorCopyDest(fc: *FunctionCodegen, dst_ptr_reg: u32, type_name: []const u8) void {
    if (!fc.drop_enabled) return;
    if (fc.dtors.map.get(type_name) == null) return;
    const local = if (dst_ptr_reg < fc.reg_local.len) fc.reg_local[dst_ptr_reg] orelse return else return;
    const index = if (local < fc.copy_dest_slot.len) fc.copy_dest_slot[local] orelse return else return;
    dropPriorOccupant(fc, index);
}
