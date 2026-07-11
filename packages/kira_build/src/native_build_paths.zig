const std = @import("std");
const builtin = @import("builtin");

/// Filesystem and project-layout helpers shared by native-library manifest
/// discovery (`ffi_support.zig`) and native artifact compilation
/// (`native_artifact_build.zig`). Extracted so neither of those modules has to
/// import the other for these low-level primitives.
pub fn absolutize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

pub fn makePath(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, path);
}

pub fn fileExists(path: []const u8) bool {
    var file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}

pub fn findManifestInDirectory(allocator: std.mem.Allocator, directory: []const u8) !?[]const u8 {
    const names = [_][]const u8{ "kira.toml", "project.toml" };
    for (names) |name| {
        const candidate = try std.fs.path.join(allocator, &.{ directory, name });
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

pub fn discoverProjectRootFromPath(allocator: std.mem.Allocator, start_path: []const u8) ![]const u8 {
    var cursor = try absolutize(allocator, start_path);
    errdefer allocator.free(cursor);
    const fallback = try allocator.dupe(u8, cursor);
    errdefer allocator.free(fallback);

    while (true) {
        if (try findManifestInDirectory(allocator, cursor)) |_| {
            allocator.free(fallback);
            return cursor;
        }

        const parent = std.fs.path.dirname(cursor) orelse break;
        if (std.mem.eql(u8, parent, cursor)) break;
        const copy = try allocator.dupe(u8, parent);
        allocator.free(cursor);
        cursor = copy;
    }

    allocator.free(cursor);
    return fallback;
}

pub fn processTempRoot() ?[]const u8 {
    if (!builtin.link_libc) return null;
    if (builtin.os.tag == .windows) {
        if (std.c.getenv("TEMP")) |raw| return std.mem.span(raw);
        if (std.c.getenv("TMP")) |raw| return std.mem.span(raw);
    } else if (std.c.getenv("TMPDIR")) |raw| {
        return std.mem.span(raw);
    }
    return null;
}
