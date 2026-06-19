const std = @import("std");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const parent = @import("lower_program.zig");

const lowerFunction = parent.lowerFunction;

pub fn registerTypeAccessorHeaders(
    ctx: *shared.Context,
    type_decl: syntax.ast.TypeDecl,
    function_headers: *std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    for (type_decl.members) |member| {
        if (member != .field_decl) continue;
        const field = member.field_decl;
        if (field.body == null) continue;
        const key = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ type_decl.name, field.name });
        try function_headers.put(ctx.allocator, key, .{
            .id = @as(u32, @intCast(function_headers.count())),
            .params = &.{},
            .param_ownership = &.{},
            .param_defaults = &.{},
            .execution = .inherited,
            .return_type = if (field.type_expr) |type_expr| try shared.typeFromSyntaxChecked(ctx, type_expr.*) else .{ .kind = .unknown },
            .return_ownership = .owned,
            .is_accessor = true,
            .span = field.span,
        });
    }
}

pub fn lowerTypeAccessors(
    ctx: *shared.Context,
    type_decl: syntax.ast.TypeDecl,
    imports: []const model.Import,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) ![]model.Function {
    var functions = std.array_list.Managed(model.Function).init(ctx.allocator);
    for (type_decl.members) |member| {
        if (member != .field_decl) continue;
        const field = member.field_decl;
        const body = field.body orelse continue;
        try functions.append(try lowerFunction(ctx, .{
            .annotations = &.{},
            .name = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ type_decl.name, field.name }),
            .params = &.{},
            .return_type = field.type_expr,
            .body = try returnize(ctx, body),
            .span = field.span,
        }, imports, function_headers));
    }
    return functions.toOwnedSlice();
}

fn returnize(ctx: *shared.Context, block: syntax.ast.Block) !syntax.ast.Block {
    if (block.statements.len == 0) return block;
    const last = block.statements[block.statements.len - 1];
    if (last != .expr_stmt) return block;

    var statements = std.array_list.Managed(syntax.ast.Statement).init(ctx.allocator);
    try statements.appendSlice(block.statements[0 .. block.statements.len - 1]);
    try statements.append(.{ .return_stmt = .{ .value = last.expr_stmt.expr, .span = last.expr_stmt.span } });
    return .{ .statements = try statements.toOwnedSlice(), .span = block.span };
}
