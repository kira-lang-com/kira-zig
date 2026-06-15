const std = @import("std");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const type_impl = @import("lower_program_types.zig");

// The Widget->Node bridge executes through computed-property accessors. A computed member
// `let node: T { ... }` on a concrete declaration lowers to a nullary method `Form.node(self) -> T`
// whose body returns the block's value, and is marked `is_accessor` so bare member access
// (`widget.node`, no parens) invokes it. This reuses the ordinary struct-method machinery, so the
// accessor runs identically on vm/llvm/hybrid.

// Register a callable header for each computed member of a concrete declaration, so accessors
// resolve during body lowering and during member-access lowering.
pub fn registerFormAccessorHeaders(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    function_headers: *std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    for (form_decl.body.members) |member| {
        if (member != .field_decl) continue;
        const field = member.field_decl;
        if (field.body == null) continue;
        if (!returnsConcreteType(ctx, field)) continue;

        var params = std.array_list.Managed(model.ResolvedType).init(ctx.allocator);
        var ownership = std.array_list.Managed(model.OwnershipMode).init(ctx.allocator);
        try params.append(.{ .kind = .named, .name = form_decl.name });
        try ownership.append(.borrow_read);

        const key = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ form_decl.name, field.name });
        try function_headers.put(ctx.allocator, key, .{
            .id = @as(u32, @intCast(function_headers.count())),
            .params = try params.toOwnedSlice(),
            .param_ownership = try ownership.toOwnedSlice(),
            .execution = .inherited,
            .return_type = if (field.type_expr) |type_expr| try shared.typeFromSyntaxChecked(ctx, type_expr.*) else .{ .kind = .unknown },
            .return_ownership = .owned,
            .is_accessor = true,
            .span = field.span,
        });
    }
}

// Lower each computed member into a `Form.member(self) -> T` accessor function. The block's
// trailing expression is returned, so `let node: T { TextNode(text: text) }` becomes
// `function node(self) -> T { return TextNode(text: text) }` (bare field names resolve via
// implicit `self`).
pub fn lowerFormAccessors(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    imports: []const model.Import,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) ![]model.Function {
    var functions = std.array_list.Managed(model.Function).init(ctx.allocator);
    for (form_decl.body.members) |member| {
        if (member != .field_decl) continue;
        const field = member.field_decl;
        const body = field.body orelse continue;
        if (!returnsConcreteType(ctx, field)) continue;

        const accessor = syntax.ast.FunctionDecl{
            .annotations = &.{},
            .name = field.name,
            .params = &.{},
            .return_type = field.type_expr,
            .body = try returnize(ctx, body),
            .span = field.span,
        };
        try functions.append(try type_impl.lowerMethodFunction(ctx, form_decl.name, accessor, imports, function_headers));
    }
    return functions.toOwnedSlice();
}

// A computed accessor is lowered to runtime only when its declared return type is a concrete,
// known type (a struct/class — i.e. present in `type_headers`, which includes the declaration
// structs themselves). A computed member typed by an abstract construct family (`let node: Node`)
// can only be realized through `any`-dispatch, which is not yet wired, so it stays validation-only
// — preserving the prior skip behavior and keeping such declarations buildable.
fn returnsConcreteType(ctx: *shared.Context, field: syntax.ast.FieldDecl) bool {
    const type_expr = field.type_expr orelse return false;
    if (type_expr.* != .named) return false;
    const segments = type_expr.named.segments;
    const leaf = segments[segments.len - 1].text;
    const headers = ctx.type_headers orelse return false;
    return headers.get(leaf) != null;
}

// Turn a computed-member block into a function body that returns its value: if the final
// statement is a bare expression, wrap it in a `return`. Blocks that already `return` are kept.
fn returnize(ctx: *shared.Context, block: syntax.ast.Block) !syntax.ast.Block {
    if (block.statements.len == 0) return block;
    const last = block.statements[block.statements.len - 1];
    if (last != .expr_stmt) return block;

    var statements = std.array_list.Managed(syntax.ast.Statement).init(ctx.allocator);
    try statements.appendSlice(block.statements[0 .. block.statements.len - 1]);
    try statements.append(.{ .return_stmt = .{ .value = last.expr_stmt.expr, .span = last.expr_stmt.span } });
    return .{ .statements = try statements.toOwnedSlice(), .span = block.span };
}
