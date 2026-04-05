const std = @import("std");
const instruction = @import("instruction.zig");

pub const Module = struct {
    functions: []Function,
    entry_function_id: ?u32,

    pub fn writeToFile(self: Module, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(&buffer);
        defer writer.interface.flush() catch {};
        try serialize(&writer.interface, self);
    }

    pub fn readFromFile(allocator: std.mem.Allocator, path: []const u8) !Module {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        return deserialize(allocator, bytes);
    }

    pub fn findFunctionById(self: Module, function_id: u32) ?Function {
        for (self.functions) |function_decl| {
            if (function_decl.id == function_id) return function_decl;
        }
        return null;
    }
};

pub const Function = struct {
    id: u32,
    name: []const u8,
    param_count: u32 = 0,
    register_count: u32,
    local_count: u32,
    instructions: []instruction.Instruction,
};

pub fn serialize(writer: anytype, module: Module) !void {
    try writer.writeAll("KBC0");
    try writer.writeInt(u32, @as(u32, @intCast(module.functions.len)), .little);
    try writer.writeInt(i32, if (module.entry_function_id) |value| @as(i32, @intCast(value)) else -1, .little);

    for (module.functions) |function_decl| {
        try writer.writeInt(u32, function_decl.id, .little);
        try writeString(writer, function_decl.name);
        try writer.writeInt(u32, function_decl.param_count, .little);
        try writer.writeInt(u32, function_decl.register_count, .little);
        try writer.writeInt(u32, function_decl.local_count, .little);
        try writer.writeInt(u32, @as(u32, @intCast(function_decl.instructions.len)), .little);
        for (function_decl.instructions) |inst| {
            try writer.writeByte(@intFromEnum(std.meta.activeTag(inst)));
            switch (inst) {
                .const_int => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(i64, value.value, .little);
                },
                .const_string => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writeString(writer, value.value);
                },
                .const_bool => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeByte(if (value.value) 1 else 0);
                },
                .const_null_ptr => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                },
                .add => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.lhs, .little);
                    try writer.writeInt(u32, value.rhs, .little);
                },
                .store_local => |value| {
                    try writer.writeInt(u32, value.local, .little);
                    try writer.writeInt(u32, value.src, .little);
                },
                .load_local => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.local, .little);
                },
                .print => |value| try writer.writeInt(u32, value.src, .little),
                .call_runtime => |value| try writeCall(writer, value.function_id, value.args, value.dst),
                .call_native => |value| try writeCall(writer, value.function_id, value.args, value.dst),
                .ret => |value| try writer.writeInt(i32, if (value.src) |src| @as(i32, @intCast(src)) else -1, .little),
            }
        }
    }
}

pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !Module {
    var stream = std.io.fixedBufferStream(bytes);
    const reader = stream.reader();

    var magic: [4]u8 = undefined;
    _ = try reader.readAll(&magic);
    if (!std.mem.eql(u8, &magic, "KBC0")) return error.InvalidBytecode;

    const function_count = try reader.readInt(u32, .little);
    const raw_entry = try reader.readInt(i32, .little);
    var functions = std.array_list.Managed(Function).init(allocator);

    for (0..function_count) |_| {
        const function_id = try reader.readInt(u32, .little);
        const name = try readString(allocator, reader);
        const param_count = try reader.readInt(u32, .little);
        const register_count = try reader.readInt(u32, .little);
        const local_count = try reader.readInt(u32, .little);
        const instruction_count = try reader.readInt(u32, .little);
        var instructions = std.array_list.Managed(instruction.Instruction).init(allocator);
        for (0..instruction_count) |_| {
            const tag = try reader.readByte();
            const op: instruction.OpCode = @enumFromInt(tag);
            switch (op) {
                .const_int => try instructions.append(.{ .const_int = .{
                    .dst = try reader.readInt(u32, .little),
                    .value = try reader.readInt(i64, .little),
                } }),
                .const_string => try instructions.append(.{ .const_string = .{
                    .dst = try reader.readInt(u32, .little),
                    .value = try readString(allocator, reader),
                } }),
                .const_bool => try instructions.append(.{ .const_bool = .{
                    .dst = try reader.readInt(u32, .little),
                    .value = (try reader.readByte()) != 0,
                } }),
                .const_null_ptr => try instructions.append(.{ .const_null_ptr = .{
                    .dst = try reader.readInt(u32, .little),
                } }),
                .add => try instructions.append(.{ .add = .{
                    .dst = try reader.readInt(u32, .little),
                    .lhs = try reader.readInt(u32, .little),
                    .rhs = try reader.readInt(u32, .little),
                } }),
                .store_local => try instructions.append(.{ .store_local = .{
                    .local = try reader.readInt(u32, .little),
                    .src = try reader.readInt(u32, .little),
                } }),
                .load_local => try instructions.append(.{ .load_local = .{
                    .dst = try reader.readInt(u32, .little),
                    .local = try reader.readInt(u32, .little),
                } }),
                .print => try instructions.append(.{ .print = .{
                    .src = try reader.readInt(u32, .little),
                } }),
                .call_runtime => try instructions.append(.{ .call_runtime = try readRuntimeCall(allocator, reader) }),
                .call_native => try instructions.append(.{ .call_native = try readNativeCall(allocator, reader) }),
                .ret => try instructions.append(.{ .ret = .{
                    .src = blk: {
                        const raw = try reader.readInt(i32, .little);
                        break :blk if (raw >= 0) @as(?u32, @intCast(raw)) else null;
                    },
                } }),
            }
        }
        try functions.append(.{
            .id = function_id,
            .name = name,
            .param_count = param_count,
            .register_count = register_count,
            .local_count = local_count,
            .instructions = try instructions.toOwnedSlice(),
        });
    }

    return .{
        .functions = try functions.toOwnedSlice(),
        .entry_function_id = if (raw_entry >= 0) @as(u32, @intCast(raw_entry)) else null,
    };
}

fn writeString(writer: anytype, value: []const u8) !void {
    try writer.writeInt(u32, @as(u32, @intCast(value.len)), .little);
    try writer.writeAll(value);
}

fn readString(allocator: std.mem.Allocator, reader: anytype) ![]const u8 {
    const length = try reader.readInt(u32, .little);
    const buffer = try allocator.alloc(u8, length);
    _ = try reader.readAll(buffer);
    return buffer;
}

fn writeCall(writer: anytype, function_id: u32, args: []const u32, dst: ?u32) !void {
    try writer.writeInt(u32, function_id, .little);
    try writer.writeInt(u32, @as(u32, @intCast(args.len)), .little);
    for (args) |arg| try writer.writeInt(u32, arg, .little);
    try writer.writeInt(i32, if (dst) |value| @as(i32, @intCast(value)) else -1, .little);
}

fn readRuntimeCall(allocator: std.mem.Allocator, reader: anytype) !@FieldType(instruction.Instruction, "call_runtime") {
    const call = try readCallParts(allocator, reader);
    return .{ .function_id = call.function_id, .args = call.args, .dst = call.dst };
}

fn readNativeCall(allocator: std.mem.Allocator, reader: anytype) !@FieldType(instruction.Instruction, "call_native") {
    const call = try readCallParts(allocator, reader);
    return .{ .function_id = call.function_id, .args = call.args, .dst = call.dst };
}

fn readCallParts(allocator: std.mem.Allocator, reader: anytype) !struct { function_id: u32, args: []const u32, dst: ?u32 } {
    const function_id = try reader.readInt(u32, .little);
    const arg_count = try reader.readInt(u32, .little);
    const args = try allocator.alloc(u32, arg_count);
    for (0..arg_count) |index| {
        args[index] = try reader.readInt(u32, .little);
    }
    const raw_dst = try reader.readInt(i32, .little);
    return .{
        .function_id = function_id,
        .args = args,
        .dst = if (raw_dst >= 0) @as(?u32, @intCast(raw_dst)) else null,
    };
}
