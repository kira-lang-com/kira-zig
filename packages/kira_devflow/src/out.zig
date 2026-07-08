//! Minimal stdout printer for devflow's human-facing output.

const std = @import("std");

var buffer: [4096]u8 = undefined;

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var w = std.Io.File.stdout().writer(std.Options.debug_io, &buffer);
    const out = &w.interface;
    out.print(fmt, args) catch {};
    out.flush() catch {};
}

pub fn line(text: []const u8) void {
    print("{s}\n", .{text});
}
