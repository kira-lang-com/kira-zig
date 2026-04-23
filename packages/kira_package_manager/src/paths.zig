const std = @import("std");
const toolchain = @import("kira_toolchain");

pub fn cacheRoot(allocator: std.mem.Allocator) ![]u8 {
    const kira_home = try toolchain.kiraHome(allocator);
    defer allocator.free(kira_home);
    return std.fs.path.join(allocator, &.{ kira_home, "cache", "packages" });
}

pub fn registryRoot(allocator: std.mem.Allocator) ![]u8 {
    const root = try cacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "registry" });
}

pub fn gitRoot(allocator: std.mem.Allocator) ![]u8 {
    const root = try cacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "git" });
}

pub fn ensurePath(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, path);
}
