//! On-disk cache of per-function codegen-unit object files, content-addressed by
//! the digest from `cgu_hash`. A cached `.o` is reused verbatim when its function's
//! current input hash matches; otherwise the function is regenerated and stored.
//!
//! Layout: `<incremental_root>/<triple>-<opt>-<mode>/<hexdigest>.o`. The per-config
//! subdirectory keeps debug/release/cross builds from colliding — an object built
//! for one target must never be handed to another. Because objects are named by
//! their content hash, lookup is "does the file exist" and there is no separate
//! index to keep consistent.
//!
//! Garbage collection: each build records the digests it still needs via
//! `markLive`; `collectGarbage` then deletes every `.o` in the config directory
//! whose digest was not marked, reclaiming objects for functions that were deleted,
//! renamed, or changed (their old digest is no longer live).

const std = @import("std");
const cgu_hash = @import("cgu_hash.zig");

pub const Digest = cgu_hash.Digest;
pub const CguConfig = cgu_hash.CguConfig;

pub const CguCache = struct {
    allocator: std.mem.Allocator,
    /// Absolute-or-relative directory holding this config's object files.
    dir: []const u8,
    /// Hex digests kept alive by the current build; everything else is GC-eligible.
    live: std.StringHashMapUnmanaged(void) = .{},

    /// Open (creating if needed) the cache directory for `config` under
    /// `incremental_root` (typically `<project>/.kira-build/incremental`).
    pub fn open(allocator: std.mem.Allocator, incremental_root: []const u8, config: CguConfig) !CguCache {
        const key = try configKey(allocator, config);
        defer allocator.free(key);
        const dir = try std.fs.path.join(allocator, &.{ incremental_root, key });
        try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);
        return .{ .allocator = allocator, .dir = dir };
    }

    pub fn deinit(self: *CguCache) void {
        var it = self.live.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.live.deinit(self.allocator);
        self.allocator.free(self.dir);
    }

    /// Path where the object for `digest` lives (whether or not it exists yet).
    /// Caller owns the returned slice.
    pub fn objectPath(self: *const CguCache, digest: Digest) ![]const u8 {
        const name = try objectName(self.allocator, digest);
        defer self.allocator.free(name);
        return std.fs.path.join(self.allocator, &.{ self.dir, name });
    }

    /// Whether a cached object exists for `digest`.
    pub fn has(self: *const CguCache, digest: Digest) bool {
        const path = self.objectPath(digest) catch return false;
        defer self.allocator.free(path);
        return fileExists(path);
    }

    /// Record `digest` as needed by the current build so GC will not reclaim it.
    /// Marking is idempotent.
    pub fn markLive(self: *CguCache, digest: Digest) !void {
        const hex = try hexDigest(self.allocator, digest);
        const gop = try self.live.getOrPut(self.allocator, hex);
        if (gop.found_existing) self.allocator.free(hex);
    }

    /// Copy a freshly emitted object at `source_path` into the cache under `digest`,
    /// and mark it live. Idempotent: a matching cached object is left in place.
    pub fn store(self: *CguCache, digest: Digest, source_path: []const u8) !void {
        try self.markLive(digest);
        const dest = try self.objectPath(digest);
        defer self.allocator.free(dest);
        if (fileExists(dest)) return;
        try copyFile(self.allocator, source_path, dest);
    }

    /// Delete every `.o` in the cache directory whose digest was not marked live by
    /// the current build. Returns the number of objects reclaimed.
    pub fn collectGarbage(self: *CguCache) !usize {
        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, self.dir, .{ .iterate = true }) catch return 0;
        defer dir.close(std.Options.debug_io);

        var reclaimed: usize = 0;
        var iterator = dir.iterate();
        while (try iterator.next(std.Options.debug_io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".o")) continue;
            const stem = entry.name[0 .. entry.name.len - 2];
            if (self.live.contains(stem)) continue;
            dir.deleteFile(std.Options.debug_io, entry.name) catch continue;
            reclaimed += 1;
        }
        return reclaimed;
    }
};

fn objectName(allocator: std.mem.Allocator, digest: Digest) ![]const u8 {
    const hex = try hexDigest(allocator, digest);
    defer allocator.free(hex);
    return std.fmt.allocPrint(allocator, "{s}.o", .{hex});
}

fn hexDigest(allocator: std.mem.Allocator, digest: Digest) ![]const u8 {
    const hex = try allocator.alloc(u8, digest.len * 2);
    const lut = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = lut[byte >> 4];
        hex[i * 2 + 1] = lut[byte & 0x0f];
    }
    return hex;
}

/// A filesystem-safe directory name uniquely identifying the compilation config.
fn configKey(allocator: std.mem.Allocator, config: CguConfig) ![]const u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}", .{
        config.triple,
        config.opt_flag,
        @tagName(config.mode),
        if (config.drop_enabled) "drop" else "nodrop",
    });
    defer allocator.free(raw);
    const key = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |c, i| {
        key[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.' => c,
            else => '_',
        };
    }
    return key;
}

fn fileExists(path: []const u8) bool {
    var file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}

fn copyFile(allocator: std.mem.Allocator, source_path: []const u8, destination_path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, source_path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(data);
    const file = if (std.fs.path.isAbsolute(destination_path))
        try std.Io.Dir.createFileAbsolute(std.Options.debug_io, destination_path, .{ .truncate = true })
    else
        try std.Io.Dir.cwd().createFile(std.Options.debug_io, destination_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, data);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn digestFromByte(seed: u8) Digest {
    var d: Digest = undefined;
    for (&d, 0..) |*slot, i| slot.* = seed +% @as(u8, @intCast(i));
    return d;
}

const test_config = CguConfig{
    .triple = "arm64-apple-macosx",
    .opt_flag = "-O2",
    .mode = .llvm_native,
    .drop_enabled = false,
};

fn writeTemp(path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, bytes);
}

test "store then lookup reuses the cached object" {
    const root = ".zig-cache/cgu-cache-test-a";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, root) catch {};

    var cache = try CguCache.open(testing.allocator, root, test_config);
    defer cache.deinit();

    const digest = digestFromByte(1);
    try testing.expect(!cache.has(digest));

    const src = ".zig-cache/cgu-cache-test-a-src.o";
    try writeTemp(src, "OBJECT-BYTES");
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, src) catch {};
    try cache.store(digest, src);

    try testing.expect(cache.has(digest));
    const path = try cache.objectPath(digest);
    defer testing.allocator.free(path);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, testing.allocator, .limited(1024));
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("OBJECT-BYTES", data);
}

test "garbage collection reclaims objects not marked live" {
    const root = ".zig-cache/cgu-cache-test-b";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, root) catch {};

    const src = ".zig-cache/cgu-cache-test-b-src.o";
    try writeTemp(src, "x");
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, src) catch {};

    // First build: two live objects.
    {
        var cache = try CguCache.open(testing.allocator, root, test_config);
        defer cache.deinit();
        try cache.store(digestFromByte(1), src);
        try cache.store(digestFromByte(2), src);
        try testing.expectEqual(@as(usize, 0), try cache.collectGarbage());
    }

    // Second build: only digest 1 is still live; digest 2 (a deleted/renamed
    // function's stale object) must be reclaimed, and digest 3 stored fresh.
    {
        var cache = try CguCache.open(testing.allocator, root, test_config);
        defer cache.deinit();
        try testing.expect(cache.has(digestFromByte(1)));
        try testing.expect(cache.has(digestFromByte(2)));
        try cache.markLive(digestFromByte(1));
        try cache.store(digestFromByte(3), src);
        const reclaimed = try cache.collectGarbage();
        try testing.expectEqual(@as(usize, 1), reclaimed); // digest 2 removed
        try testing.expect(cache.has(digestFromByte(1)));
        try testing.expect(cache.has(digestFromByte(3)));
        try testing.expect(!cache.has(digestFromByte(2)));
    }
}

test "distinct configs use distinct cache directories" {
    const root = ".zig-cache/cgu-cache-test-c";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, root) catch {};

    var debug_cache = try CguCache.open(testing.allocator, root, .{
        .triple = "arm64-apple-macosx",
        .opt_flag = "-O0",
        .mode = .llvm_native,
        .drop_enabled = false,
    });
    defer debug_cache.deinit();
    var release_cache = try CguCache.open(testing.allocator, root, .{
        .triple = "arm64-apple-macosx",
        .opt_flag = "-O2",
        .mode = .llvm_native,
        .drop_enabled = false,
    });
    defer release_cache.deinit();

    try testing.expect(!std.mem.eql(u8, debug_cache.dir, release_cache.dir));
}
