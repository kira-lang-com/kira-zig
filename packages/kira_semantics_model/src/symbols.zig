const source_pkg = @import("kira_source");
const ResolvedType = @import("types.zig").ResolvedType;

pub const LocalSymbol = struct {
    id: u32,
    name: []const u8,
    ty: ResolvedType,
    is_param: bool = false,
    span: source_pkg.Span,
};
