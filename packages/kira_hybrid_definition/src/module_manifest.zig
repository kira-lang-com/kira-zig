const std = @import("std");
const runtime_abi = @import("kira_runtime_abi");

pub const FunctionManifest = struct {
    id: u32,
    name: []const u8,
    execution: runtime_abi.FunctionExecution,
    exported_name: ?[]const u8 = null,
};

pub const HybridModuleManifest = struct {
    module_name: []const u8,
    bytecode_path: []const u8,
    native_library_path: []const u8,
    entry_function_id: u32,
    entry_execution: runtime_abi.FunctionExecution,
    functions: []const FunctionManifest,

    pub fn writeToFile(self: HybridModuleManifest, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{ .truncate = true });
        defer file.close(std.Options.debug_io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(std.Options.debug_io, &buffer);
        defer writer.interface.flush() catch {};

        try writer.interface.writeAll("KHM1");
        try writeString(&writer.interface, self.module_name);
        try writeString(&writer.interface, self.bytecode_path);
        try writeString(&writer.interface, self.native_library_path);
        try writer.interface.writeInt(u32, self.entry_function_id, .little);
        try writer.interface.writeByte(@intFromEnum(self.entry_execution));
        try writer.interface.writeInt(u32, @as(u32, @intCast(self.functions.len)), .little);
        for (self.functions) |function_decl| {
            try writer.interface.writeInt(u32, function_decl.id, .little);
            try writer.interface.writeByte(@intFromEnum(function_decl.execution));
            try writeString(&writer.interface, function_decl.name);
            try writeString(&writer.interface, function_decl.exported_name orelse "");
        }
    }

    pub fn readFromFile(allocator: std.mem.Allocator, path: []const u8) !HybridModuleManifest {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024 * 1024));
        var reader_state = std.Io.Reader.fixed(bytes);
        const reader = &reader_state;

        var magic: [4]u8 = undefined;
        try reader.readSliceAll(&magic);
        if (!std.mem.eql(u8, &magic, "KHM1")) return error.InvalidHybridManifest;

        const module_name = try readString(allocator, reader);
        const bytecode_path = try readString(allocator, reader);
        const native_library_path = try readString(allocator, reader);
        const entry_function_id = try reader.takeInt(u32, .little);
        const entry_execution: runtime_abi.FunctionExecution = @enumFromInt(try reader.takeByte());
        const function_count = try reader.takeInt(u32, .little);
        var functions = std.array_list.Managed(FunctionManifest).init(allocator);
        for (0..function_count) |_| {
            const function_id = try reader.takeInt(u32, .little);
            const execution: runtime_abi.FunctionExecution = @enumFromInt(try reader.takeByte());
            const name = try readString(allocator, reader);
            const exported_name = try readString(allocator, reader);
            try functions.append(.{
                .id = function_id,
                .name = name,
                .execution = execution,
                .exported_name = if (exported_name.len == 0) null else exported_name,
            });
        }

        return .{
            .module_name = module_name,
            .bytecode_path = bytecode_path,
            .native_library_path = native_library_path,
            .entry_function_id = entry_function_id,
            .entry_execution = entry_execution,
            .functions = try functions.toOwnedSlice(),
        };
    }
};

fn writeString(writer: anytype, value: []const u8) !void {
    try writer.writeInt(u32, @as(u32, @intCast(value.len)), .little);
    try writer.writeAll(value);
}

fn readString(allocator: std.mem.Allocator, reader: anytype) ![]const u8 {
    const length = try reader.takeInt(u32, .little);
    const buffer = try allocator.alloc(u8, length);
    try reader.readSliceAll(buffer);
    return buffer;
}
