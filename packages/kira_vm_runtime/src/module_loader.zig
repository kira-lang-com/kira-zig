const std = @import("std");
const bytecode = @import("kira_bytecode");

pub fn loadModuleFromFile(allocator: std.mem.Allocator, path: []const u8) !bytecode.Module {
    return bytecode.Module.readFromFile(allocator, path);
}
