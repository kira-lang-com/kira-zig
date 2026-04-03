const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");

pub fn lintFile(allocator: std.mem.Allocator, path: []const u8) ![]const diagnostics.Diagnostic {
    const result = try build.checkFile(allocator, path);
    return result.diagnostics;
}
