const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");

pub fn lintFile(allocator: std.mem.Allocator, path: []const u8) ![]const diagnostics.Diagnostic {
    return build.checkFile(allocator, path);
}
