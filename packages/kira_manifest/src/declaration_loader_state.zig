const std = @import("std");
const source = @import("kira_source");
const diagnostics = @import("kira_diagnostics");

pub const Loader = struct {
    allocator: std.mem.Allocator,
    diags: std.array_list.Managed(diagnostics.Diagnostic),
    source_path: []const u8,

    pub fn err(self: *Loader, span: source.Span, code: []const u8, title: []const u8, message: []const u8) !void {
        try diagnostics.appendOwned(self.allocator, &self.diags, .{
            .severity = .@"error",
            .code = code,
            .domain = "manifest",
            .title = title,
            .message = message,
            .labels = &.{diagnostics.primaryLabel(span, title)},
        });
    }

    pub fn warn(self: *Loader, span: source.Span, code: []const u8, title: []const u8, message: []const u8) !void {
        try diagnostics.appendOwned(self.allocator, &self.diags, .{
            .severity = .warning,
            .code = code,
            .domain = "manifest",
            .title = title,
            .message = message,
            .labels = &.{diagnostics.primaryLabel(span, title)},
        });
    }
};
