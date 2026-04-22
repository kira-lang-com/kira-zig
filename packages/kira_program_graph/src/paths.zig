const std = @import("std");
const builtin = @import("builtin");

pub fn canonicalizeExistingPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var dir = std.fs.openDirAbsolute(std.fs.path.dirname(path) orelse ".", .{}) catch return allocator.dupe(u8, path);
        defer dir.close();
        return dir.realpathAlloc(allocator, std.fs.path.basename(path));
    }
    return std.fs.cwd().realpathAlloc(allocator, path);
}

pub fn canonicalizeSourceRoot(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    if (dirExists(root_path)) return canonicalizeDirectory(allocator, root_path);
    return absolutizeLexical(allocator, root_path);
}

pub fn canonicalizeDirectory(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var parent = std.fs.openDirAbsolute(std.fs.path.dirname(path) orelse ".", .{}) catch return allocator.dupe(u8, path);
        defer parent.close();
        return parent.realpathAlloc(allocator, std.fs.path.basename(path));
    }
    return std.fs.cwd().realpathAlloc(allocator, path);
}

pub fn absolutizeLexical(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

pub fn fileExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        var file = std.fs.openFileAbsolute(path, .{}) catch return false;
        file.close();
        return true;
    }

    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

pub fn dirExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
        dir.close();
        return true;
    }

    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

pub fn pathWithinRoot(path: []const u8, root: []const u8) bool {
    if (pathEql(path, root)) return true;
    if (path.len <= root.len) return false;
    if (!pathStartsWith(path, root)) return false;
    return isSeparator(path[root.len]);
}

pub fn pathEql(left: []const u8, right: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    const head = path[0..prefix.len];
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(head, prefix);
    return std.mem.eql(u8, head, prefix);
}

fn isSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

test "pathWithinRoot requires a component boundary" {
    try std.testing.expect(pathWithinRoot("C:\\pkg\\app\\main.kira", "C:\\pkg\\app"));
    try std.testing.expect(!pathWithinRoot("C:\\pkg\\application\\main.kira", "C:\\pkg\\app"));
}
