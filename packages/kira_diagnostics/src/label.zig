const Span = @import("kira_source").Span;

pub const LabelKind = enum {
    primary,
    secondary,
};

pub const Label = struct {
    kind: LabelKind = .primary,
    span: Span,
    message: []const u8,
};

pub fn primary(span: Span, message: []const u8) Label {
    return .{
        .kind = .primary,
        .span = span,
        .message = message,
    };
}

pub fn secondary(span: Span, message: []const u8) Label {
    return .{
        .kind = .secondary,
        .span = span,
        .message = message,
    };
}
