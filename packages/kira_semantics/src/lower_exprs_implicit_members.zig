//! Expected-type resolution for leading-dot expressions (`.case`,
//! `.Concrete(...)`, `.factory(...)`, and `.callback`). This pass rewrites the
//! syntax to the already-supported qualified/bare expression; all HIR and
//! backend lowering therefore remains identical to the explicit spelling.
const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const function_types = @import("lower_exprs_function_types.zig");

const Target = struct {
    name: []const u8,
    call: ?syntax.ast.CallExpr,
    span: @import("kira_source").Span,
};

pub fn rewriteExpected(
    ctx: *shared.Context,
    expr: *syntax.ast.Expr,
    expected: model.ResolvedType,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !?*syntax.ast.Expr {
    const target = implicitTarget(expr) orelse return null;

    if (target.call == null and expected.kind == .callback) {
        if (try callbackCandidate(ctx, target.name, expected, function_headers)) {
            return makeIdentifier(ctx, target.name, target.span);
        }
        return emitUnknown(ctx, target, expected);
    }

    if (target.call) |call| {
        // A concrete type/form wins when its value is compatible with the
        // expected class, struct, or construct-family existential.
        if (typeCandidateFits(ctx, target.name, expected)) {
            return rewriteCall(ctx, call, try makeIdentifier(ctx, target.name, target.span));
        }

        // A function declared in the expected type namespace is the direct
        // replacement for `Expected.factory(...)`.
        if (expectedNamespace(expected)) |namespace| {
            const qualified = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ namespace, target.name });
            if (functionCandidateFits(ctx, qualified, expected, function_headers)) {
                return rewriteCall(ctx, call, try makeMember(ctx, namespace, target.name, target.span));
            }
        }

        // Free functions participate by result type. The name is still
        // explicit, so overload selection is deterministic.
        if (functionCandidateFits(ctx, target.name, expected, function_headers)) {
            return rewriteCall(ctx, call, try makeIdentifier(ctx, target.name, target.span));
        }
        return emitUnknown(ctx, target, expected);
    }

    // Immutable type-qualified values such as `Theme.standard` can use
    // `.standard` when the surrounding expression expects their value type.
    if (expectedNamespace(expected)) |namespace| {
        if (constantCandidateFits(ctx, namespace, target.name, expected)) {
            return makeMember(ctx, namespace, target.name, target.span);
        }
    }
    return emitUnknown(ctx, target, expected);
}

pub fn isImplicit(expr: *syntax.ast.Expr) bool {
    return implicitTarget(expr) != null;
}

fn implicitTarget(expr: *syntax.ast.Expr) ?Target {
    return switch (expr.*) {
        .implicit_member => |node| .{ .name = node.name, .call = null, .span = node.span },
        .call => |call| switch (call.callee.*) {
            .implicit_member => |node| .{ .name = node.name, .call = call, .span = call.span },
            else => null,
        },
        else => null,
    };
}

fn expectedNamespace(expected: model.ResolvedType) ?[]const u8 {
    return switch (expected.kind) {
        .named, .enum_instance => expected.name,
        .construct_any => if (expected.construct_constraint) |constraint| constraint.construct_name else null,
        else => null,
    };
}

fn typeCandidateFits(ctx: *shared.Context, name: []const u8, expected: model.ResolvedType) bool {
    const exists = (ctx.type_headers != null and ctx.type_headers.?.get(name) != null) or
        ctx.imported_globals.findType(name) != null;
    if (!exists) return false;
    return shared.canAssignInContext(ctx, expected, .{ .kind = .named, .name = name });
}

fn functionCandidateFits(
    ctx: *shared.Context,
    name: []const u8,
    expected: model.ResolvedType,
    headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) bool {
    if (shared.findFunctionHeader(ctx, headers, name)) |header| {
        return shared.canAssignInContext(ctx, expected, header.return_type);
    }
    if (ctx.imported_globals.findFunction(name)) |function| {
        return shared.canAssignInContext(ctx, expected, function.return_type);
    }
    return false;
}

fn callbackCandidate(
    ctx: *shared.Context,
    name: []const u8,
    expected: model.ResolvedType,
    headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !bool {
    if (shared.findFunctionHeader(ctx, headers, name)) |header| {
        const actual = try function_types.functionTypeFromHeader(ctx.allocator, header);
        return expected.eql(actual);
    }
    if (ctx.imported_globals.findFunction(name)) |function| {
        const actual = try function_types.functionTypeFromResolvedSignature(ctx.allocator, function.params, function.return_type);
        return expected.eql(actual);
    }
    return false;
}

fn constantCandidateFits(
    ctx: *shared.Context,
    namespace: []const u8,
    member_name: []const u8,
    expected: model.ResolvedType,
) bool {
    const header = shared.namedTypeHeader(ctx, .{ .kind = .named, .name = namespace }) orelse return false;
    for (header.fields) |field| {
        if (field.storage == .immutable and std.mem.eql(u8, field.name, member_name)) {
            return shared.canAssignInContext(ctx, expected, field.ty);
        }
    }
    return false;
}

fn makeIdentifier(ctx: *shared.Context, name: []const u8, span: @import("kira_source").Span) !*syntax.ast.Expr {
    const segments = try ctx.allocator.alloc(syntax.ast.NameSegment, 1);
    segments[0] = .{ .text = try ctx.allocator.dupe(u8, name), .span = span };
    const expr = try ctx.allocator.create(syntax.ast.Expr);
    expr.* = .{ .identifier = .{ .name = .{ .segments = segments, .span = span }, .span = span } };
    return expr;
}

fn makeMember(
    ctx: *shared.Context,
    namespace: []const u8,
    name: []const u8,
    span: @import("kira_source").Span,
) !*syntax.ast.Expr {
    const object = try makeIdentifier(ctx, namespace, span);
    const expr = try ctx.allocator.create(syntax.ast.Expr);
    expr.* = .{ .member = .{ .object = object, .member = try ctx.allocator.dupe(u8, name), .span = span } };
    return expr;
}

fn rewriteCall(ctx: *shared.Context, call: syntax.ast.CallExpr, callee: *syntax.ast.Expr) !*syntax.ast.Expr {
    const expr = try ctx.allocator.create(syntax.ast.Expr);
    var rewritten = call;
    rewritten.callee = callee;
    expr.* = .{ .call = rewritten };
    return expr;
}

fn emitUnknown(ctx: *shared.Context, target: Target, expected: model.ResolvedType) !?*syntax.ast.Expr {
    const expected_text = try shared.typeTextFromResolved(ctx.allocator, expected);
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM167",
        .title = "unknown implicit member",
        .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not resolve '.{s}' to a value compatible with '{s}'.", .{ target.name, expected_text }),
        .labels = &.{diagnostics.primaryLabel(target.span, "no compatible declaration has this name")},
        .help = "Check the member spelling, or use the fully qualified expression to select a declaration explicitly.",
    });
    return error.DiagnosticsEmitted;
}
