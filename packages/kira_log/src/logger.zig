const std = @import("std");
const LogEntry = @import("log_entry.zig").LogEntry;
const LogLevel = @import("log_entry.zig").LogLevel;

pub const Logger = struct {
    writer: std.fs.File.Writer,

    pub fn init(writer: std.fs.File.Writer) Logger {
        return .{ .writer = writer };
    }

    pub fn log(self: *Logger, level: LogLevel, scope: []const u8, message: []const u8) !void {
        try self.writer.print("[{s}] {s}: {s}\n", .{ @tagName(level), scope, message });
    }

    pub fn logEntry(self: *Logger, entry: LogEntry) !void {
        try self.log(entry.level, entry.scope, entry.message);
    }
};
