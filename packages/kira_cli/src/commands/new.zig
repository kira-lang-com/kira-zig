const std = @import("std");
const app_generation = @import("kira_app_generation");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    _ = stderr;
    if (args.len < 2) return error.InvalidArguments;

    const resource_root = try support.resolveResourceRoot(allocator);
    defer allocator.free(resource_root);

    const templates_root = try std.fs.path.join(allocator, &.{ resource_root, "templates" });
    defer allocator.free(templates_root);
    try app_generation.generateApp(allocator, templates_root, args[0], args[1]);
    try stdout.print("created {s} at {s}\n", .{ args[0], args[1] });
}
