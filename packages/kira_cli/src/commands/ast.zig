const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");
const syntax = @import("kira_syntax_model");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len < 1) return error.InvalidArguments;
    const input = try support.resolveCommandInput(allocator, args[0]);

    try support.logFrontendStarted(stderr, "ast", input.source_path);
    const result = try build.parseFile(allocator, input.source_path);
    if (diagnostics.hasErrors(result.diagnostics) or result.program == null) {
        try support.logFrontendFailed(stderr, result.failure_stage, input.source_path, result.diagnostics.len);
        try support.renderDiagnostics(stderr, &result.source, result.diagnostics);
        return error.CommandFailed;
    }

    try syntax.ast.dumpProgram(stdout, result.program.?);
}
