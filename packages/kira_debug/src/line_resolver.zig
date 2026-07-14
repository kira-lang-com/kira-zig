//! line_resolver — bridges the compiler's byte-offset source spans and the
//! debugger's human 1-based line:column positions. Every backend (VM, native,
//! hybrid) carries `SourceSpan` (file + byte offsets) from the bytecode line
//! table / IR `locations`; the UI and `BreakpointSpec.line` speak in line:col.
//! `LineResolver` owns the loaded file text + `kira_source.LineMap` per path and
//! converts both directions, caching each file (including negative results) so a
//! backtrace over many frames in the same file reads the disk once.
//!
//! Missing or unreadable files never crash the debugger: `resolve` returns a
//! synthetic unknown position (line 0, column 0) and `lineToOffset` returns null.
const std = @import("std");
const source = @import("kira_source");
const debug_info = @import("debug_info.zig");

const SourcePosition = debug_info.SourcePosition;
const SourceSpan = debug_info.SourceSpan;

/// A per-path cache slot. `missing` is a remembered negative result so an
/// unreadable file is not re-`open`ed on every frame of a long backtrace.
const CachedFile = union(enum) {
    loaded: source.SourceFile,
    missing,
};

/// Converts source spans to positions and back-resolves lines to byte offsets,
/// owning the file text + line map for every path it has touched.
pub const LineResolver = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMap(CachedFile),

    pub fn init(allocator: std.mem.Allocator) LineResolver {
        return .{
            .allocator = allocator,
            .files = std.StringHashMap(CachedFile).init(allocator),
        };
    }

    pub fn deinit(self: *LineResolver) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .loaded => |*sf| sf.deinit(),
                .missing => {},
            }
        }
        self.files.deinit();
    }

    /// Load (and cache) the file for `path`, returning a pointer to its owned
    /// `SourceFile`, or null when the file is missing/unreadable. The returned
    /// pointer is valid until the next `loadFile` of a *new* path (which may
    /// rehash the map); callers use it before loading another file. Errors are
    /// reserved for allocation failure only.
    pub fn loadFile(self: *LineResolver, path: []const u8) !?*source.SourceFile {
        const gop = try self.files.getOrPut(path);
        if (!gop.found_existing) {
            // getOrPut stored the borrowed `path` as the key; replace it with an
            // owned copy so the entry outlives the caller's slice.
            const owned_key = self.allocator.dupe(u8, path) catch |err| {
                _ = self.files.remove(path);
                return err;
            };
            gop.key_ptr.* = owned_key;
            if (source.SourceFile.fromPath(self.allocator, path)) |sf| {
                gop.value_ptr.* = .{ .loaded = sf };
            } else |_| {
                gop.value_ptr.* = .missing;
            }
        }
        return switch (gop.value_ptr.*) {
            .loaded => |*sf| sf,
            .missing => null,
        };
    }

    /// Resolve a byte-offset span to a 1-based line:column. Uses the span's
    /// start offset (where a frame/breakpoint is anchored). Unknown spans and
    /// unreadable files yield a synthetic `{file, 0, 0}` position instead of an
    /// error, so a backtrace over stripped/synthetic frames still renders.
    pub fn resolve(self: *LineResolver, span: SourceSpan) !SourcePosition {
        if (span.isUnknown()) return unknownPosition(span.file);
        const sf = (try self.loadFile(span.file)) orelse return unknownPosition(span.file);
        const lc = sf.line_map.lineColumn(span.start);
        return .{
            .file = span.file,
            .line = @intCast(lc.line),
            .column = @intCast(lc.column),
        };
    }

    /// Back-resolve a 1-based source `line` to the best byte offset for setting a
    /// line breakpoint: the first non-whitespace byte on the line (so the
    /// breakpoint lands on real code, not leading indentation). A blank line
    /// resolves to its start offset. Returns null when the file is
    /// missing/unreadable or `line` is out of range (0 or past EOF).
    pub fn lineToOffset(self: *LineResolver, file: []const u8, line: u32) !?u32 {
        if (line == 0) return null;
        const sf = (try self.loadFile(file)) orelse return null;
        const line_index: usize = line - 1;
        if (line_index >= sf.line_map.line_starts.len) return null;
        const bounds = sf.line_map.lineBounds(line_index, sf.text);
        var offset = bounds.start;
        while (offset < bounds.end and (sf.text[offset] == ' ' or sf.text[offset] == '\t')) : (offset += 1) {}
        return @intCast(offset);
    }

    fn unknownPosition(file: []const u8) SourcePosition {
        return .{ .file = file, .line = 0, .column = 0 };
    }
};

test "resolve maps a known offset to line:column and lineToOffset round-trips" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const text = "let a = 1\n    let b = 2\nlet c = 3\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sample.kira", .data = text });

    const path = try tmp.dir.realPathFileAlloc(testing.io, "sample.kira", testing.allocator);
    defer testing.allocator.free(path);

    var resolver = LineResolver.init(testing.allocator);
    defer resolver.deinit();

    // Offset 0 is the first char of line 1.
    const p0 = try resolver.resolve(.{ .file = path, .start = 0, .end = 3 });
    try testing.expectEqual(@as(u32, 1), p0.line);
    try testing.expectEqual(@as(u32, 1), p0.column);

    // "let b" begins on line 2 after 4 spaces of indent. Line 2 starts at
    // offset len("let a = 1\n") = 10; the 'l' of "let b" is at column 5.
    const line2_start: u32 = 10;
    const p1 = try resolver.resolve(.{ .file = path, .start = line2_start + 4, .end = line2_start + 5 });
    try testing.expectEqual(@as(u32, 2), p1.line);
    try testing.expectEqual(@as(u32, 5), p1.column);

    // lineToOffset for line 2 skips the leading indentation -> first code byte.
    const off2 = (try resolver.lineToOffset(path, 2)).?;
    try testing.expectEqual(line2_start + 4, off2);

    // Line 1 has no indent -> offset 0.
    const off1 = (try resolver.lineToOffset(path, 1)).?;
    try testing.expectEqual(@as(u32, 0), off1);

    // Second lookup on the same file hits the cache (no crash, same result).
    const off1_again = (try resolver.lineToOffset(path, 1)).?;
    try testing.expectEqual(@as(u32, 0), off1_again);

    // Out-of-range line -> null.
    try testing.expectEqual(@as(?u32, null), try resolver.lineToOffset(path, 999));
    try testing.expectEqual(@as(?u32, null), try resolver.lineToOffset(path, 0));
}

test "missing files and unknown spans degrade gracefully, never crash" {
    const testing = std.testing;
    var resolver = LineResolver.init(testing.allocator);
    defer resolver.deinit();

    // Unreadable path -> synthetic unknown position, cached negative result.
    const pos = try resolver.resolve(.{ .file = "/no/such/file.kira", .start = 42, .end = 43 });
    try testing.expectEqualStrings("/no/such/file.kira", pos.file);
    try testing.expectEqual(@as(u32, 0), pos.line);
    try testing.expectEqual(@as(u32, 0), pos.column);
    try testing.expectEqual(@as(?u32, null), try resolver.lineToOffset("/no/such/file.kira", 1));

    // Unknown (zero) span short-circuits without any file access.
    const unknown = try resolver.resolve(.{ .file = "whatever.kira", .start = 0, .end = 0 });
    try testing.expectEqual(@as(u32, 0), unknown.line);
}
