//! Field-level codec primitives for the KBC container (split from
//! serialization.zig, Core Law #5): strings, ownership modes, TypeRefs, and
//! the call-shaped instruction payloads shared by `serialize`/`deserialize`.
const std = @import("std");
const instruction = @import("instruction.zig");
const bytecode = @import("bytecode.zig");

const OwnershipMode = bytecode.OwnershipMode;

pub fn writeString(writer: anytype, value: []const u8) !void {
    try writer.writeInt(u32, @as(u32, @intCast(value.len)), .little);
    try writer.writeAll(value);
}

pub fn writeOwnershipModes(writer: anytype, values: []const OwnershipMode) !void {
    try writer.writeInt(u32, @as(u32, @intCast(values.len)), .little);
    for (values) |value| try writer.writeByte(@intFromEnum(value));
}

pub fn readOwnershipModes(allocator: std.mem.Allocator, reader: anytype) ![]const OwnershipMode {
    const count = try reader.takeInt(u32, .little);
    const values = try allocator.alloc(OwnershipMode, count);
    for (0..count) |index| values[index] = try readOwnershipMode(reader);
    return values;
}

pub fn readOwnershipMode(reader: anytype) !OwnershipMode {
    return switch (try reader.takeByte()) {
        @intFromEnum(OwnershipMode.owned) => .owned,
        @intFromEnum(OwnershipMode.borrow_read) => .borrow_read,
        @intFromEnum(OwnershipMode.borrow_mut) => .borrow_mut,
        @intFromEnum(OwnershipMode.move) => .move,
        @intFromEnum(OwnershipMode.copy) => .copy,
        else => error.InvalidBytecode,
    };
}

pub fn defaultOwnershipModes(allocator: std.mem.Allocator, count: u32, mode: OwnershipMode) ![]const OwnershipMode {
    const values = try allocator.alloc(OwnershipMode, count);
    for (values) |*value| value.* = mode;
    return values;
}

pub fn readString(allocator: std.mem.Allocator, reader: anytype) ![]const u8 {
    const length = try reader.takeInt(u32, .little);
    const buffer = try allocator.alloc(u8, length);
    _ = try reader.readSliceAll(buffer);
    return buffer;
}

pub fn readStringList(allocator: std.mem.Allocator, reader: anytype) ![]const []const u8 {
    const count = try reader.takeInt(u32, .little);
    const values = try allocator.alloc([]const u8, count);
    for (0..count) |index| values[index] = try readString(allocator, reader);
    return values;
}

pub fn writeCall(writer: anytype, function_id: u32, args: []const u32, dst: ?u32) !void {
    try writer.writeInt(u32, function_id, .little);
    try writeCallPayload(writer, args, dst);
}

pub fn writeIndirectCall(writer: anytype, callee: u32, args: []const u32, dst: ?u32) !void {
    try writer.writeInt(u32, callee, .little);
    try writeCallPayload(writer, args, dst);
}

pub fn writeCallPayload(writer: anytype, args: []const u32, dst: ?u32) !void {
    try writer.writeInt(u32, @as(u32, @intCast(args.len)), .little);
    for (args) |arg| try writer.writeInt(u32, arg, .little);
    try writer.writeInt(i32, if (dst) |value| @as(i32, @intCast(value)) else -1, .little);
}

pub fn writeTypeRef(writer: anytype, value: instruction.TypeRef) !void {
    try writer.writeByte(@intFromEnum(value.kind));
    try writer.writeByte(if (value.name != null) 1 else 0);
    if (value.name) |name| try writeString(writer, name);
    try writer.writeByte(if (value.construct_constraint != null) 1 else 0);
    if (value.construct_constraint) |constraint| try writeString(writer, constraint.construct_name);
}

pub fn readTypeRef(allocator: std.mem.Allocator, reader: anytype) !instruction.TypeRef {
    const kind: instruction.TypeRef.Kind = @enumFromInt(try reader.takeByte());
    const has_name = (try reader.takeByte()) != 0;
    const name = if (has_name) try readString(allocator, reader) else null;
    const has_constraint = (try reader.takeByte()) != 0;
    return .{
        .kind = kind,
        .name = name,
        .construct_constraint = if (has_constraint) .{ .construct_name = try readString(allocator, reader) } else null,
    };
}

pub fn readRuntimeCall(allocator: std.mem.Allocator, reader: anytype) !@FieldType(instruction.Instruction, "call_runtime") {
    const call = try readCallParts(allocator, reader);
    return .{ .function_id = call.function_id, .args = call.args, .dst = call.dst };
}

pub fn readNativeCall(allocator: std.mem.Allocator, reader: anytype) !@FieldType(instruction.Instruction, "call_native") {
    const call = try readCallParts(allocator, reader);
    return .{
        .function_id = call.function_id,
        .args = call.args,
        .dst = call.dst,
        .return_ty = try readTypeRef(allocator, reader),
    };
}

pub fn readIndirectCall(allocator: std.mem.Allocator, reader: anytype) !@FieldType(instruction.Instruction, "call_value") {
    const call = try readIndirectCallParts(allocator, reader);
    return .{ .callee = call.callee, .args = call.args, .dst = call.dst };
}

pub fn readVirtualCall(allocator: std.mem.Allocator, reader: anytype) !@FieldType(instruction.Instruction, "call_virtual") {
    const receiver = try reader.takeInt(u32, .little);
    const static_type_name = try readString(allocator, reader);
    const method_name = try readString(allocator, reader);
    const payload = try readCallPayload(allocator, reader);
    return .{
        .receiver = receiver,
        .static_type_name = static_type_name,
        .method_name = method_name,
        .args = payload.args,
        .return_ty = try readTypeRef(allocator, reader),
        .dst = payload.dst,
    };
}

pub fn readCallParts(allocator: std.mem.Allocator, reader: anytype) !struct { function_id: u32, args: []const u32, dst: ?u32 } {
    const function_id = try reader.takeInt(u32, .little);
    const payload = try readCallPayload(allocator, reader);
    return .{
        .function_id = function_id,
        .args = payload.args,
        .dst = payload.dst,
    };
}

pub fn readIndirectCallParts(allocator: std.mem.Allocator, reader: anytype) !struct { callee: u32, args: []const u32, dst: ?u32 } {
    const callee = try reader.takeInt(u32, .little);
    const payload = try readCallPayload(allocator, reader);
    return .{
        .callee = callee,
        .args = payload.args,
        .dst = payload.dst,
    };
}

pub fn readCallPayload(allocator: std.mem.Allocator, reader: anytype) !struct { args: []const u32, dst: ?u32 } {
    const arg_count = try reader.takeInt(u32, .little);
    const args = try allocator.alloc(u32, arg_count);
    for (0..arg_count) |index| {
        args[index] = try reader.takeInt(u32, .little);
    }
    const raw_dst = try reader.takeInt(i32, .little);
    return .{
        .args = args,
        .dst = if (raw_dst >= 0) @as(?u32, @intCast(raw_dst)) else null,
    };
}
