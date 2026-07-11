//! Deep-copy/clone semantics for managed struct, array, and enum values.
//! Extracted from vm.zig (Core Law #5); the Vm keeps thin delegating methods
//! so call sites are unchanged. `vm: anytype` mirrors vm_value_clone.zig to
//! avoid an import cycle with vm.zig.
const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const ownership = @import("ownership.zig");
const native_bridge = @import("vm_native_bridge.zig");

const ArrayObject = ownership.ArrayObject;

pub fn resolveStructValuePointer(vm: anytype, expected_type_name: []const u8, ptr: usize) !usize {
    if (ptr == 0) {
        vm.rememberError("struct value pointer is null");
        return error.RuntimeFailure;
    }
    if (vm.isManagedStructPointer(ptr)) return ptr;
    _ = expected_type_name;

    const slot_ptr: *const runtime_abi.Value = @ptrFromInt(ptr);
    const value = slot_ptr.*;
    if (value != .raw_ptr) {
        // Some lowered paths hand us a direct pointer to inline struct field storage
        // instead of a slot containing a managed struct pointer. Treat that as an
        // already-resolved struct pointer and let downstream field access validate it.
        return ptr;
    }
    if (value.raw_ptr == 0) return 0;
    if (!vm.isManagedStructPointer(value.raw_ptr)) {
        vm.rememberError("struct pointer slot does not contain a managed struct value");
        return error.RuntimeFailure;
    }
    return value.raw_ptr;
}

pub fn ensureStructDestinationPointer(vm: anytype, module: *const bytecode.Module, expected_type_name: []const u8, ptr: usize) !usize {
    if (ptr == 0) {
        vm.rememberError("struct destination pointer is null");
        return error.RuntimeFailure;
    }
    if (vm.isManagedStructPointer(ptr)) return ptr;

    const slot_ptr: *runtime_abi.Value = @ptrFromInt(ptr);
    if (slot_ptr.* == .raw_ptr and slot_ptr.raw_ptr != 0) {
        if (!vm.isManagedStructPointer(slot_ptr.raw_ptr)) {
            vm.rememberError("struct destination slot does not contain a managed struct value");
            return error.RuntimeFailure;
        }
        return slot_ptr.raw_ptr;
    }

    const old = slot_ptr.*;
    slot_ptr.* = .{ .raw_ptr = try vm.allocateStruct(module, expected_type_name) };
    vm.heap.dropValue(old);
    return slot_ptr.raw_ptr;
}

pub fn copyStructValueInto(
    vm: anytype,
    module: *const bytecode.Module,
    type_name: []const u8,
    dst_raw_ptr: usize,
    src_value: runtime_abi.Value,
) !void {
    const type_decl = vm.findTypeCached(module, type_name) orelse {
        vm.rememberError("struct type could not be resolved");
        return error.RuntimeFailure;
    };
    const dst_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(dst_raw_ptr);
    if (src_value == .raw_ptr and src_value.raw_ptr != 0) {
        if (vm.isManagedStructPointer(src_value.raw_ptr)) {
            const src_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(src_value.raw_ptr);
            try copyStruct(vm, module, type_decl, dst_ptr, src_ptr);
        } else {
            try vm.copyStructFromNativeLayoutInto(module, type_name, dst_raw_ptr, src_value.raw_ptr);
        }
        return;
    }
    if (src_value == .raw_ptr and src_value.raw_ptr == 0) {
        const default_ptr = try vm.allocateStruct(module, type_name);
        defer vm.heap.dropValue(.{ .raw_ptr = default_ptr });
        const src_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(default_ptr);
        try copyStruct(vm, module, type_decl, dst_ptr, src_ptr);
        return;
    }
    vm.rememberError("struct copy source must be a struct value");
    return error.RuntimeFailure;
}

pub fn cloneStructValue(vm: anytype, module: *const bytecode.Module, type_name: []const u8, src_raw_ptr: usize) !usize {
    const type_decl = vm.findTypeCached(module, type_name) orelse {
        vm.rememberError("struct type could not be resolved");
        return error.RuntimeFailure;
    };
    const fresh = try vm.allocateStruct(module, type_name);
    errdefer vm.heap.dropValue(.{ .raw_ptr = fresh });
    const dst_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(fresh);
    const src_ptr: [*]align(1) runtime_abi.Value = @ptrFromInt(src_raw_ptr);
    try copyStruct(vm, module, type_decl, dst_ptr, src_ptr);
    return fresh;
}

pub fn copyStruct(
    vm: anytype,
    module: *const bytecode.Module,
    type_decl: bytecode.TypeDecl,
    dst_ptr: [*]align(1) runtime_abi.Value,
    src_ptr: [*]align(1) runtime_abi.Value,
) !void {
    for (type_decl.fields, 0..) |field_decl, index| {
        if (field_decl.ty.kind == .ffi_struct) {
            const nested_name = field_decl.ty.name orelse {
                vm.rememberError("struct field type is missing a name");
                return error.RuntimeFailure;
            };
            const nested_type = vm.findTypeCached(module, nested_name) orelse {
                vm.rememberError("struct type could not be resolved");
                return error.RuntimeFailure;
            };
            if (src_ptr[index] != .raw_ptr) {
                vm.rememberFmt(
                    "nested struct copy source must be a pointer: {s}.{s}",
                    .{ type_decl.name, field_decl.name },
                );
                return error.RuntimeFailure;
            }
            if (dst_ptr[index] != .raw_ptr or dst_ptr[index].raw_ptr == 0) {
                const old = dst_ptr[index];
                dst_ptr[index] = .{ .raw_ptr = try vm.allocateStruct(module, nested_name) };
                vm.heap.dropValue(old);
            }
            if (src_ptr[index].raw_ptr == 0) {
                // Treat null nested pointers as zero/default nested structs.
                const old = dst_ptr[index];
                dst_ptr[index] = .{ .raw_ptr = try vm.allocateStruct(module, nested_name) };
                vm.heap.dropValue(old);
                continue;
            }
            const nested_dst: [*]align(1) runtime_abi.Value = @ptrFromInt(dst_ptr[index].raw_ptr);
            const nested_src: [*]align(1) runtime_abi.Value = @ptrFromInt(src_ptr[index].raw_ptr);
            try copyStruct(vm, module, nested_type, nested_dst, nested_src);
        } else {
            const old = dst_ptr[index];
            dst_ptr[index] = try vm.cloneBorrowedValueForStore(module, field_decl.ty, src_ptr[index]);
            vm.heap.dropValue(old);
        }
    }
}

/// Deep-clone a managed array value so the result shares no backing storage
/// with the source. Struct and nested-array elements are cloned recursively;
/// primitive/string elements are retained. Implements affine copy semantics
/// for array-typed struct fields (see copyStruct).
pub fn cloneArrayValueDeep(
    vm: anytype,
    module: *const bytecode.Module,
    element_ty: bytecode.TypeRef,
    src_value: runtime_abi.Value,
) anyerror!runtime_abi.Value {
    if (src_value != .raw_ptr or src_value.raw_ptr == 0) return src_value;
    const src_array: *const ArrayObject = @ptrFromInt(src_value.raw_ptr);
    const len = src_array.len;
    const dst_ptr = try vm.allocateArray(len);
    const dst_array: *ArrayObject = @ptrFromInt(dst_ptr);
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const element = runtime_abi.bridgeValueToValue(src_array.items[index]);
        const cloned = switch (element_ty.kind) {
            .ffi_struct => blk: {
                if (element != .raw_ptr or element.raw_ptr == 0) break :blk element;
                const nested_name = element_ty.name orelse break :blk element;
                if (!vm.isManagedStructPointer(element.raw_ptr)) {
                    break :blk runtime_abi.Value{ .raw_ptr = try vm.copyStructFromNativeLayout(module, nested_name, element.raw_ptr) };
                }
                const fresh = try vm.allocateStruct(module, nested_name);
                const nested_type = vm.findTypeCached(module, nested_name) orelse {
                    vm.heap.dropValue(.{ .raw_ptr = fresh });
                    vm.rememberError("array element struct type could not be resolved");
                    return error.RuntimeFailure;
                };
                const fresh_fields: [*]align(1) runtime_abi.Value = @ptrFromInt(fresh);
                const src_fields: [*]align(1) runtime_abi.Value = @ptrFromInt(element.raw_ptr);
                try copyStruct(vm, module, nested_type, fresh_fields, src_fields);
                break :blk runtime_abi.Value{ .raw_ptr = fresh };
            },
            .array => try cloneArrayValueDeep(vm, module, try vm.arrayElementType(module, element_ty), element),
            .enum_instance => blk: {
                if (element != .raw_ptr or element.raw_ptr == 0) break :blk element;
                const enum_name = element_ty.name orelse break :blk element;
                break :blk try cloneEnumValue(vm, module, enum_name, element);
            },
            .construct_any => try vm.cloneBorrowedValueForStore(module, element_ty, element),
            else => element,
        };
        dst_array.items[index] = runtime_abi.bridgeValueFromValue(cloned);
    }
    return .{ .raw_ptr = dst_ptr };
}

pub fn cloneEnumValue(vm: anytype, module: *const bytecode.Module, type_name: []const u8, value: runtime_abi.Value) anyerror!runtime_abi.Value {
    if (value != .raw_ptr or value.raw_ptr == 0) return value;
    if (!vm.isManagedStructPointer(value.raw_ptr)) {
        var native_candidate = value.raw_ptr;
        var depth: usize = 0;
        while (depth < 8) : (depth += 1) {
            const native_words: [*]const u64 = @ptrFromInt(native_candidate);
            if (native_bridge.enumNativeVariant(vm, module, type_name, native_words[0])) |_| {
                return .{ .raw_ptr = try vm.copyEnumFromNativeLayout(module, type_name, native_candidate) };
            }
            const next_candidate: usize = @intCast(native_words[0]);
            if (next_candidate == 0 or next_candidate == native_candidate or next_candidate % @alignOf(u64) != 0) break;
            native_candidate = next_candidate;
        }
    }
    const src: [*]align(1) const runtime_abi.Value = @ptrFromInt(value.raw_ptr);
    if (src[0] == .raw_ptr and src[0].raw_ptr != 0 and src[0].raw_ptr != value.raw_ptr) {
        return cloneEnumValue(vm, module, type_name, src[0]);
    }
    if (src[0] != .integer) {
        const native_words: [*]const u64 = @ptrFromInt(value.raw_ptr);
        var chain_candidate: usize = value.raw_ptr;
        var chain_words = [_]u64{0} ** 4;
        var chain_index: usize = 0;
        while (chain_index < chain_words.len) : (chain_index += 1) {
            const chain_ptr: [*]const u64 = @ptrFromInt(chain_candidate);
            chain_words[chain_index] = chain_ptr[0];
            const next_candidate: usize = @intCast(chain_ptr[0]);
            if (next_candidate == 0 or next_candidate == chain_candidate or next_candidate % @alignOf(u64) != 0) break;
            chain_candidate = next_candidate;
        }
        vm.rememberFmt(
            "enum clone requires an integer tag slot: type={s} ptr=0x{x} first_word=0x{x} chain=0x{x},0x{x},0x{x},0x{x}",
            .{ type_name, value.raw_ptr, native_words[0], chain_words[0], chain_words[1], chain_words[2], chain_words[3] },
        );
        return error.RuntimeFailure;
    }
    const payload_ty = native_bridge.enumPayloadType(vm, module, type_name, @intCast(src[0].integer)) orelse bytecode.TypeRef{ .kind = .void };
    const slots = try vm.allocator.alloc(runtime_abi.Value, 2);
    errdefer vm.allocator.free(slots);
    slots[0] = src[0];
    slots[1] = switch (payload_ty.kind) {
        .ffi_struct => blk: {
            if (src[1] != .raw_ptr or src[1].raw_ptr == 0) break :blk src[1];
            break :blk .{ .raw_ptr = try cloneStructValue(vm, module, payload_ty.name orelse type_name, src[1].raw_ptr) };
        },
        .array => try cloneArrayValueDeep(vm, module, try vm.arrayElementType(module, payload_ty), src[1]),
        .enum_instance => try cloneEnumValue(vm, module, payload_ty.name orelse type_name, src[1]),
        else => src[1],
    };
    return .{ .raw_ptr = try vm.heap.registerStruct(type_name, slots) };
}
