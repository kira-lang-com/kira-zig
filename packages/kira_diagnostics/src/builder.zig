const std = @import("std");
const source_pkg = @import("kira_source");
const diagnostic = @import("diagnostic.zig");
const label = @import("label.zig");

pub const ErrorSpec = struct {
    code: ?[]const u8 = null,
    title: []const u8,
    message: []const u8,
    span: ?source_pkg.Span = null,
    label: ?[]const u8 = null,
    help: ?[]const u8 = null,
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(diagnostic.Diagnostic),

    pub fn init(
        allocator: std.mem.Allocator,
        out: *std.array_list.Managed(diagnostic.Diagnostic),
    ) Emitter {
        return .{
            .allocator = allocator,
            .out = out,
        };
    }

    pub fn err(self: Emitter, spec: ErrorSpec) !void {
        const labels = if (spec.span) |span|
            &.{label.primary(span, spec.label orelse spec.title)}
        else
            &.{};
        try diagnostic.appendOwned(self.allocator, self.out, .{
            .severity = .@"error",
            .code = spec.code,
            .title = spec.title,
            .message = spec.message,
            .labels = labels,
            .help = spec.help,
        });
    }

    pub fn errf(
        self: Emitter,
        spec: ErrorSpec,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        var resolved = spec;
        resolved.message = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.err(resolved);
    }

    pub fn emitAndFail(self: Emitter, spec: ErrorSpec) error{ DiagnosticsEmitted, OutOfMemory } {
        self.err(spec) catch |emit_err| switch (emit_err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        return error.DiagnosticsEmitted;
    }
};
