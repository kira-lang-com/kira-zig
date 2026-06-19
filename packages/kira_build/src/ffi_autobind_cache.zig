const std = @import("std");
const native = @import("kira_native_lib_definition");
const fs_helpers = @import("ffi_autobind_fs.zig");

var key_cache_mutex: std.atomic.Mutex = .unlocked;
var key_cache: std.StringHashMapUnmanaged([]const u8) = .empty;
const generator_cache_version = "kira-autobinding-sdk-v1";

pub fn bindingsAreCurrent(allocator: std.mem.Allocator, output_path: []const u8, cache_key: []const u8) !bool {
    if (!fs_helpers.fileExists(output_path)) return false;
    const key_path = try keyPath(allocator, output_path);
    defer allocator.free(key_path);
    const existing = fs_helpers.readFileAlloc(key_path, allocator, 4096) catch return false;
    defer allocator.free(existing);
    return std.mem.eql(u8, existing, cache_key);
}

pub fn writeKey(output_path: []const u8, cache_key: []const u8) !void {
    const path = try keyPath(std.heap.page_allocator, output_path);
    defer std.heap.page_allocator.free(path);
    try fs_helpers.writeFile(path, cache_key);
    deleteLegacyKey(output_path);
}

pub fn cacheKey(
    allocator: std.mem.Allocator,
    library: native.ResolvedNativeLibrary,
    autobinding: native.AutobindingSpec,
) ![]const u8 {
    const memo_key = try memoKey(allocator, library, autobinding);
    defer allocator.free(memo_key);
    if (cachedKey(allocator, memo_key)) |value| return value;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(generator_cache_version ++ "\n");
    try hashString(&hasher, "module", autobinding.module_name);
    try hashPath(allocator, &hasher, "output", autobinding.output_path);
    try hashString(&hasher, "mode", @tagName(autobinding.bindings.mode));
    try hashString(&hasher, "profile", @tagName(autobinding.bindings.profile));
    for (library.headers.defines) |define| try hashString(&hasher, "header_define", define);
    for (library.build.defines) |define| try hashString(&hasher, "build_define", define);
    for (autobinding.bindings.functions) |name| try hashString(&hasher, "function", name);
    for (autobinding.bindings.structs) |name| try hashString(&hasher, "struct", name);
    for (autobinding.bindings.callbacks) |name| try hashString(&hasher, "callback", name);

    if (library.manifest_path) |path| try hashFileIfPresent(allocator, &hasher, "manifest", path);
    if (library.headers.entrypoint) |path| try hashFileIfPresent(allocator, &hasher, "entrypoint", path);
    for (autobinding.headers) |path| try hashFileIfPresent(allocator, &hasher, "header", path);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const computed = try hexDigest(allocator, &digest);
    try storeCachedKey(allocator, memo_key, computed);
    return computed;
}

fn deleteLegacyKey(output_path: []const u8) void {
    const legacy_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}.key", .{output_path}) catch return;
    defer std.heap.page_allocator.free(legacy_path);
    if (std.fs.path.isAbsolute(legacy_path)) {
        std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, legacy_path) catch {};
    } else {
        std.Io.Dir.cwd().deleteFile(std.Options.debug_io, legacy_path) catch {};
    }
}

fn keyPath(allocator: std.mem.Allocator, output_path: []const u8) ![]const u8 {
    const project_root = try metadataProjectRoot(allocator, output_path);
    defer allocator.free(project_root);
    const digest = try pathDigest(allocator, output_path);
    defer allocator.free(digest);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.stamp", .{digest});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ project_root, ".kira-build", "autobind", file_name });
}

fn memoKey(
    allocator: std.mem.Allocator,
    library: native.ResolvedNativeLibrary,
    autobinding: native.AutobindingSpec,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n",
        .{
            generator_cache_version,
            library.name,
            library.artifact_path,
            autobinding.output_path,
            autobinding.module_name,
            @tagName(autobinding.bindings.profile),
        },
    );
}

fn cachedKey(allocator: std.mem.Allocator, memo_key: []const u8) ?[]const u8 {
    lockMutex(&key_cache_mutex);
    defer key_cache_mutex.unlock();
    const value = key_cache.get(memo_key) orelse return null;
    return allocator.dupe(u8, value) catch null;
}

fn storeCachedKey(allocator: std.mem.Allocator, memo_key: []const u8, computed: []const u8) !void {
    lockMutex(&key_cache_mutex);
    defer key_cache_mutex.unlock();
    if (key_cache.contains(memo_key)) return;
    try key_cache.put(
        std.heap.page_allocator,
        try std.heap.page_allocator.dupe(u8, memo_key),
        try std.heap.page_allocator.dupe(u8, computed),
    );
    _ = allocator;
}

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
}

fn metadataProjectRoot(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const start_dir = std.fs.path.dirname(path) orelse ".";
    var cursor = try canonicalPathOrOriginal(allocator, start_dir);
    errdefer allocator.free(cursor);

    while (true) {
        if (hasProjectManifest(cursor)) return cursor;
        const parent = std.fs.path.dirname(cursor) orelse break;
        if (std.mem.eql(u8, parent, cursor)) break;
        const copy = try allocator.dupe(u8, parent);
        allocator.free(cursor);
        cursor = copy;
    }
    return cursor;
}

fn hasProjectManifest(path: []const u8) bool {
    return fileExistsAt(path, "kira.toml") or
        fileExistsAt(path, "project.toml") or
        fileExistsAt(path, "Kira.toml");
}

fn fileExistsAt(dir_path: []const u8, file_name: []const u8) bool {
    const joined = std.fs.path.join(std.heap.page_allocator, &.{ dir_path, file_name }) catch return false;
    defer std.heap.page_allocator.free(joined);
    return fs_helpers.fileExists(joined);
}

fn pathDigest(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const canonical = try canonicalPathOrOriginal(allocator, path);
    defer allocator.free(canonical);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(canonical);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = try hexDigest(allocator, &digest);
    return hex[0 .. hex.len - 1];
}

fn hashCompilerIdentity(allocator: std.mem.Allocator, hasher: anytype) !void {
    const exe_path = std.process.executablePathAlloc(std.Options.debug_io, allocator) catch return;
    defer allocator.free(exe_path);
    try hashString(hasher, "compiler_path", exe_path);
    const stat = fs_helpers.statFile(exe_path) catch return;
    var buffer: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "size={d};mtime={d}", .{ stat.size, stat.mtime });
    try hashString(hasher, "compiler_stat", text);
}

fn hashFileIfPresent(allocator: std.mem.Allocator, hasher: anytype, label: []const u8, path: []const u8) !void {
    const bytes = fs_helpers.readFileAlloc(path, allocator, 64 * 1024 * 1024) catch return;
    defer allocator.free(bytes);
    try hashPath(allocator, hasher, label, path);
    hasher.update(bytes);
    hasher.update("\n");
}

fn hashPath(allocator: std.mem.Allocator, hasher: anytype, label: []const u8, path: []const u8) !void {
    const canonical = try canonicalPathOrOriginal(allocator, path);
    defer allocator.free(canonical);
    try hashString(hasher, label, canonical);
}

fn canonicalPathOrOriginal(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, allocator) catch allocator.dupe(u8, path);
}

fn hashString(hasher: anytype, label: []const u8, value: []const u8) !void {
    hasher.update(label);
    hasher.update("=");
    hasher.update(value);
    hasher.update("\n");
}

fn hexDigest(allocator: std.mem.Allocator, digest: []const u8) ![]const u8 {
    const alphabet = "0123456789abcdef";
    const out = try allocator.alloc(u8, digest.len * 2 + 1);
    for (digest, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    out[digest.len * 2] = '\n';
    return out;
}
