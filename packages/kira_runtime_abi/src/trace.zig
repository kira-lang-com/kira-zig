const std = @import("std");

var execution_trace_enabled = false;

pub fn setEnabled(enabled: bool) void {
    execution_trace_enabled = enabled;
}

pub fn isEnabled() bool {
    return execution_trace_enabled;
}

pub fn emit(comptime domain: []const u8, comptime event: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!execution_trace_enabled) return;

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(std.Options.debug_io, &buffer);
    defer writer.interface.flush() catch {};

    writer.interface.print("[trace][{s}][{s}] ", .{ domain, event }) catch return;
    writer.interface.print(fmt, args) catch return;
    writer.interface.writeByte('\n') catch return;
}

test "trace toggle updates global state" {
    defer setEnabled(false);
    setEnabled(true);
    try std.testing.expect(isEnabled());
    setEnabled(false);
    try std.testing.expect(!isEnabled());
}
