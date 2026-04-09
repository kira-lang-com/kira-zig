const std = @import("std");
const diagnostics = @import("kira_diagnostics");

pub fn append(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed(diagnostics.Diagnostic),
    code: []const u8,
    title: []const u8,
    message: []const u8,
    help: ?[]const u8,
) !void {
    try diagnostics.appendOwned(allocator, list, .{
        .severity = .@"error",
        .code = code,
        .title = title,
        .message = message,
        .help = help,
    });
}
