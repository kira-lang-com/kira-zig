const std = @import("std");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const node_bridge = @import("lower_construct_node_bridge.zig");
const type_impl = @import("lower_program_types.zig");
const form_surface = @import("construct_form_surface.zig");

// Construct defaults are inherited behavior, but the runtime dispatcher operates on concrete
// form methods. Materialize each missing default as `Form.member(self, ...)` so `any Widget`
// dispatch reaches the same implementation on vm/llvm/hybrid.

pub fn registerDefaultFunctionHeaders(
    ctx: *shared.Context,
    program: syntax.ast.Program,
    form_decl: syntax.ast.ConstructFormDecl,
    function_headers: *std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    const defaults = try inheritedDefaults(ctx, program, form_decl);
    for (defaults) |default| {
        if (try formDeclaresMember(ctx, form_decl, default.name)) continue;
        if (!defaultDependenciesAvailable(ctx, program, form_decl, default)) continue;
        switch (default.kind) {
            .field => |field| if (!node_bridge.returnsConcreteType(ctx, field)) continue,
            .function => {},
        }

        const full_name = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ form_decl.name, default.name });
        if (function_headers.get(full_name) != null) continue;

        var params = std.array_list.Managed(model.ResolvedType).init(ctx.allocator);
        var ownership = std.array_list.Managed(model.OwnershipMode).init(ctx.allocator);
        try params.append(.{ .kind = .named, .name = form_decl.name });
        try ownership.append(.borrow_read);

        switch (default.kind) {
            .field => |field| {
                try function_headers.put(ctx.allocator, full_name, .{
                    .id = @as(u32, @intCast(function_headers.count())),
                    .params = try params.toOwnedSlice(),
                    .param_ownership = try ownership.toOwnedSlice(),
                    .execution = .inherited,
                    .return_type = if (field.type_expr) |type_expr| try shared.typeFromSyntaxChecked(ctx, type_expr.*) else .{ .kind = .unknown },
                    .return_ownership = .owned,
                    .is_accessor = true,
                    .span = field.span,
                });
            },
            .function => |function| {
                for (function.params) |param| {
                    try ownership.append(shared.ownershipModeFromSyntax(param.type_expr));
                    try params.append(if (param.type_expr) |type_expr| try shared.typeFromSyntaxChecked(ctx, type_expr.*) else .{ .kind = .unknown });
                }
                try function_headers.put(ctx.allocator, full_name, .{
                    .id = @as(u32, @intCast(function_headers.count())),
                    .params = try params.toOwnedSlice(),
                    .param_ownership = try ownership.toOwnedSlice(),
                    .execution = .inherited,
                    .return_type = if (function.return_type) |return_type| try shared.typeFromSyntaxChecked(ctx, return_type.*) else .{ .kind = .unknown },
                    .return_ownership = shared.ownershipModeFromSyntax(function.return_type),
                    .span = function.span,
                });
            },
        }
    }
}

pub fn registerDefaultMethods(
    ctx: *shared.Context,
    program: syntax.ast.Program,
    form_decl: syntax.ast.ConstructFormDecl,
    type_headers: *std.StringHashMapUnmanaged(shared.TypeHeader),
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    var header = type_headers.get(form_decl.name) orelse return;
    var methods = std.array_list.Managed(shared.MethodMember).init(ctx.allocator);
    try methods.appendSlice(header.methods);

    const defaults = try inheritedDefaults(ctx, program, form_decl);
    for (defaults) |default| {
        if (try formDeclaresMember(ctx, form_decl, default.name)) continue;
        if (!defaultDependenciesAvailable(ctx, program, form_decl, default)) continue;
        if (type_impl.methodNameExists(methods.items, default.name)) continue;

        const full_name = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ form_decl.name, default.name });
        const function_header = function_headers.get(full_name) orelse continue;
        try methods.append(.{
            .name = try ctx.allocator.dupe(u8, default.name),
            .full_name = full_name,
            .receiver_type_name = try ctx.allocator.dupe(u8, form_decl.name),
            .receiver_offset = 0,
            .params = if (function_header.params.len > 0) function_header.params[1..] else &.{},
            .param_ownership = if (function_header.param_ownership.len > 0) function_header.param_ownership[1..] else &.{},
            .return_type = function_header.return_type,
            .return_ownership = function_header.return_ownership,
            .span = default.span,
        });
    }

    header.methods = try methods.toOwnedSlice();
    try type_headers.put(ctx.allocator, form_decl.name, header);
}

pub fn lowerDefaultFunctions(
    ctx: *shared.Context,
    program: syntax.ast.Program,
    form_decl: syntax.ast.ConstructFormDecl,
    imports: []const model.Import,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) ![]model.Function {
    var functions = std.array_list.Managed(model.Function).init(ctx.allocator);
    const defaults = try inheritedDefaults(ctx, program, form_decl);
    for (defaults) |default| {
        if (try formDeclaresMember(ctx, form_decl, default.name)) continue;
        if (!defaultDependenciesAvailable(ctx, program, form_decl, default)) continue;
        const function_decl = switch (default.kind) {
            .field => |field| blk: {
                const body = field.body orelse continue;
                if (!node_bridge.returnsConcreteType(ctx, field)) continue;
                const rewritten_body = try qualifyImplicitSelf(ctx, try returnize(ctx, body), form_decl);
                break :blk syntax.ast.FunctionDecl{
                    .annotations = &.{},
                    .name = field.name,
                    .params = &.{},
                    .return_type = field.type_expr,
                    .body = rewritten_body,
                    .span = field.span,
                };
            },
            .function => |function| blk: {
                var rewritten = function;
                if (function.body) |body| rewritten.body = try qualifyImplicitSelf(ctx, body, form_decl);
                break :blk rewritten;
            },
        };
        try functions.append(try type_impl.lowerMethodFunction(ctx, form_decl.name, function_decl, imports, function_headers));
    }
    return functions.toOwnedSlice();
}

const DefaultKind = union(enum) {
    field: syntax.ast.FieldDecl,
    function: syntax.ast.FunctionDecl,
};

const DefaultMember = struct {
    name: []const u8,
    kind: DefaultKind,
    span: @import("kira_source").Span,
};

fn inheritedDefaults(
    ctx: *shared.Context,
    program: syntax.ast.Program,
    form_decl: syntax.ast.ConstructFormDecl,
) ![]DefaultMember {
    const families = ctx.form_families orelse return &.{};
    const form_families = families.get(form_decl.name) orelse return &.{};
    var defaults = std.array_list.Managed(DefaultMember).init(ctx.allocator);
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(ctx.allocator);

    for (form_families) |family| {
        const construct_decl = findConstructDecl(program, family) orelse continue;
        for (construct_decl.members) |member| {
            switch (member) {
                .field_decl => |field| {
                    if (field.body == null or seen.contains(field.name)) continue;
                    try seen.put(ctx.allocator, field.name, {});
                    try defaults.append(.{
                        .name = field.name,
                        .kind = .{ .field = field },
                        .span = field.span,
                    });
                },
                .function_decl => |function| {
                    if (function.body == null or seen.contains(function.name)) continue;
                    try seen.put(ctx.allocator, function.name, {});
                    try defaults.append(.{
                        .name = function.name,
                        .kind = .{ .function = function },
                        .span = function.span,
                    });
                },
                else => {},
            }
        }
    }
    return defaults.toOwnedSlice();
}

fn findConstructDecl(program: syntax.ast.Program, name: []const u8) ?syntax.ast.ConstructDecl {
    for (program.decls) |decl| {
        if (decl != .construct_decl) continue;
        if (std.mem.eql(u8, decl.construct_decl.name, name)) return decl.construct_decl;
    }
    return null;
}

fn formDeclaresMember(ctx: *shared.Context, form_decl: syntax.ast.ConstructFormDecl, name: []const u8) !bool {
    const members = try form_surface.effectiveMembers(ctx, form_decl);
    for (members) |member| {
        switch (member) {
            .field_decl => |field| if (std.mem.eql(u8, field.name, name)) return true,
            .function_decl => |function| if (std.mem.eql(u8, function.name, name)) return true,
            else => {},
        }
    }
    return false;
}

fn defaultDependenciesAvailable(
    ctx: *shared.Context,
    program: syntax.ast.Program,
    form_decl: syntax.ast.ConstructFormDecl,
    default: DefaultMember,
) bool {
    return switch (default.kind) {
        .field => |field| if (field.body) |body|
            blockDependenciesAvailable(ctx, program, form_decl, body, &.{})
        else
            true,
        .function => |function| if (function.body) |body|
            blockDependenciesAvailable(ctx, program, form_decl, body, function.params)
        else
            true,
    };
}

fn blockDependenciesAvailable(
    ctx: *shared.Context,
    program: syntax.ast.Program,
    form_decl: syntax.ast.ConstructFormDecl,
    block: syntax.ast.Block,
    params: []const syntax.ast.ParamDecl,
) bool {
    for (block.statements) |statement| {
        if (!statementDependenciesAvailable(ctx, program, form_decl, statement, params)) return false;
    }
    return true;
}

fn statementDependenciesAvailable(
    ctx: *shared.Context,
    program: syntax.ast.Program,
    form_decl: syntax.ast.ConstructFormDecl,
    statement: syntax.ast.Statement,
    params: []const syntax.ast.ParamDecl,
) bool {
    return switch (statement) {
        .let_stmt => |stmt| stmt.value == null or exprDependenciesAvailable(ctx, program, form_decl, stmt.value.?, params),
        .assign_stmt => |stmt| exprDependenciesAvailable(ctx, program, form_decl, stmt.target, params) and exprDependenciesAvailable(ctx, program, form_decl, stmt.value, params),
        .expr_stmt => |stmt| exprDependenciesAvailable(ctx, program, form_decl, stmt.expr, params),
        .return_stmt => |stmt| stmt.value == null or exprDependenciesAvailable(ctx, program, form_decl, stmt.value.?, params),
        else => true,
    };
}

fn exprDependenciesAvailable(
    ctx: *shared.Context,
    program: syntax.ast.Program,
    form_decl: syntax.ast.ConstructFormDecl,
    expr: *syntax.ast.Expr,
    params: []const syntax.ast.ParamDecl,
) bool {
    return switch (expr.*) {
        .identifier => |ident| rootAvailable(ctx, program, form_decl, ident.name, params),
        .member => |member| exprDependenciesAvailable(ctx, program, form_decl, member.object, params),
        .call => |call| blk: {
            if (!exprDependenciesAvailable(ctx, program, form_decl, call.callee, params)) break :blk false;
            for (call.args) |arg| {
                if (!exprDependenciesAvailable(ctx, program, form_decl, arg.value, params)) break :blk false;
            }
            break :blk true;
        },
        .array => |array| blk: {
            for (array.elements) |element| {
                if (!exprDependenciesAvailable(ctx, program, form_decl, element, params)) break :blk false;
            }
            break :blk true;
        },
        .struct_literal => |literal| blk: {
            for (literal.fields) |field| {
                if (!exprDependenciesAvailable(ctx, program, form_decl, field.value, params)) break :blk false;
            }
            break :blk true;
        },
        .index => |index| exprDependenciesAvailable(ctx, program, form_decl, index.object, params) and exprDependenciesAvailable(ctx, program, form_decl, index.index, params),
        .unary => |unary| exprDependenciesAvailable(ctx, program, form_decl, unary.operand, params),
        .ownership => |ownership| exprDependenciesAvailable(ctx, program, form_decl, ownership.operand, params),
        .try_expr => |try_expr| exprDependenciesAvailable(ctx, program, form_decl, try_expr.operand, params),
        .binary => |binary| exprDependenciesAvailable(ctx, program, form_decl, binary.lhs, params) and exprDependenciesAvailable(ctx, program, form_decl, binary.rhs, params),
        .conditional => |conditional| exprDependenciesAvailable(ctx, program, form_decl, conditional.condition, params) and exprDependenciesAvailable(ctx, program, form_decl, conditional.then_expr, params) and exprDependenciesAvailable(ctx, program, form_decl, conditional.else_expr, params),
        else => true,
    };
}

fn rootAvailable(
    ctx: *shared.Context,
    program: syntax.ast.Program,
    form_decl: syntax.ast.ConstructFormDecl,
    name: syntax.ast.QualifiedName,
    params: []const syntax.ast.ParamDecl,
) bool {
    if (name.segments.len == 0) return true;
    const root = name.segments[0].text;
    if (std.mem.eql(u8, root, "self")) return true;
    for (params) |param| {
        if (std.mem.eql(u8, param.name, root)) return true;
    }
    if (!constructFamilyDeclaresMember(program, form_decl, root)) return true;
    return formDeclaresMember(ctx, form_decl, root) catch false;
}

fn constructFamilyDeclaresMember(
    program: syntax.ast.Program,
    form_decl: syntax.ast.ConstructFormDecl,
    name: []const u8,
) bool {
    const family = form_decl.construct_name.segments[form_decl.construct_name.segments.len - 1].text;
    const construct_decl = findConstructDecl(program, family) orelse return false;
    for (construct_decl.members) |member| {
        switch (member) {
            .field_decl => |field| if (std.mem.eql(u8, field.name, name)) return true,
            .function_decl => |function| if (std.mem.eql(u8, function.name, name)) return true,
            else => {},
        }
    }
    return false;
}

fn qualifyImplicitSelf(
    ctx: *shared.Context,
    block: syntax.ast.Block,
    form_decl: syntax.ast.ConstructFormDecl,
) !syntax.ast.Block {
    var statements = std.array_list.Managed(syntax.ast.Statement).init(ctx.allocator);
    for (block.statements) |statement| try statements.append(try qualifyStatement(ctx, statement, form_decl));
    return .{ .statements = try statements.toOwnedSlice(), .span = block.span };
}

fn qualifyStatement(
    ctx: *shared.Context,
    statement: syntax.ast.Statement,
    form_decl: syntax.ast.ConstructFormDecl,
) anyerror!syntax.ast.Statement {
    switch (statement) {
        .let_stmt => |stmt| {
            var rewritten = stmt;
            if (stmt.value) |value| rewritten.value = try qualifyExpr(ctx, value, form_decl);
            return .{ .let_stmt = rewritten };
        },
        .assign_stmt => |stmt| return .{ .assign_stmt = .{
            .target = try qualifyExpr(ctx, stmt.target, form_decl),
            .value = try qualifyExpr(ctx, stmt.value, form_decl),
            .span = stmt.span,
        } },
        .expr_stmt => |stmt| return .{ .expr_stmt = .{ .expr = try qualifyExpr(ctx, stmt.expr, form_decl), .span = stmt.span } },
        .return_stmt => |stmt| {
            var rewritten = stmt;
            if (stmt.value) |value| rewritten.value = try qualifyExpr(ctx, value, form_decl);
            return .{ .return_stmt = rewritten };
        },
        else => return statement,
    }
}

fn qualifyExpr(
    ctx: *shared.Context,
    expr: *syntax.ast.Expr,
    form_decl: syntax.ast.ConstructFormDecl,
) anyerror!*syntax.ast.Expr {
    const out = try ctx.allocator.create(syntax.ast.Expr);
    out.* = switch (expr.*) {
        .identifier => |ident| if (ident.name.segments.len > 0 and (formDeclaresMember(ctx, form_decl, ident.name.segments[0].text) catch false))
            try selfMemberChain(ctx, ident.name)
        else
            expr.*,
        .member => |member| .{ .member = .{
            .object = try qualifyExpr(ctx, member.object, form_decl),
            .member = member.member,
            .span = member.span,
        } },
        .call => |call| .{ .call = .{
            .callee = try qualifyExpr(ctx, call.callee, form_decl),
            .args = try qualifyCallArgs(ctx, call.args, form_decl),
            .trailing_builder = call.trailing_builder,
            .trailing_callback = call.trailing_callback,
            .span = call.span,
        } },
        .array => |array| .{ .array = .{ .elements = try qualifyExprList(ctx, array.elements, form_decl), .span = array.span } },
        .struct_literal => |literal| .{ .struct_literal = .{
            .type_name = literal.type_name,
            .fields = try qualifyStructFields(ctx, literal.fields, form_decl),
            .span = literal.span,
        } },
        .index => |index| .{ .index = .{
            .object = try qualifyExpr(ctx, index.object, form_decl),
            .index = try qualifyExpr(ctx, index.index, form_decl),
            .span = index.span,
        } },
        .unary => |unary| .{ .unary = .{ .op = unary.op, .operand = try qualifyExpr(ctx, unary.operand, form_decl), .span = unary.span } },
        .ownership => |ownership| .{ .ownership = .{ .op = ownership.op, .operand = try qualifyExpr(ctx, ownership.operand, form_decl), .span = ownership.span } },
        .try_expr => |try_expr| .{ .try_expr = .{ .operand = try qualifyExpr(ctx, try_expr.operand, form_decl), .span = try_expr.span } },
        .binary => |binary| .{ .binary = .{
            .op = binary.op,
            .lhs = try qualifyExpr(ctx, binary.lhs, form_decl),
            .rhs = try qualifyExpr(ctx, binary.rhs, form_decl),
            .span = binary.span,
        } },
        .conditional => |conditional| .{ .conditional = .{
            .condition = try qualifyExpr(ctx, conditional.condition, form_decl),
            .then_expr = try qualifyExpr(ctx, conditional.then_expr, form_decl),
            .else_expr = try qualifyExpr(ctx, conditional.else_expr, form_decl),
            .span = conditional.span,
        } },
        else => expr.*,
    };
    return out;
}

fn selfMemberChain(ctx: *shared.Context, name: syntax.ast.QualifiedName) !syntax.ast.Expr {
    const self_expr = try ctx.allocator.create(syntax.ast.Expr);
    self_expr.* = .{ .identifier = .{
        .name = .{
            .segments = try singleSegment(ctx, "self", name.span),
            .span = name.span,
        },
        .span = name.span,
    } };

    var current = self_expr;
    for (name.segments) |segment| {
        const next = try ctx.allocator.create(syntax.ast.Expr);
        next.* = .{ .member = .{
            .object = current,
            .member = segment.text,
            .span = segment.span,
        } };
        current = next;
    }
    return current.*;
}

fn singleSegment(ctx: *shared.Context, text: []const u8, span: @import("kira_source").Span) ![]syntax.ast.NameSegment {
    const segments = try ctx.allocator.alloc(syntax.ast.NameSegment, 1);
    segments[0] = .{ .text = text, .span = span };
    return segments;
}

fn qualifyExprList(
    ctx: *shared.Context,
    values: []*syntax.ast.Expr,
    form_decl: syntax.ast.ConstructFormDecl,
) ![]*syntax.ast.Expr {
    const out = try ctx.allocator.alloc(*syntax.ast.Expr, values.len);
    for (values, 0..) |value, index| out[index] = try qualifyExpr(ctx, value, form_decl);
    return out;
}

fn qualifyCallArgs(
    ctx: *shared.Context,
    args: []const syntax.ast.CallArg,
    form_decl: syntax.ast.ConstructFormDecl,
) ![]syntax.ast.CallArg {
    const out = try ctx.allocator.alloc(syntax.ast.CallArg, args.len);
    for (args, 0..) |arg, index| {
        out[index] = arg;
        out[index].value = try qualifyExpr(ctx, arg.value, form_decl);
    }
    return out;
}

fn qualifyStructFields(
    ctx: *shared.Context,
    fields: []const syntax.ast.StructLiteralField,
    form_decl: syntax.ast.ConstructFormDecl,
) ![]syntax.ast.StructLiteralField {
    const out = try ctx.allocator.alloc(syntax.ast.StructLiteralField, fields.len);
    for (fields, 0..) |field, index| {
        out[index] = field;
        out[index].value = try qualifyExpr(ctx, field.value, form_decl);
    }
    return out;
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
