const std = @import("std");
const templates = @import("templates.zig");

pub fn generateApp(allocator: std.mem.Allocator, templates_root: []const u8, name: []const u8, destination: []const u8) !void {
    const app_template = try std.fs.path.join(allocator, &.{ templates_root, "app" });
    defer allocator.free(app_template);
    try templates.copyTemplateTree(allocator, app_template, destination, name);
}
