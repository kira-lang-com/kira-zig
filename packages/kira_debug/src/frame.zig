//! frame — pure, formatting-only rendering of debugger stop state: a backtrace
//! (`[]Frame`), a one-line "stopped" summary (`StopReason` + optional top frame),
//! and a source-context view that prints a window of lines around the stop with a
//! `>` marker on the current line. Nothing here mutates runtime state, allocates,
//! or touches disk directly — source text is supplied through a `LineProvider`
//! callback so this module stays independent of how a frontend loads files.
//!
//! The `SourceTextProvider` adapter builds a `LineProvider` over an in-memory
//! `kira_source.SourceFile` (or raw text + `LineMap`), reusing `LineMap.lineBounds`
//! to slice each line. A frontend that already owns a `LineResolver` can adapt its
//! cached `SourceFile` into a `SourceTextProvider` without this module importing
//! `line_resolver.zig` (it does not — see api_exposed note).
const std = @import("std");
const source = @import("kira_source");
const debug_info = @import("debug_info.zig");

const Frame = debug_info.Frame;
const StopReason = debug_info.StopReason;
const SourcePosition = debug_info.SourcePosition;
const Backend = debug_info.Backend;

/// Human name for a backend tag, used in backtrace lines.
fn backendName(backend: Backend) []const u8 {
    return switch (backend) {
        .vm => "vm",
        .native => "native",
    };
}

/// Render a backtrace, one line per frame:
///   `#idx function_name at file:line:col [backend]`
/// Frames without resolved position (synthetic/stripped) render `at <unknown>`.
pub fn formatBacktrace(writer: *std.Io.Writer, frames: []const Frame) !void {
    for (frames) |frame| {
        try writer.print("#{d} {s}", .{ frame.index, frame.function_name });
        if (frame.position) |pos| {
            try writer.print(" at {s}:{d}:{d}", .{ pos.file, pos.line, pos.column });
        } else {
            try writer.writeAll(" at <unknown>");
        }
        try writer.print(" [{s}]\n", .{backendName(frame.backend)});
    }
}

/// Render a one-line "stopped" summary for the given `reason`. When `top` is
/// supplied (and the reason is not a program exit) the frame's function and
/// resolved position are appended: `... in function_name at file:line:col`.
pub fn formatStop(writer: *std.Io.Writer, reason: StopReason, top: ?Frame) !void {
    switch (reason) {
        .entry => try writer.writeAll("Stopped at entry (program not started)"),
        .exited => |code| {
            try writer.print("Program exited with code {d}\n", .{code});
            return;
        },
        .breakpoint => |id| try writer.print("Stopped at breakpoint #{d}", .{id}),
        .watchpoint => |id| try writer.print("Stopped at watchpoint #{d}", .{id}),
        .step => try writer.writeAll("Stopped after step"),
        .paused => try writer.writeAll("Paused"),
        .trapped => |message| try writer.print("Trapped: {s}", .{message}),
    }
    if (top) |frame| {
        try writer.print(" in {s}", .{frame.function_name});
        if (frame.position) |pos| {
            try writer.print(" at {s}:{d}:{d}", .{ pos.file, pos.line, pos.column });
        }
    }
    try writer.writeByte('\n');
}

/// A source-text lookup callback: returns the text of a 1-based `line` (without
/// its trailing newline), or null when the line is out of range or no source is
/// available. Kept opaque so `frame.zig` never depends on how text is loaded.
pub const LineProvider = struct {
    ctx: *const anyopaque,
    getLine: *const fn (ctx: *const anyopaque, line: u32) ?[]const u8,

    pub fn line(self: LineProvider, n: u32) ?[]const u8 {
        return self.getLine(self.ctx, n);
    }
};

/// Print a window of `radius` lines on each side of `position.line`, with a `>`
/// marker on the stop line and a space on the others, each prefixed by a
/// right-aligned line-number gutter: `>  12 | let x = 1`. Lines the provider
/// cannot supply (past EOF / missing file) are skipped. A position with line 0
/// (unresolved) prints a single "<no source>" notice instead.
pub fn formatStoppedSource(
    writer: *std.Io.Writer,
    provider: LineProvider,
    position: SourcePosition,
    radius: u32,
) !void {
    if (position.line == 0) {
        try writer.print("{s}: <no source>\n", .{position.file});
        return;
    }
    const first = if (position.line > radius) position.line - radius else 1;
    const last = position.line +| radius;
    var n = first;
    while (n <= last) : (n += 1) {
        const text = provider.line(n) orelse continue;
        const marker: []const u8 = if (n == position.line) ">" else " ";
        try writer.print("{s} {d:>4} | {s}\n", .{ marker, n, text });
    }
}

/// A `LineProvider` backed by in-memory source text and its `LineMap`. Build one
/// from a loaded `kira_source.SourceFile` (e.g. a `LineResolver`'s cached file)
/// and hand `.provider()` to `formatStoppedSource`.
pub const SourceTextProvider = struct {
    text: []const u8,
    line_map: source.LineMap,

    pub fn fromSourceFile(sf: *const source.SourceFile) SourceTextProvider {
        return .{ .text = sf.text, .line_map = sf.line_map };
    }

    pub fn fromText(text: []const u8, line_map: source.LineMap) SourceTextProvider {
        return .{ .text = text, .line_map = line_map };
    }

    fn getLine(ctx: *const anyopaque, n: u32) ?[]const u8 {
        const self: *const SourceTextProvider = @ptrCast(@alignCast(ctx));
        if (n == 0) return null;
        const idx: usize = @as(usize, n) - 1;
        if (idx >= self.line_map.line_starts.len) return null;
        const bounds = self.line_map.lineBounds(idx, self.text);
        // A file ending in '\n' leaves a phantom line whose start is EOF; it is
        // not a real source line (editors do not show it), so treat it as past
        // EOF rather than emitting a spurious blank line at the window's edge.
        if (self.text.len != 0 and bounds.start >= self.text.len) return null;
        return self.text[bounds.start..bounds.end];
    }

    pub fn provider(self: *const SourceTextProvider) LineProvider {
        return .{ .ctx = self, .getLine = getLine };
    }
};

test "formatBacktrace renders resolved and unknown frames" {
    var buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    const frames = [_]Frame{
        .{
            .index = 0,
            .backend = .native,
            .function_id = 7,
            .function_name = "compute",
            .position = .{ .file = "src/main.kira", .line = 12, .column = 5 },
            .program_counter = 0x40,
        },
        .{
            .index = 1,
            .backend = .vm,
            .function_id = 3,
            .function_name = "main",
            .position = null,
        },
    };

    try formatBacktrace(&stream, &frames);
    const out = stream.buffered();
    try std.testing.expectEqualStrings(
        "#0 compute at src/main.kira:12:5 [native]\n#1 main at <unknown> [vm]\n",
        out,
    );
}

test "formatStop summarizes reasons with and without a top frame" {
    const testing = std.testing;
    var buffer: [512]u8 = undefined;

    {
        var stream = std.Io.Writer.fixed(&buffer);
        try formatStop(&stream, .{ .breakpoint = 2 }, .{
            .index = 0,
            .backend = .vm,
            .function_id = 1,
            .function_name = "main",
            .position = .{ .file = "a.kira", .line = 4, .column = 1 },
        });
        try testing.expectEqualStrings(
            "Stopped at breakpoint #2 in main at a.kira:4:1\n",
            stream.buffered(),
        );
    }
    {
        var stream = std.Io.Writer.fixed(&buffer);
        try formatStop(&stream, .{ .trapped = "index out of bounds" }, null);
        try testing.expectEqualStrings("Trapped: index out of bounds\n", stream.buffered());
    }
    {
        var stream = std.Io.Writer.fixed(&buffer);
        try formatStop(&stream, .{ .exited = 0 }, null);
        try testing.expectEqualStrings("Program exited with code 0\n", stream.buffered());
    }
    {
        var stream = std.Io.Writer.fixed(&buffer);
        try formatStop(&stream, .entry, null);
        try testing.expectEqualStrings("Stopped at entry (program not started)\n", stream.buffered());
    }
}

test "formatStoppedSource marks the stop line within a radius window" {
    const testing = std.testing;
    const text = "line one\nline two\nline three\nline four\nline five\n";
    var line_map = try source.LineMap.init(testing.allocator, text);
    defer line_map.deinit(testing.allocator);

    var stp = SourceTextProvider.fromText(text, line_map);

    var buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    try formatStoppedSource(&stream, stp.provider(), .{ .file = "x.kira", .line = 3, .column = 1 }, 1);

    try testing.expectEqualStrings(
        "     2 | line two\n>    3 | line three\n     4 | line four\n",
        stream.buffered(),
    );
}

test "formatStoppedSource clamps the window at file bounds" {
    const testing = std.testing;
    const text = "alpha\nbeta\n";
    var line_map = try source.LineMap.init(testing.allocator, text);
    defer line_map.deinit(testing.allocator);

    var stp = SourceTextProvider.fromText(text, line_map);

    var buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    // Stop on line 1 with radius 5: no line 0, and lines past EOF are skipped.
    try formatStoppedSource(&stream, stp.provider(), .{ .file = "x.kira", .line = 1, .column = 1 }, 5);

    try testing.expectEqualStrings(
        ">    1 | alpha\n     2 | beta\n",
        stream.buffered(),
    );
}

test "formatStoppedSource reports unresolved positions" {
    const testing = std.testing;
    const text = "only line\n";
    var line_map = try source.LineMap.init(testing.allocator, text);
    defer line_map.deinit(testing.allocator);

    var stp = SourceTextProvider.fromText(text, line_map);

    var buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    try formatStoppedSource(&stream, stp.provider(), .{ .file = "gone.kira", .line = 0, .column = 0 }, 2);

    try testing.expectEqualStrings("gone.kira: <no source>\n", stream.buffered());
}
