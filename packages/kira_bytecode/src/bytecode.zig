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
                .call_runtime => |value| try writer.writeInt(u32, value.function_id, .little),
                .call_native => |value| try writer.writeInt(u32, value.function_id, .little),
                .ret_void => {},
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
                .call_runtime => try instructions.append(.{ .call_runtime = .{
                    .function_id = try reader.readInt(u32, .little),
                } }),
                .call_native => try instructions.append(.{ .call_native = .{
                    .function_id = try reader.readInt(u32, .little),
                } }),
                .ret_void => try instructions.append(.{ .ret_void = {} }),
            }
        }
        try functions.append(.{
            .id = function_id,
            .name = name,
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
