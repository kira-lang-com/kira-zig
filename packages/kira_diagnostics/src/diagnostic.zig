const Label = @import("label.zig").Label;

pub const Severity = enum {
    @"error",
    warning,
    note,
};

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    labels: []const Label,
    notes: []const []const u8 = &.{},
};

pub fn single(severity: Severity, message: []const u8, label: Label) Diagnostic {
    return .{
        .severity = severity,
        .message = message,
        .labels = &.{label},
    };
}
