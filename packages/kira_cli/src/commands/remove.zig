const std = @import("std");
const package_support = @import("package_support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len != 1) return error.InvalidArguments;
    var location = try package_support.loadManifestLocation(allocator, null);
    if (!package_support.removeDependency(&location.manifest, args[0])) return error.InvalidArguments;
    try package_support.writeManifest(location.manifest_path, location.manifest);
    try package_support.syncAndRender(allocator, location.root_path, stdout, stderr, .{});
}
