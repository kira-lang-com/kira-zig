//! Enum-variant construction lowering: recognizes `Enum.variant` member and
//! `Enum.variant(payload)` call expressions (with or without an expected enum
//! type), resolves the enum declaration and variant, validates payload
//! presence/absence, and lowers to a `construct_enum_variant` HIR expression.
const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const types = @import("lower_exprs_types.zig");
const parent = @import("lower_exprs.zig");

const flattenMemberExprPath = types.flattenMemberExprPath;
const qualifiedLeaf = types.qualifiedLeaf;
const lowerExpr = parent.lowerExpr;

pub fn lowerEnumVariantExprExpected(
    ctx: *shared.Context,
    expr: *syntax.ast.Expr,
    expected_type: model.ResolvedType,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) anyerror!?*model.Expr {
    if (expected_type.name == null) return null;
    if (expected_type.kind != .enum_instance and expected_type.kind != .named) return null;
    if (resolveEnumDecl(ctx, expected_type.name.?) == null and resolveEnumDecl(ctx, qualifiedLeaf(expected_type.name.?)) == null) return null;
    return lowerEnumVariantExpr(ctx, expr, expected_type, imports, scope, function_headers);
}

pub fn lowerEnumVariantExpr(
    ctx: *shared.Context,
    expr: *syntax.ast.Expr,
    expected_type: model.ResolvedType,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) anyerror!?*model.Expr {
    const EnumTarget = struct {
        enum_name: []const u8,
        variant_name: []const u8,
        payload_expr: ?*syntax.ast.Expr,
        span: source_pkg.Span,
    };
    const MemberTarget = struct {
        enum_name: []const u8,
        variant_name: []const u8,
    };

    const enum_target: EnumTarget = switch (expr.*) {
        .implicit_member => |node| .{
            .enum_name = expected_type.name orelse return null,
            .variant_name = node.name,
            .payload_expr = null,
            .span = node.span,
        },
        .member => |node| .{
            .enum_name = expected_type.name orelse try flattenMemberExprPath(ctx.allocator, node.object),
            .variant_name = node.member,
            .payload_expr = @as(?*syntax.ast.Expr, null),
            .span = node.span,
        },
        .call => |node| blk: {
            if ((node.callee.* != .member and node.callee.* != .implicit_member) or node.trailing_builder != null or node.trailing_callback != null) return null;
            if (node.args.len > 1) return null;
            const target: MemberTarget = switch (node.callee.*) {
                .implicit_member => |member| .{
                    .enum_name = expected_type.name orelse return null,
                    .variant_name = member.name,
                },
                .member => |member| .{
                    .enum_name = expected_type.name orelse try flattenMemberExprPath(ctx.allocator, member.object),
                    .variant_name = member.member,
                },
                else => unreachable,
            };
            break :blk .{
                .enum_name = target.enum_name,
                .variant_name = target.variant_name,
                .payload_expr = if (node.args.len == 1) node.args[0].value else null,
                .span = node.span,
            };
        },
        else => return null,
    };

    const resolved_name = resolveEnumName(ctx, enum_target.enum_name, expected_type.name orelse "");
    const enum_decl = resolveEnumDecl(ctx, resolved_name) orelse return null;
    if (enum_decl.type_params.len != 0 and (expected_type.name == null or !std.mem.eql(u8, expected_type.name.?, resolved_name))) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM106",
            .title = "generic enum constructor needs an explicit type",
            .message = "Generic enum variant construction currently needs an explicit surrounding enum type.",
            .labels = &.{diagnostics.primaryLabel(enum_target.span, "constructor does not provide enough type information")},
            .help = "Write an explicit type such as `let value: Result<String, ParseError> = Result.Ok(\"ok\")`.",
        });
        return error.DiagnosticsEmitted;
    }

    const variant_decl = findEnumVariant(enum_decl, enum_target.variant_name) orelse return null;
    const payload = if (enum_target.payload_expr) |payload_expr|
        if (variant_decl.payload_ty) |payload_ty|
            if (function_headers) |headers|
                try types.lowerExpectedValue(ctx, payload_expr, payload_ty, imports, scope, headers, enum_target.span)
            else
                try lowerExpr(ctx, payload_expr, imports, scope, function_headers)
        else {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM105",
                .title = "match pattern payload is invalid",
                .message = "This enum variant does not accept a payload value.",
                .labels = &.{diagnostics.primaryLabel(enum_target.span, "payload value is not valid for this enum variant")},
                .help = "Remove the argument from this enum constructor call.",
            });
            return error.DiagnosticsEmitted;
        }
    else if (variant_decl.payload_ty != null)
        variant_decl.default_value
    else
        null;

    if (variant_decl.payload_ty != null and payload == null) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM105",
            .title = "match pattern payload is invalid",
            .message = "This enum variant requires an associated payload value.",
            .labels = &.{diagnostics.primaryLabel(enum_target.span, "missing enum payload value")},
            .help = "Pass the payload argument or add a default value on the enum variant declaration.",
        });
        return error.DiagnosticsEmitted;
    }

    const lowered = try ctx.allocator.create(model.Expr);
    lowered.* = .{ .construct_enum_variant = .{
        .enum_name = try ctx.allocator.dupe(u8, resolved_name),
        .variant_name = try ctx.allocator.dupe(u8, variant_decl.name),
        .discriminant = variant_decl.discriminant,
        .payload = payload,
        .ty = .{ .kind = .enum_instance, .name = try ctx.allocator.dupe(u8, resolved_name) },
        .span = enum_target.span,
    } };
    return lowered;
}

fn resolveEnumDecl(ctx: *shared.Context, name: []const u8) ?model.EnumDecl {
    // Imports are file-scoped: an enum from a dependency package is invisible unless the
    // current file imports that package's module.
    if (!ctx.enumSymbolVisible(name)) return null;
    if (ctx.concrete_enums) |concrete_enums| {
        if (concrete_enums.get(name)) |enum_decl| return enum_decl;
    }
    if (ctx.enum_headers) |headers| {
        if (headers.get(name)) |enum_decl| return enum_decl;
    }
    return null;
}

fn resolveEnumName(ctx: *shared.Context, candidate: []const u8, fallback: []const u8) []const u8 {
    if (candidate.len != 0) {
        if (resolveEnumDecl(ctx, candidate) != null) return candidate;
        const leaf = qualifiedLeaf(candidate);
        if (resolveEnumDecl(ctx, leaf) != null) return leaf;
    }
    return fallback;
}

fn findEnumVariant(enum_decl: model.EnumDecl, name: []const u8) ?model.EnumVariantHir {
    for (enum_decl.variants) |variant_decl| {
        if (std.mem.eql(u8, variant_decl.name, name)) return variant_decl;
    }
    return null;
}
