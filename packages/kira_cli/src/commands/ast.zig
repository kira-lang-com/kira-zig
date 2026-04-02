const std = @import("std");
const build = @import("kira_build");
const syntax = @import("kira_syntax_model");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    _ = stderr;
    if (args.len < 1) return error.InvalidArguments;

    const result = try build.parseFile(allocator, args[0]);
    try syntax.ast.dumpProgram(stdout, result.program);
}
