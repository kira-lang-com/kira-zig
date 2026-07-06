// Cleanup-slot allocation for the LLVM C-API backend's drop driver: the entry-block
// pre-scan that gives every owned-value producer (allocs, call results, field
// move-outs, string producers, per-local enum/string slots, owned params) its
// cleanup slot before any instruction is lowered. Split out of
// backend_capi_drop.zig (Core Law #5); the runtime driver that fills, escapes,
// and frees these slots stays there.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const runtime_utils = @import("backend_runtime_utils.zig");
const drop = @import("backend_capi_drop.zig");
const FunctionCodegen = @import("backend_capi_codegen.zig").FunctionCodegen;

const OwnedKind = drop.OwnedKind;

fn ownedKindFor(value_type: ir.ValueType) ?OwnedKind {
    return switch (value_type.kind) {
        .array => .array,
        .ffi_struct => .struct_heap,
        .construct_any => .struct_ptr,
        // closures/enums are raw heap blocks freed with plain free().
        .raw_ptr, .enum_instance => .raw,
        else => null,
    };
}

fn ownedProducer(instruction: ir.Instruction) ?struct { dst: u32, ty: ir.ValueType } {
    return switch (instruction) {
        .alloc_array => |v| .{ .dst = v.dst, .ty = v.ty },
        .alloc_struct => |v| .{ .dst = v.dst, .ty = .{ .kind = .ffi_struct, .name = v.type_name } },
        .alloc_enum => |v| .{ .dst = v.dst, .ty = .{ .kind = .enum_instance, .name = v.enum_type_name } },
        .const_closure => |v| .{ .dst = v.dst, .ty = .{ .kind = .raw_ptr } },
        else => null,
    };
}

// Pre-scan owned-producing instructions and allocate one cleanup slot per result
// in the entry block (so every slot dominates all exits), seeding register_slot.
// Call with the builder positioned at the entry block.
pub fn setup(fc: *FunctionCodegen) !void {
    fc.register_slot = try fc.allocator.alloc(?u32, fc.function_decl.register_count);
    @memset(fc.register_slot, null);
    fc.local_slot = try fc.allocator.alloc(?u32, fc.function_decl.local_count);
    @memset(fc.local_slot, null);
    fc.reg_local = try fc.allocator.alloc(?u32, fc.function_decl.register_count);
    @memset(fc.reg_local, null);
    fc.copy_dest_slot = try fc.allocator.alloc(?u32, fc.function_decl.local_count);
    @memset(fc.copy_dest_slot, null);
    fc.enum_local_slot = try fc.allocator.alloc(?u32, fc.function_decl.local_count);
    @memset(fc.enum_local_slot, null);
    fc.string_local_slot = try fc.allocator.alloc(?u32, fc.function_decl.local_count);
    @memset(fc.string_local_slot, null);
    fc.reg_field_ptr = try fc.allocator.alloc(bool, fc.function_decl.register_count);
    @memset(fc.reg_field_ptr, false);
    fc.reg_string_literal = try fc.allocator.alloc(bool, fc.function_decl.register_count);
    @memset(fc.reg_string_literal, false);
    if (!fc.drop_enabled) return;
    const api = fc.api;

    // Pre-scan: a register->local map (load_local/local_ptr) lets us see, for each
    // copy_indirect, which local backs its destination.
    const scan_reg_local = try fc.allocator.alloc(?u32, fc.function_decl.register_count);
    defer fc.allocator.free(scan_reg_local);
    @memset(scan_reg_local, null);

    for (fc.function_decl.instructions) |instruction| {
        switch (instruction) {
            .load_local => |v| if (v.dst < scan_reg_local.len) {
                scan_reg_local[v.dst] = v.local;
            },
            .local_ptr => |v| if (v.dst < scan_reg_local.len) {
                scan_reg_local[v.dst] = v.local;
            },
            .store_local => |v| {
                // One per-local cleanup slot for a string local: the local owns a deep
                // clone of every assigned value (made at the store_local site), the slot
                // drops the prior clone on reassignment, exit cleanup frees the final
                // one. A borrow store is a non-owning alias and is not tracked.
                if (!v.borrow and v.local < fc.function_decl.local_types.len and
                    fc.function_decl.local_types[v.local].kind == .string and
                    v.local < fc.string_local_slot.len and fc.string_local_slot[v.local] == null)
                {
                    const slot = api.LLVMBuildAlloca(fc.builder, fc.types.ptr_ty, "drop.strlocal.slot");
                    _ = api.LLVMBuildStore(fc.builder, api.LLVMConstNull(fc.types.ptr_ty), slot);
                    const index: u32 = @intCast(fc.drop_slots.items.len);
                    try fc.drop_slots.append(fc.allocator, .{ .alloca = slot, .kind = .string_buf, .ty = .{ .kind = .string } });
                    fc.string_local_slot[v.local] = index;
                }
                // One per-local cleanup slot for an owned enum local, reused across
                // reassignments. An enum value is a heap block (alloc_enum mallocs a
                // 16-byte { tag, payload }); a `var s: Enum` reassigned in branches would
                // otherwise leave its live value in whichever branch's per-producer slot
                // ran, and the return frees the wrong (last-lowered) slot — freeing the
                // live returned enum (the F1 use-after-free). A per-local slot tracks the
                // local's current value at runtime, so reassignment drops the dead value
                // and the live one is escaped on return regardless of which branch ran.
                // A reborrow store (`var r = <borrow>`) is a non-owning alias and must not
                // be tracked here; onStoreLocal also guards on borrow and on the source
                // being a tracked owned value before it routes through this slot.
                if (v.borrow) continue;
                if (v.local >= fc.function_decl.local_types.len) continue;
                if (fc.function_decl.local_types[v.local].kind != .enum_instance) continue;
                if (v.local >= fc.enum_local_slot.len or fc.enum_local_slot[v.local] != null) continue;
                const slot = api.LLVMBuildAlloca(fc.builder, fc.types.ptr_ty, "drop.enumlocal.slot");
                _ = api.LLVMBuildStore(fc.builder, api.LLVMConstNull(fc.types.ptr_ty), slot);
                const index: u32 = @intCast(fc.drop_slots.items.len);
                try fc.drop_slots.append(fc.allocator, .{ .alloca = slot, .kind = .raw, .ty = fc.function_decl.local_types[v.local] });
                fc.enum_local_slot[v.local] = index;
            },
            .copy_indirect => |v| {
                // One struct_contents cleanup slot per destination local (reused across
                // reassignments so the same backing is released at most once).
                if (fc.dtors.map.get(v.type_name) == null) continue;
                const local = if (v.dst_ptr < scan_reg_local.len) scan_reg_local[v.dst_ptr] orelse continue else continue;
                if (local >= fc.copy_dest_slot.len or fc.copy_dest_slot[local] != null) continue;
                const slot = api.LLVMBuildAlloca(fc.builder, fc.types.ptr_ty, "drop.contents.slot");
                _ = api.LLVMBuildStore(fc.builder, api.LLVMConstNull(fc.types.ptr_ty), slot);
                const index: u32 = @intCast(fc.drop_slots.items.len);
                try fc.drop_slots.append(fc.allocator, .{ .alloca = slot, .kind = .struct_contents, .ty = .{ .kind = .ffi_struct, .name = v.type_name } });
                fc.copy_dest_slot[local] = index;
            },
            .call => |v| {
                // A native call returning an owned aggregate yields fresh caller-stable
                // heap storage (an ffi_struct the callee moved/cloned out, or a heap
                // array). Track it so the caller frees it at scope exit unless it is
                // consumed/moved first (onEscape nulls the slot; a direct return skips it).
                const dst = v.dst orelse continue;
                const callee = runtime_utils.functionById(fc.request.program.programPtr().*, v.callee) orelse continue;
                const kind: OwnedKind = switch (callee.return_type.kind) {
                    .ffi_struct => .struct_heap,
                    .array => .array,
                    // A returned enum is a fresh heap block the callee (or, for a hybrid
                    // call into the VM, `lowerEnumToNativeOwned`) handed over as a libc-
                    // allocated `{tag,payload}`; the caller owns it and frees it at scope
                    // exit unless it is moved on (a store into a field moves it; a borrow-
                    // arg pass keeps it). Tracked in hybrid too: the runtime no longer
                    // double-frees these (see HybridRuntime.cleanupPendingCallbackReturns),
                    // which also reclaims the per-frame `graphicsEventKindFromRaw`/
                    // `...ButtonFromRaw` enum that previously leaked.
                    .enum_instance => .raw,
                    // A returned string is ALWAYS a fresh owned buffer: a callee's `ret`
                    // clones an untracked (literal/borrowed) source before returning, and
                    // a hybrid runtime call clones the VM-owned result (lowerRuntimeCall).
                    .string => .string_buf,
                    else => continue,
                };
                if (dst >= fc.register_slot.len or fc.register_slot[dst] != null) continue;
                const slot = api.LLVMBuildAlloca(fc.builder, fc.types.ptr_ty, "drop.callret.slot");
                _ = api.LLVMBuildStore(fc.builder, api.LLVMConstNull(fc.types.ptr_ty), slot);
                const index: u32 = @intCast(fc.drop_slots.items.len);
                try fc.drop_slots.append(fc.allocator, .{ .alloca = slot, .kind = kind, .ty = callee.return_type });
                fc.register_slot[dst] = index;
            },
            .load_indirect => |v| {
                // A string field read is a CLONE-on-read (strings are deep values):
                // dst owns a fresh buffer and needs a slot regardless of `moved`.
                if (v.ty.kind == .string) {
                    try allocStringSlot(fc, v.dst, "drop.strload.slot");
                    continue;
                }
                // A checker-verified field move-out transfers ownership to dst: the
                // codegen nulls the field storage after the read, so dst is the sole
                // owner and needs a cleanup slot for scope exit.
                if (!v.moved) continue;
                const kind: OwnedKind = switch (v.ty.kind) {
                    .array => .array,
                    .enum_instance => .raw,
                    else => continue,
                };
                if (v.dst >= fc.register_slot.len or fc.register_slot[v.dst] != null) continue;
                const slot = api.LLVMBuildAlloca(fc.builder, fc.types.ptr_ty, "drop.fieldmove.slot");
                _ = api.LLVMBuildStore(fc.builder, api.LLVMConstNull(fc.types.ptr_ty), slot);
                const index: u32 = @intCast(fc.drop_slots.items.len);
                try fc.drop_slots.append(fc.allocator, .{ .alloca = slot, .kind = kind, .ty = v.ty });
                fc.register_slot[v.dst] = index;
            },
            .native_state_field_get => |v| {
                // Clone-on-read for a string payload slot, `moved` or not.
                if (v.field_ty.kind == .string) {
                    try allocStringSlot(fc, v.dst, "drop.strstate.slot");
                    continue;
                }
                // Same field move-out rule for a native-state payload slot.
                if (!v.moved) continue;
                const kind: OwnedKind = switch (v.field_ty.kind) {
                    .array => .array,
                    .enum_instance => .raw,
                    else => continue,
                };
                if (v.dst >= fc.register_slot.len or fc.register_slot[v.dst] != null) continue;
                const slot = api.LLVMBuildAlloca(fc.builder, fc.types.ptr_ty, "drop.statemove.slot");
                _ = api.LLVMBuildStore(fc.builder, api.LLVMConstNull(fc.types.ptr_ty), slot);
                const index: u32 = @intCast(fc.drop_slots.items.len);
                try fc.drop_slots.append(fc.allocator, .{ .alloca = slot, .kind = kind, .ty = v.field_ty });
                fc.register_slot[v.dst] = index;
            },
            // Strings-are-deep-values producers: each owns a fresh malloc'd buffer.
            .c_string_to_string => |v| try allocStringSlot(fc, v.dst, "drop.cstr.slot"),
            // String concatenation (`+` with string operands) mallocs the result
            // buffer. register_types is inferred before setup runs (see lower()).
            .add => |v| {
                if (v.dst < fc.register_types.len and fc.register_types[v.dst].kind == .string) {
                    try allocStringSlot(fc, v.dst, "drop.scat.slot");
                }
            },
            .array_get => |v| {
                if (v.ty.kind == .string) try allocStringSlot(fc, v.dst, "drop.strelem.slot");
            },
            .enum_payload => |v| {
                if (v.payload_ty.kind == .string) try allocStringSlot(fc, v.dst, "drop.strpayload.slot");
            },
            .call_value => |v| {
                // A closure call returning an owned aggregate yields caller-stable heap
                // storage, same as a direct call; track it for drop.
                const dst = v.dst orelse continue;
                const kind: OwnedKind = switch (v.return_type.kind) {
                    .ffi_struct => .struct_heap,
                    .array => .array,
                    .enum_instance => .raw,
                    .string => .string_buf,
                    else => continue,
                };
                if (dst >= fc.register_slot.len or fc.register_slot[dst] != null) continue;
                const slot = api.LLVMBuildAlloca(fc.builder, fc.types.ptr_ty, "drop.cvret.slot");
                _ = api.LLVMBuildStore(fc.builder, api.LLVMConstNull(fc.types.ptr_ty), slot);
                const index: u32 = @intCast(fc.drop_slots.items.len);
                try fc.drop_slots.append(fc.allocator, .{ .alloca = slot, .kind = kind, .ty = v.return_type });
                fc.register_slot[dst] = index;
            },
            .call_virtual => |v| {
                const dst = v.dst orelse continue;
                const kind: OwnedKind = switch (v.return_ty.kind) {
                    .ffi_struct => .struct_heap,
                    .construct_any => .struct_ptr,
                    .array => .array,
                    .enum_instance => .raw,
                    .string => .string_buf,
                    else => continue,
                };
                if (dst >= fc.register_slot.len or fc.register_slot[dst] != null) continue;
                const slot = api.LLVMBuildAlloca(fc.builder, fc.types.ptr_ty, "drop.vret.slot");
                _ = api.LLVMBuildStore(fc.builder, api.LLVMConstNull(fc.types.ptr_ty), slot);
                const index: u32 = @intCast(fc.drop_slots.items.len);
                try fc.drop_slots.append(fc.allocator, .{ .alloca = slot, .kind = kind, .ty = v.return_ty });
                fc.register_slot[dst] = index;
            },
            else => {},
        }
        const producer = ownedProducer(instruction) orelse continue;
        const kind = ownedKindFor(producer.ty) orelse continue;
        const slot = api.LLVMBuildAlloca(fc.builder, fc.types.ptr_ty, "drop.slot");
        _ = api.LLVMBuildStore(fc.builder, api.LLVMConstNull(fc.types.ptr_ty), slot);
        const index: u32 = @intCast(fc.drop_slots.items.len);
        try fc.drop_slots.append(fc.allocator, .{ .alloca = slot, .kind = kind, .ty = producer.ty });
        if (producer.dst < fc.register_slot.len) fc.register_slot[producer.dst] = index;
    }

    // Owned aggregate parameters: a moved-in struct/array is owned by the callee, which
    // must drop it at scope exit unless it is moved out (returned/stored — which nulls
    // the slot through the param's local_slot). Allocate a cleanup slot per owned
    // ffi_struct/array param now; seedOwnedParams fills it once the params are bound.
    // A struct param releases only its contents (the shell is the caller's storage).
    for (fc.function_decl.param_types, 0..) |pt, i| {
        if (i >= fc.function_decl.param_ownership.len) break;
        switch (fc.function_decl.param_ownership[i]) {
            .owned, .move => {},
            else => continue,
        }
        const kind: OwnedKind = switch (pt.kind) {
            // A moved-in struct is fully owned by the callee (Rust move semantics): the
            // caller hands over a caller-stable heap shell (lowerCall normalizes any stack
            // source to heap) and relinquishes it, so the callee drops shell + contents at
            // exit (kira_destroy) unless it moves the value onward. This replaces the older
            // split model (callee releases only contents, caller keeps the shell) which
            // leaked every owned struct argument — neither side freed the shell.
            // HYBRID EXCEPTION: a struct value crossing the VM bridge is VM-managed, so the
            // native callee must not free its shell; keep the contents-only model there.
            .ffi_struct => if (pt.name != null and fc.dtors.map.get(pt.name.?) != null)
                (if (fc.request.mode == .hybrid) .struct_contents else .struct_heap)
            else
                continue,
            .array => .array,
            // A moved-in closure / heap value: the callee owns it and frees it at exit
            // (tag-safe so callable-values are a no-op). This reclaims owned closure
            // parameters whose blocks would otherwise leak after the caller escapes them.
            // HYBRID EXCEPTION: a closure/raw_ptr parameter of a native function may be a
            // VM-OWNED value the VM passed across the bridge (a VM closure is tagged for ABI
            // compat but its block is VM-managed). Freeing it here corrupts the VM heap, so
            // do not take ownership of closure/raw_ptr params in hybrid mode.
            .construct_any => if (fc.request.mode == .hybrid) continue else .struct_ptr,
            .raw_ptr => if (fc.request.mode == .hybrid) continue else .closure,
            else => continue,
        };
        const slot = api.LLVMBuildAlloca(fc.builder, fc.types.ptr_ty, "drop.param.slot");
        _ = api.LLVMBuildStore(fc.builder, api.LLVMConstNull(fc.types.ptr_ty), slot);
        const index: u32 = @intCast(fc.drop_slots.items.len);
        try fc.drop_slots.append(fc.allocator, .{ .alloca = slot, .kind = kind, .ty = pt });
        if (i < fc.local_slot.len) fc.local_slot[@intCast(i)] = index;
    }
}

// Allocate a string-buffer cleanup slot for `dst` (entry-block alloca, init null).
// The producing site records the buffer pointer via onAllocPointer once the value
// exists; a slot whose producer never runs (dead branch) stays null and free(null)
// is a no-op at exit.
fn allocStringSlot(fc: *FunctionCodegen, dst: u32, name: [:0]const u8) !void {
    if (dst >= fc.register_slot.len or fc.register_slot[dst] != null) return;
    const api = fc.api;
    const slot = api.LLVMBuildAlloca(fc.builder, fc.types.ptr_ty, name.ptr);
    _ = api.LLVMBuildStore(fc.builder, api.LLVMConstNull(fc.types.ptr_ty), slot);
    const index: u32 = @intCast(fc.drop_slots.items.len);
    try fc.drop_slots.append(fc.allocator, .{ .alloca = slot, .kind = .string_buf, .ty = .{ .kind = .string } });
    fc.register_slot[dst] = index;
}

// Seed each owned-aggregate param's cleanup slot with the param's runtime pointer.
// Must run after the params are bound to locals (still in the entry block, so the
// stores dominate every exit). Pairs with the owned-param slots allocated in setup.
pub fn seedOwnedParams(fc: *FunctionCodegen) void {
    if (!fc.drop_enabled) return;
    const api = fc.api;
    for (fc.function_decl.param_types, 0..) |pt, i| {
        if (i >= fc.function_decl.param_ownership.len) break;
        switch (fc.function_decl.param_ownership[i]) {
            .owned, .move => {},
            else => continue,
        }
        switch (pt.kind) {
            .ffi_struct, .array, .construct_any, .raw_ptr => {},
            else => continue,
        }
        if (i >= fc.local_slot.len) continue;
        const idx = fc.local_slot[@intCast(i)] orelse continue;
        const param = api.LLVMGetParam(fc.function_value, @intCast(i));
        const ptr = api.LLVMBuildIntToPtr(fc.builder, param, fc.types.ptr_ty, "param.own.ptr");
        _ = api.LLVMBuildStore(fc.builder, ptr, fc.drop_slots.items[idx].alloca);
    }
}

pub fn teardown(fc: *FunctionCodegen) void {
    fc.drop_slots.deinit(fc.allocator);
    fc.allocator.free(fc.register_slot);
    fc.allocator.free(fc.local_slot);
    fc.allocator.free(fc.reg_local);
    fc.allocator.free(fc.copy_dest_slot);
    fc.allocator.free(fc.enum_local_slot);
    fc.allocator.free(fc.string_local_slot);
    fc.allocator.free(fc.reg_field_ptr);
    fc.allocator.free(fc.reg_string_literal);
}
