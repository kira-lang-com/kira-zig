const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len < 1) return error.InvalidArguments;
    const result = try build.checkFile(allocator, args[0]);
    if (result.diagnostics.len == 0) {
        try stdout.writeAll("check passed\n");
        return;
    }
    try diagnostics.renderer.renderAll(stderr, &result.source, result.diagnostics);
}
