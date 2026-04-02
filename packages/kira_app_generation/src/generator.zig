const std = @import("std");
const templates = @import("templates.zig");

pub fn generateApp(allocator: std.mem.Allocator, name: []const u8, destination: []const u8) !void {
    try templates.copyTemplateTree(allocator, "templates/app", destination, name);
}
