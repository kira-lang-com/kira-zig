//! Native-layout destruction for the VM <-> native bridge.
//!
//! The release/teardown half of vm_native_bridge.zig: everything that frees a
//! native-layout struct, array, or enum block (including the `WithOwner`
//! variants that pick the VM vs C heap for the block itself), plus native-state
//! payload destruction (`destroyNativeStatePayload`, `freeNativeState`,
//! `deinitTrackedNativeStates`). Functions take the owning `Vm` as their first
//! parameter, mirroring the other split files; vm_native_bridge.zig re-exports
//! the public surface so call sites are unchanged.

const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const native_layout = @import("native_layout.zig");
const ownership = @import("ownership.zig");
const vm_mod = @import("vm.zig");
const bridge = @import("vm_native_bridge.zig");

const Vm = vm_mod.Vm;
const NativeStateBox = vm_mod.NativeStateBox;
const ArrayObject = ownership.ArrayObject;

/// Which heap owns a native-layout BLOCK: `.vm` blocks were allocated with the
/// VM allocator (`copyStructToNativeLayout` and friends), `.c` blocks with libc
/// `malloc` by native code (`kira_struct_alloc`, `kira_enum_clone`, ...). Element
/// payloads keep their own per-value owner while recursing.
pub const NativeLayoutOwner = enum {
    vm,
    c,
};

pub fn destroyArrayNativeLayout(self: *Vm, module: *const bytecode.Module, array_ty: bytecode.TypeRef, native_array_ptr: usize) void {
    destroyArrayNativeLayoutWithOwner(self, module, array_ty, native_array_ptr, .vm);
}

pub fn destroyOwnedArrayNativeLayout(self: *Vm, module: *const bytecode.Module, array_ty: bytecode.TypeRef, native_array_ptr: usize) void {
    destroyArrayNativeLayoutWithOwner(self, module, array_ty, native_array_ptr, .c);
}

pub fn destroyArrayNativeLayoutWithOwner(self: *Vm, module: *const bytecode.Module, array_ty: bytecode.TypeRef, native_array_ptr: usize, owner: NativeLayoutOwner) void {
    if (native_array_ptr == 0) return;
    const object: *ArrayObject = @ptrFromInt(native_array_ptr);
    const items = object.items[0..@max(object.cap, 1)];
    const element_ty = self.arrayElementType(module, array_ty) catch .{ .kind = .raw_ptr };
    // Elements keep the per-value `owner`: a native-owned array holds native-owned
    // elements (e.g. `kira_struct_alloc`'d struct elements with their 8-byte header),
    // which must be released by their own type-specific scheme.
    for (items[0..object.len]) |item| {
        destroyNativeLayoutValueWithOwner(self, module, element_ty, runtime_abi.bridgeValueToValue(item), owner);
    }
    // The array BLOCK (the `ArrayObject` and its `items` buffer) is always owned by
    // `self.allocator`, for BOTH owners: VM-built native arrays come straight from
    // `self.allocator` (`copyArrayToNativeLayout`), and native-built arrays come from
    // `kira_array_alloc` -> `kira_bridge_alloc`, whose installed hook
    // (`kira_hybrid_install_array_allocator`) is wired to this same allocator. (Unlike
    // `kira_struct_alloc`, the array helpers route through the installed VM allocator,
    // not raw libc.) Freeing the block with the C allocator hands libc an smp pointer
    // -> "pointer being freed was not allocated".
    self.allocator.free(items);
    self.allocator.destroy(object);
    bridge.recordNativeArrayFree(self);
}

pub fn destroyStructNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) void {
    destroyStructNativeLayoutWithOwner(self, module, type_name, native_ptr, .vm);
}

pub fn destroyOwnedStructNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) void {
    destroyStructNativeLayoutWithOwner(self, module, type_name, native_ptr, .c);
}

pub fn destroyStructNativeLayoutWithOwner(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize, owner: NativeLayoutOwner) void {
    if (native_ptr == 0) return;
    destroyStructNativeLayoutFieldsWithOwner(self, module, type_name, native_ptr, owner);
    const layout = native_layout.structLayout(module, type_name) catch return;
    const word_count = @max(1, std.math.divCeil(usize, layout.size, @sizeOf(u64)) catch unreachable);
    const words: [*]u64 = @ptrFromInt(native_ptr);
    const free_owner: NativeLayoutOwner = if (std.c.getenv("KIRA_RESULT_VM_FREE") != null) .vm else owner;
    switch (free_owner) {
        // VM-allocated native-layout structs (`copyStructToNativeLayout`) are a bare
        // `self.allocator.alloc(u64, ...)` with no header, so the payload pointer IS
        // the base.
        .vm => self.allocator.free(words[0..word_count]),
        // Native-owned structs (a `@Native`/native function result, or an owned heap
        // element of a native-returned array/enum) are produced by `kira_struct_alloc`
        // (runtime_helpers.c), which `malloc`s an 8-byte type-id header in front of the
        // payload and returns `base + 8`. The matching deallocator is `kira_struct_free`
        // = `free(ptr - 8)`. Freeing the payload pointer directly hands libc a non-base
        // address ("pointer being freed was not allocated"), so free the real malloc
        // base. The same `raw_ptr - @sizeOf(u64)` header convention is read in
        // vm_construct_any.zig.
        .c => std.c.free(@ptrFromInt(native_ptr - @sizeOf(u64))),
    }
    bridge.recordNativeStructFree(self);
}

pub fn destroyNativeLayoutValue(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value) void {
    destroyNativeLayoutValueWithOwner(self, module, ty, value, .vm);
}

pub fn destroyNativeLayoutValueWithOwner(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value, owner: NativeLayoutOwner) void {
    switch (ty.kind) {
        .ffi_struct => {
            if (value == .raw_ptr) {
                if (ty.name) |name| destroyStructNativeLayoutWithOwner(self, module, name, value.raw_ptr, owner);
            }
        },
        .array => {
            if (value == .raw_ptr) destroyArrayNativeLayoutWithOwner(self, module, ty, value.raw_ptr, owner);
        },
        .enum_instance => if (ty.name) |name| {
            if (value == .raw_ptr) destroyEnumNativeLayoutWithOwner(self, module, name, value.raw_ptr, owner);
        },
        .construct_any => self.heap.dropValue(value),
        else => {},
    }
}

pub fn destroyEnumNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) void {
    destroyEnumNativeLayoutWithOwner(self, module, type_name, native_ptr, .vm);
}

pub fn destroyOwnedEnumNativeLayout(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) void {
    destroyEnumNativeLayoutWithOwner(self, module, type_name, native_ptr, .c);
}

pub fn destroyEnumNativeLayoutWithOwner(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize, owner: NativeLayoutOwner) void {
    if (native_ptr == 0) return;
    const words: [*]u64 = @ptrFromInt(native_ptr);
    if (bridge.enumNativeVariant(self, module, type_name, words[0])) |native_variant| {
        destroyEnumNativePayloadWithOwner(self, module, native_variant.payload_ty, words[1], owner);
    }
    const native_words: []u64 = words[0..2];
    switch (owner) {
        .vm => self.allocator.free(native_words),
        .c => std.heap.c_allocator.free(native_words),
    }
}

pub fn destroyEnumNativePayload(self: *Vm, module: *const bytecode.Module, payload_ty: bytecode.TypeRef, word: u64) void {
    destroyEnumNativePayloadWithOwner(self, module, payload_ty, word, .vm);
}

pub fn destroyEnumNativePayloadWithOwner(self: *Vm, module: *const bytecode.Module, payload_ty: bytecode.TypeRef, word: u64, owner: NativeLayoutOwner) void {
    if (word == 0) return;
    switch (payload_ty.kind) {
        .ffi_struct => destroyStructNativeLayoutWithOwner(self, module, payload_ty.name orelse return, @intCast(word), owner),
        .array => destroyArrayNativeLayoutWithOwner(self, module, payload_ty, @intCast(word), owner),
        .enum_instance => destroyEnumNativeLayoutWithOwner(self, module, payload_ty.name orelse return, @intCast(word), owner),
        .string => switch (owner) {
            .vm => self.allocator.destroy(@as(*runtime_abi.BridgeString, @ptrFromInt(@as(usize, @intCast(word))))),
            .c => std.heap.c_allocator.destroy(@as(*runtime_abi.BridgeString, @ptrFromInt(@as(usize, @intCast(word))))),
        },
        else => {},
    }
}

pub fn destroyStructNativeLayoutFields(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize) void {
    destroyStructNativeLayoutFieldsWithOwner(self, module, type_name, native_ptr, .vm);
}

pub fn destroyStructNativeLayoutFieldsWithOwner(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_ptr: usize, owner: NativeLayoutOwner) void {
    const type_decl = self.findTypeCached(module, type_name) orelse return;
    for (type_decl.fields, 0..) |field_decl, index| {
        const offset = native_layout.fieldOffset(module, type_name, index) catch continue;
        const address = native_ptr + offset;
        switch (field_decl.ty.kind) {
            .array => {
                const array_ptr = (@as(*const usize, @ptrFromInt(address))).*;
                destroyArrayNativeLayoutWithOwner(self, module, field_decl.ty, array_ptr, owner);
                // Clear the slot so a subsequent overwrite (releaseNativeFieldBeforeOverwrite ->
                // re-entry on the same address) does not free this now-stale pointer again.
                (@as(*usize, @ptrFromInt(address))).* = 0;
            },
            .ffi_struct => if (field_decl.ty.name) |nested_name| {
                destroyStructNativeLayoutFieldsWithOwner(self, module, nested_name, address, owner);
            },
            .enum_instance => {
                const enum_ptr = (@as(*const usize, @ptrFromInt(address))).*;
                destroyEnumNativeLayoutWithOwner(self, module, field_decl.ty.name orelse return, enum_ptr, owner);
                (@as(*usize, @ptrFromInt(address))).* = 0;
            },
            .construct_any => {},
            else => {},
        }
    }
}

pub fn destroyPreservedNativeStateValue(self: *Vm, module: *const bytecode.Module, ty: bytecode.TypeRef, value: runtime_abi.Value) void {
    switch (ty.kind) {
        .ffi_struct => {
            if (value != .raw_ptr or value.raw_ptr == 0) return;
            destroyStructNativeLayout(self, module, ty.name orelse return, value.raw_ptr);
        },
        .array => {
            if (value != .raw_ptr or value.raw_ptr == 0) return;
            destroyArrayNativeLayout(self, module, ty, value.raw_ptr);
        },
        .enum_instance => {
            if (value != .raw_ptr or value.raw_ptr == 0) return;
            destroyEnumNativeLayout(self, module, ty.name orelse return, value.raw_ptr);
        },
        .construct_any => self.heap.dropValue(value),
        else => {},
    }
}

pub fn destroyNativeStatePayload(self: *Vm, module: *const bytecode.Module, type_name: []const u8, native_payload_ptr: usize) void {
    if (native_payload_ptr == 0) return;
    const type_decl = self.findTypeCached(module, type_name) orelse return;
    const native_payload: [*]const runtime_abi.BridgeValue = @ptrFromInt(native_payload_ptr);
    for (type_decl.fields, 0..) |field_decl, index| {
        destroyPreservedNativeStateValue(self, module, field_decl.ty, runtime_abi.bridgeValueToValue(native_payload[index]));
    }
    self.allocator.free(native_payload[0..type_decl.fields.len]);
}

pub fn destroyMaterializedNativeStatePayload(self: *Vm, runtime_payload_ptr: usize, field_count: usize) void {
    if (runtime_payload_ptr == 0) return;
    const runtime_payload: [*]runtime_abi.Value = @ptrFromInt(runtime_payload_ptr);
    self.heap.dropSlots(runtime_payload[0..field_count]);
    self.allocator.free(runtime_payload[0..field_count]);
}

/// Releases one VM-allocated native-state box (`nativeStateFree`). Unknown
/// tokens are ignored: they either belong to the native backend (hybrid) or
/// are raw payload views, and neither is this allocator's to free.
pub fn freeNativeState(self: *Vm, state_token: usize) void {
    if (!self.native_state_boxes.remove(state_token)) return;
    const box: *NativeStateBox = @ptrFromInt(state_token);
    if (box.payload != 0) {
        destroyNativeStatePayload(self, box.module, box.typeName(), box.payload);
    }
    if (box.runtime_payload != 0) {
        destroyMaterializedNativeStatePayload(self, box.runtime_payload, box.field_count);
    }
    self.allocator.destroy(box);
}

pub fn deinitTrackedNativeStates(self: *Vm) void {
    var iterator = self.native_state_boxes.iterator();
    while (iterator.next()) |entry| {
        const box: *NativeStateBox = @ptrFromInt(entry.key_ptr.*);
        if (box.payload != 0) {
            destroyNativeStatePayload(self, box.module, box.typeName(), box.payload);
        }
        if (box.runtime_payload != 0) {
            destroyMaterializedNativeStatePayload(self, box.runtime_payload, box.field_count);
        }
        self.allocator.destroy(box);
    }
    self.native_state_boxes.deinit();
}
