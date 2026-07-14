const std = @import("std");

var context: ?*anyopaque = null;
var callback: ?*const fn (?*anyopaque, []const u8) void = null;

pub fn setCallback(new_context: ?*anyopaque, new_callback: ?*const fn (?*anyopaque, []const u8) void) void {
    context = new_context;
    callback = new_callback;
}

pub fn emit(comptime fmt: []const u8, args: anytype) void {
    const sink = callback orelse return;
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    sink(context, message);
}

test "package progress formats and publishes immediately" {
    const Capture = struct {
        var buffer: [512]u8 = undefined;
        var len: usize = 0;

        fn receive(_: ?*anyopaque, message: []const u8) void {
            @memcpy(buffer[0..message.len], message);
            len = message.len;
        }
    };

    setCallback(null, Capture.receive);
    defer setCallback(null, null);
    emit("Resolving dependency {s}", .{"FrostUI"});
    try std.testing.expectEqualStrings("Resolving dependency FrostUI", Capture.buffer[0..Capture.len]);
}
