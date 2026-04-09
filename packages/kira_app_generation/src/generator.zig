const std = @import("std");
const templates = @import("templates.zig");

pub const TemplateKind = enum {
    app,
    library,
};

pub fn generateApp(allocator: std.mem.Allocator, templates_root: []const u8, name: []const u8, destination: []const u8) !void {
    return generate(allocator, templates_root, .app, name, destination);
}

pub fn generate(
    allocator: std.mem.Allocator,
    templates_root: []const u8,
    kind: TemplateKind,
    name: []const u8,
    destination: []const u8,
) !void {
    const template_dir_name = switch (kind) {
        .app => "app",
        .library => "library",
    };
    const template_root = try std.fs.path.join(allocator, &.{ templates_root, template_dir_name });
    defer allocator.free(template_root);
    try templates.copyTemplateTree(allocator, template_root, destination, name);
}
