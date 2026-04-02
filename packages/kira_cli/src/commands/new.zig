const std = @import("std");
const app_generation = @import("kira_app_generation");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    _ = stderr;
    if (args.len < 2) return error.InvalidArguments;

    try app_generation.generateApp(allocator, args[0], args[1]);
    try stdout.print("created {s} at {s}\n", .{ args[0], args[1] });
}
