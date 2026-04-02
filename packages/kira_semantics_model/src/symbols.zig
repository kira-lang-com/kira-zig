const source_pkg = @import("kira_source");
const Type = @import("types.zig").Type;

pub const LocalSymbol = struct {
    id: u32,
    name: []const u8,
    ty: Type,
    span: source_pkg.Span,
};
