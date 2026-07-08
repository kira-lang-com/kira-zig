const std = @import("std");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const type_impl = @import("lower_program_types.zig");
const form_surface = @import("construct_form_surface.zig");

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
    const body_members = try form_surface.effectiveMembers(ctx, form_decl);
    for (body_members) |member| {
        if (member != .field_decl) continue;
        const field = member.field_decl;
        if (field.body == null) continue;
        if (!returnsConcreteType(ctx, field)) continue;

        var params = std.array_list.Managed(model.ResolvedType).init(ctx.allocator);
        var ownership = std.array_list.Managed(model.OwnershipMode).init(ctx.allocator);
        try params.append(.{ .kind = .named, .name = form_decl.name });
        // `body` accessors consume self (must match lowerMethodFunction).
        try ownership.append(if (shared.methodConsumesSelf(ctx, form_decl.name, field.name, field.annotations)) .owned else .borrow_read);

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

pub fn registerFormAccessorMethods(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    type_headers: *std.StringHashMapUnmanaged(shared.TypeHeader),
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    var header = type_headers.get(form_decl.name) orelse return;
    var methods = std.array_list.Managed(shared.MethodMember).init(ctx.allocator);
    try methods.appendSlice(header.methods);

    const body_members = try form_surface.effectiveMembers(ctx, form_decl);
    for (body_members) |member| {
        if (member != .field_decl) continue;
        const field = member.field_decl;
        if (field.body == null) continue;
        if (!returnsConcreteType(ctx, field)) continue;
        if (type_impl.methodNameExists(methods.items, field.name)) continue;

        const full_name = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ form_decl.name, field.name });
        const function_header = function_headers.get(full_name) orelse continue;
        try methods.append(.{
            .name = try ctx.allocator.dupe(u8, field.name),
            .full_name = full_name,
            .receiver_type_name = try ctx.allocator.dupe(u8, form_decl.name),
            .receiver_offset = 0,
            .params = if (function_header.params.len > 0) function_header.params[1..] else &.{},
            .param_ownership = if (function_header.param_ownership.len > 0) function_header.param_ownership[1..] else &.{},
            .return_type = function_header.return_type,
            .return_ownership = function_header.return_ownership,
            .span = field.span,
        });
    }

    header.methods = try methods.toOwnedSlice();
    try type_headers.put(ctx.allocator, form_decl.name, header);
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
    const body_members = try form_surface.effectiveMembers(ctx, form_decl);
    for (body_members) |member| {
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
pub fn returnsConcreteType(ctx: *shared.Context, field: syntax.ast.FieldDecl) bool {
    const type_expr = field.type_expr orelse return false;
    if (type_expr.* != .named) return false;
    const segments = type_expr.named.segments;
    const leaf = segments[segments.len - 1].text;
    if (std.mem.eql(u8, leaf, "Int") or
        std.mem.eql(u8, leaf, "Float") or
        std.mem.eql(u8, leaf, "Bool") or
        std.mem.eql(u8, leaf, "String") or
        std.mem.eql(u8, leaf, "Void"))
        return true;
    const headers = ctx.type_headers orelse return false;
    if (headers.get(leaf) != null) return true;
    return ctx.construct_headers != null and ctx.construct_headers.?.get(leaf) != null;
}

// Turn a computed-member block into a function body that returns its value. The
// trailing statement is value-producing: a bare expression becomes `return <expr>`,
// and a trailing `if`/`match`/`switch` threads the return into each branch's tail
// (so `body { if c { A } else { B } }` returns A or B). Blocks that already `return`
// are kept. Paths that produce no value (a non-expression tail, or an `if` with no
// `else`) are left as-is; the mid-IR return check reports any path that fails to
// yield a value, so a malformed body errors cleanly instead of emitting bad IR.
fn returnize(ctx: *shared.Context, block: syntax.ast.Block) !syntax.ast.Block {
    if (block.statements.len == 0) return block;
    const last = block.statements[block.statements.len - 1];
    const rewritten = (try returnizeTail(ctx, last)) orelse return block;

    var statements = std.array_list.Managed(syntax.ast.Statement).init(ctx.allocator);
    try statements.appendSlice(block.statements[0 .. block.statements.len - 1]);
    try statements.append(rewritten);
    return .{ .statements = try statements.toOwnedSlice(), .span = block.span };
}

// Rewrite one tail-position statement so its produced value becomes a `return`.
// Returns null when the statement is not value-producing in tail position, leaving
// the enclosing block untouched. Recurses through control-flow branches so a widget
// body can be `if`/`match`/`switch` whose arms each yield the returned widget.
fn returnizeTail(ctx: *shared.Context, stmt: syntax.ast.Statement) anyerror!?syntax.ast.Statement {
    switch (stmt) {
        .expr_stmt => |expr_stmt| return syntax.ast.Statement{
            .return_stmt = .{ .value = expr_stmt.expr, .span = expr_stmt.span },
        },
        .if_stmt => |if_stmt| return syntax.ast.Statement{ .if_stmt = .{
            .condition = if_stmt.condition,
            .then_block = try returnize(ctx, if_stmt.then_block),
            .else_block = if (if_stmt.else_block) |else_block| try returnize(ctx, else_block) else null,
            .span = if_stmt.span,
        } },
        .match_stmt => |match_stmt| {
            const arms = try ctx.allocator.alloc(syntax.ast.MatchArm, match_stmt.arms.len);
            for (match_stmt.arms, 0..) |arm, index| {
                arms[index] = .{
                    .patterns = arm.patterns,
                    .guard = arm.guard,
                    .body = try returnize(ctx, arm.body),
                    .span = arm.span,
                };
            }
            return syntax.ast.Statement{ .match_stmt = .{
                .subject = match_stmt.subject,
                .arms = arms,
                .span = match_stmt.span,
            } };
        },
        .switch_stmt => |switch_stmt| {
            const cases = try ctx.allocator.alloc(syntax.ast.SwitchCase, switch_stmt.cases.len);
            for (switch_stmt.cases, 0..) |case_node, index| {
                cases[index] = .{
                    .pattern = case_node.pattern,
                    .body = try returnize(ctx, case_node.body),
                    .span = case_node.span,
                };
            }
            return syntax.ast.Statement{ .switch_stmt = .{
                .subject = switch_stmt.subject,
                .cases = cases,
                .default_block = if (switch_stmt.default_block) |default_block| try returnize(ctx, default_block) else null,
                .span = switch_stmt.span,
            } };
        },
        else => return null,
    }
}
