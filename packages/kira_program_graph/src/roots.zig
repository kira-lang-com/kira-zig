const std = @import("std");
const paths = @import("paths.zig");

pub fn sourceRootForPackageRoot(allocator: std.mem.Allocator, package_root: []const u8) ![]u8 {
    const root = try paths.canonicalizeSourceRoot(allocator, package_root);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "app" });
}

pub fn canonicalAppSourceRoot(allocator: std.mem.Allocator, package_root: []const u8) ![]u8 {
    const app_root = try sourceRootForPackageRoot(allocator, package_root);
    defer allocator.free(app_root);
    return paths.canonicalizeSourceRoot(allocator, app_root);
}

test "sourceRootForPackageRoot always selects app" {
    const source_root = try sourceRootForPackageRoot(std.testing.allocator, "Package");
    defer std.testing.allocator.free(source_root);
    try std.testing.expectEqualStrings("app", std.fs.path.basename(source_root));
}
