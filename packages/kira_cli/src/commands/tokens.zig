const std = @import("std");
const build = @import("kira_build");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    _ = stderr;
    if (args.len < 1) return error.InvalidArguments;

    const result = try build.lexFile(allocator, args[0]);
    for (result.tokens) |token| {
        try stdout.print("{s} \"{s}\" [{d},{d})\n", .{ @tagName(token.kind), token.lexeme, token.span.start, token.span.end });
    }
}
