const std = @import("std");
const LogEntry = @import("log_entry.zig").LogEntry;
const LogField = @import("log_entry.zig").LogField;
const LogLevel = @import("log_entry.zig").LogLevel;

pub const Logger = struct {
    writer: std.fs.File.Writer,

    pub fn init(writer: std.fs.File.Writer) Logger {
        return .{ .writer = writer };
    }

    pub fn log(self: *Logger, level: LogLevel, scope: []const u8, event: []const u8, message: []const u8, fields: []const LogField) !void {
        try write(self.writer.interface, .{
            .level = level,
            .scope = scope,
            .event = event,
            .message = message,
            .fields = fields,
        });
    }

    pub fn logEntry(self: *Logger, entry: LogEntry) !void {
        try write(self.writer.interface, entry);
    }
};

pub fn write(writer: anytype, entry: LogEntry) !void {
    try writer.print("[{s}] {s}.{s}: {s}", .{ @tagName(entry.level), entry.scope, entry.event, entry.message });
    for (entry.fields) |field| {
        try writer.print(" {s}={s}", .{ field.key, field.value });
    }
    try writer.writeByte('\n');
}
