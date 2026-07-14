const std = @import("std");
const build = @import("kira_build");

/// Retains the complete developer report for the C API while publishing every
/// completed line immediately to the CLI's bounded progress history.
pub const ProgressReport = struct {
    output: std.Io.Writer.Allocating,
    writer: std.Io.Writer,
    line: [512]u8 = undefined,
    line_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ProgressReport {
        return .{
            .output = .init(allocator),
            .writer = .{
                .vtable = &.{ .drain = drain },
                .buffer = &.{},
            },
        };
    }

    pub fn deinit(self: *ProgressReport) void {
        self.output.deinit();
        self.* = undefined;
    }

    pub fn written(self: *ProgressReport) []u8 {
        return self.output.written();
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ProgressReport = @fieldParentPtr("writer", writer);
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.consume(bytes);
            consumed += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.consume(pattern);
            consumed += pattern.len;
        }
        return consumed;
    }

    fn consume(self: *ProgressReport, bytes: []const u8) std.Io.Writer.Error!void {
        self.output.writer.writeAll(bytes) catch return error.WriteFailed;
        for (bytes) |byte| {
            if (byte == '\n') {
                self.publishLine();
                continue;
            }
            if (byte == '\r') continue;
            if (self.line_len < self.line.len) {
                self.line[self.line_len] = byte;
                self.line_len += 1;
            }
        }
    }

    fn publishLine(self: *ProgressReport) void {
        if (self.line_len != 0) build.emitProgress(self.line[0..self.line_len]);
        self.line_len = 0;
    }
};

test "progress report preserves output and publishes completed lines" {
    const Capture = struct {
        var calls: usize = 0;
        var last: [32]u8 = undefined;
        var last_len: usize = 0;

        fn receive(_: ?*anyopaque, event: []const u8) void {
            calls += 1;
            last_len = @min(event.len, last.len);
            @memcpy(last[0..last_len], event[0..last_len]);
        }
    };

    Capture.calls = 0;
    build.setProgressCallback(null, Capture.receive);
    defer build.setProgressCallback(null, null);

    var report = ProgressReport.init(std.testing.allocator);
    defer report.deinit();
    try report.writer.writeAll("CHECK demo\nPASS DemoTest\n");

    try std.testing.expectEqualStrings("CHECK demo\nPASS DemoTest\n", report.written());
    try std.testing.expectEqual(@as(usize, 2), Capture.calls);
    try std.testing.expectEqualStrings("PASS DemoTest", Capture.last[0..Capture.last_len]);
}
