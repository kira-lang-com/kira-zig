const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const native_layout = @import("native_layout.zig");

pub fn collectArgs(allocator: std.mem.Allocator, registers: []const runtime_abi.Value, argument_registers: []const u32) ![]runtime_abi.Value {
    const values = try allocator.alloc(runtime_abi.Value, argument_registers.len);
    for (argument_registers, 0..) |register_index, index| {
        values[index] = registers[register_index];
    }
    return values;
}

pub fn resolveFunctionPointer(hooks: anytype, resolve_function: anytype, function_id: u32) !usize {
    return resolve_function(hooks.context, function_id);
}

pub fn buildLabelOffsets(allocator: std.mem.Allocator, instructions: []const bytecode.Instruction) ![]usize {
    var max_label: usize = 0;
    var has_label = false;
    for (instructions) |inst| {
        if (inst != .label) continue;
        has_label = true;
        max_label = @max(max_label, @as(usize, @intCast(inst.label.id)));
    }

    if (!has_label) return allocator.alloc(usize, 0);

    const offsets = try allocator.alloc(usize, max_label + 1);
    @memset(offsets, std.math.maxInt(usize));

    for (instructions, 0..) |inst, index| {
        if (inst != .label) continue;
        offsets[@as(usize, @intCast(inst.label.id))] = index;
    }

    return offsets;
}

pub fn resolveLabelOffset(label_offsets: []const usize, label: u32) !usize {
    const label_index = @as(usize, @intCast(label));
    if (label_index >= label_offsets.len) return error.RuntimeFailure;
    const offset = label_offsets[label_index];
    if (offset == std.math.maxInt(usize)) return error.RuntimeFailure;
    return offset;
}

pub fn findType(module: *const bytecode.Module, name: []const u8) ?bytecode.TypeDecl {
    for (module.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
    }
    return null;
}

pub fn writeNativeFieldValue(vm: anytype, module: *const bytecode.Module, field_ty: bytecode.TypeRef, value: runtime_abi.Value, address: usize) anyerror!void {
    try switch (field_ty.kind) {
        .void => {},
        .integer => native_layout.writeInteger(field_ty.name, address, value),
        .float => native_layout.writeFloat(field_ty.name, address, value),
        .string => {
            if (value != .string) {
                vm.rememberError("runtime string field cannot be lowered to native memory");
                return error.RuntimeFailure;
            }
            const string_ptr: *runtime_abi.BridgeString = @ptrFromInt(address);
            string_ptr.* = .{
                .ptr = if (value.string.len == 0) null else value.string.ptr,
                .len = value.string.len,
            };
        },
        .boolean => {
            if (value != .boolean) {
                vm.rememberError("runtime boolean field cannot be lowered to native memory");
                return error.RuntimeFailure;
            }
            (@as(*u8, @ptrFromInt(address))).* = if (value.boolean) 1 else 0;
        },
        .construct_any, .array, .raw_ptr, .enum_instance => {
            if (value != .raw_ptr) {
                vm.rememberError("runtime pointer field cannot be lowered to native memory");
                return error.RuntimeFailure;
            }
            (@as(*usize, @ptrFromInt(address))).* = value.raw_ptr;
        },
        .ffi_struct => {
            const nested_name = field_ty.name orelse {
                vm.rememberError("nested struct field type is missing a name");
                return error.RuntimeFailure;
            };
            const nested_ptr: usize = switch (value) {
                .raw_ptr => |ptr| ptr,
                .integer => |inner| if (inner <= 0) 0 else @intCast(@min(@as(u64, @intCast(inner)), std.math.maxInt(usize))),
                .void => 0,
                else => 0,
            };
            if (nested_ptr == 0) {
                const layout = try native_layout.structLayout(module, nested_name);
                const size = @max(@as(usize, layout.size), 1);
                @memset(@as([*]u8, @ptrFromInt(address))[0..size], 0);
                return;
            }
            try vm.copyStructToNativeLayoutInto(module, nested_name, nested_ptr, address);
        },
    };
}

pub fn readNativeFieldValue(
    vm: anytype,
    module: *const bytecode.Module,
    owner_type_name: []const u8,
    field_decl: bytecode.Field,
    field_index: usize,
    native_ptr: usize,
) anyerror!runtime_abi.Value {
    const offset = try native_layout.fieldOffset(module, owner_type_name, field_index);
    const address = native_ptr + offset;
    return switch (field_decl.ty.kind) {
        .void => .{ .void = {} },
        .integer => .{ .integer = native_layout.readInteger(field_decl.ty.name, address) },
        .float => .{ .float = native_layout.readFloat(field_decl.ty.name, address) },
        .string => blk: {
            const value_ptr: *const runtime_abi.BridgeString = @ptrFromInt(address);
            break :blk .{ .string = if (value_ptr.ptr) |ptr| ptr[0..value_ptr.len] else "" };
        },
        .boolean => .{ .boolean = (@as(*const u8, @ptrFromInt(address))).* != 0 },
        .construct_any, .array, .raw_ptr, .enum_instance => .{ .raw_ptr = (@as(*const usize, @ptrFromInt(address))).* },
        .ffi_struct => .{ .raw_ptr = try vm.copyStructFromNativeLayout(module, field_decl.ty.name orelse {
            vm.rememberError("nested struct field type is missing a name");
            return error.RuntimeFailure;
        }, address) },
    };
}
