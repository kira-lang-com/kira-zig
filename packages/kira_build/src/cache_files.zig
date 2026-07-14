const std = @import("std");
const builtin = @import("builtin");
const build_def = @import("kira_build_definition");

pub fn copyFile(source_path: []const u8, destination_path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, source_path, std.heap.page_allocator, .limited(256 * 1024 * 1024));
    defer std.heap.page_allocator.free(data);
    try ensureParentDir(destination_path);
    const file = if (std.fs.path.isAbsolute(destination_path))
        try std.Io.Dir.createFileAbsolute(std.Options.debug_io, destination_path, .{ .truncate = true })
    else
        try std.Io.Dir.cwd().createFile(std.Options.debug_io, destination_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, data);
}

pub fn makeExecutable(path: []const u8) !void {
    if (!std.Io.File.Permissions.has_executable_bit) return;

    const permissions: std.Io.File.Permissions = @enumFromInt(0o755);
    if (std.fs.path.isAbsolute(path)) {
        const parent_path = std.fs.path.dirname(path) orelse return error.InvalidCachePath;
        const base_name = std.fs.path.basename(path);
        var parent_dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, parent_path, .{});
        defer parent_dir.close(std.Options.debug_io);
        try parent_dir.setFilePermissions(std.Options.debug_io, base_name, permissions, .{});
        return;
    }

    try std.Io.Dir.cwd().setFilePermissions(std.Options.debug_io, path, permissions, .{});
}

pub fn publishStagedFileAtomic(source_path: []const u8, destination_path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, source_path, std.heap.page_allocator, .limited(256 * 1024 * 1024));
    defer std.heap.page_allocator.free(data);
    try publishFileAtomic(destination_path, data);
}

pub fn publishTextFileAtomic(path: []const u8, data: []const u8) !void {
    try publishFileAtomic(path, data);
}

fn publishFileAtomic(path: []const u8, data: []const u8) !void {
    try ensureParentDir(path);
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidCachePath;
    const base_name = std.fs.path.basename(path);
    var parent_dir = if (std.fs.path.isAbsolute(parent_path))
        try std.Io.Dir.openDirAbsolute(std.Options.debug_io, parent_path, .{})
    else
        try std.Io.Dir.cwd().openDir(std.Options.debug_io, parent_path, .{});
    defer parent_dir.close(std.Options.debug_io);

    var atomic_file = try parent_dir.createFileAtomic(std.Options.debug_io, base_name, .{
        .replace = false,
        .make_path = false,
    });
    defer atomic_file.deinit(std.Options.debug_io);
    try atomic_file.file.writeStreamingAll(std.Options.debug_io, data);
    atomic_file.link(std.Options.debug_io) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);
}

pub fn deleteTreeAbsolute(path: []const u8) !void {
    const parent_path = std.fs.path.dirname(path) orelse return;
    const base_name = std.fs.path.basename(path);
    var parent_dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, parent_path, .{});
    defer parent_dir.close(std.Options.debug_io);
    try parent_dir.deleteTree(std.Options.debug_io, base_name);
}

pub fn fileExistsAt(root: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(std.heap.page_allocator, &.{ root, name }) catch return false;
    defer std.heap.page_allocator.free(path);
    return fileExists(path);
}

pub fn fileExistsJoin(root: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(std.heap.page_allocator, &.{ root, name }) catch return false;
    defer std.heap.page_allocator.free(path);
    return fileExists(path);
}

pub fn fileExistsNonEmptyJoin(root: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(std.heap.page_allocator, &.{ root, name }) catch return false;
    defer std.heap.page_allocator.free(path);
    return fileExistsNonEmpty(path);
}

pub fn fileExists(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}

pub fn fileExistsNonEmpty(path: []const u8) bool {
    var file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    defer file.close(std.Options.debug_io);
    const stat = file.stat(std.Options.debug_io) catch return false;
    return stat.size != 0;
}

pub fn absolutize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, allocator);
}

pub fn hexDigest(allocator: std.mem.Allocator, digest: []const u8) ![]const u8 {
    const alphabet = "0123456789abcdef";
    const out = try allocator.alloc(u8, digest.len * 2);
    for (digest, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

pub fn backendName(target: build_def.ExecutionTarget) []const u8 {
    return switch (target) {
        .vm => "vm",
        .llvm_native => "llvm",
        .wasm32_emscripten => "wasm32-emscripten",
        .hybrid => "hybrid",
    };
}

pub fn objectName() []const u8 {
    return if (builtin.os.tag == .windows) "main.obj" else "main.o";
}

pub fn objectExtension() []const u8 {
    return if (builtin.os.tag == .windows) ".obj" else ".o";
}

pub fn executableNamePage(comptime base: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) base ++ ".exe" else base;
}

pub fn executableName(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    return if (builtin.os.tag == .windows) std.fmt.allocPrint(allocator, "{s}.exe", .{base}) else allocator.dupe(u8, base);
}

pub fn sharedLibraryName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "main.dll",
        .macos => "main.dylib",
        else => "main.so",
    };
}

pub fn sharedLibraryExtension() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };
}

pub fn defaultObjectPath(allocator: std.mem.Allocator, executable_path: []const u8) ![]const u8 {
    const ext = if (builtin.os.tag == .windows) ".exe" else "";
    if (ext.len > 0 and std.mem.endsWith(u8, executable_path, ext)) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ executable_path[0 .. executable_path.len - ext.len], objectExtension() });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ executable_path, objectExtension() });
}

pub fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return std.fmt.allocPrint(allocator, "{s}{s}", .{ path, extension });
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ path[0 .. path.len - ext.len], extension });
}
