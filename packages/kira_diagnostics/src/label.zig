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
