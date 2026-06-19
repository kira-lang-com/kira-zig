const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const shared = @import("lower_shared.zig");

pub fn effectiveMembers(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
) ![]const syntax.ast.BodyMember {
    var members = std.array_list.Managed(syntax.ast.BodyMember).init(ctx.allocator);
    for (form_decl.params) |param| {
        try members.append(.{ .field_decl = .{
            .annotations = &.{},
            .storage = .immutable,
            .name = param.name,
            .type_expr = param.type_expr,
            .value = null,
            .span = param.span,
        } });
    }

    const widget_surface = isWidgetSurface(ctx, form_decl);
    const has_explicit_body = widget_surface and hasExplicitMemberNamedBody(form_decl);
    const has_body_rule = widget_surface and findBodyRule(form_decl) != null;
    var hoisted_body_fields = std.array_list.Managed(syntax.ast.FieldDecl).init(ctx.allocator);
    var saw_body_section = false;
    for (form_decl.body.members) |member| {
        if (has_body_rule and member == .field_decl and canHoistFieldIntoBody(member.field_decl)) {
            try hoisted_body_fields.append(member.field_decl);
            continue;
        }
        if (widget_surface and member == .named_rule and isBodyRule(member.named_rule)) {
            const rule = member.named_rule;
            if (rule.block == null or rule.args.len != 0 or rule.type_expr != null or rule.value != null) {
                try emitInvalidBodySection(ctx, rule.span, "A widget body section is written as `body { ... }` with no arguments or assigned value.");
                return error.DiagnosticsEmitted;
            }
            if (saw_body_section or has_explicit_body) {
                try emitInvalidBodySection(ctx, rule.span, "The declaration already provides `body`; keep only one body definition.");
                return error.DiagnosticsEmitted;
            }
            saw_body_section = true;
            try members.append(.{ .field_decl = try syntheticBodyField(ctx, form_decl, rule, hoisted_body_fields.items) });
            continue;
        }
        try members.append(member);
    }

    return members.toOwnedSlice();
}

fn hasExplicitMemberNamedBody(form_decl: syntax.ast.ConstructFormDecl) bool {
    for (form_decl.body.members) |member| {
        switch (member) {
            .field_decl => |field| if (std.mem.eql(u8, field.name, "body")) return true,
            .function_decl => |function_decl| if (std.mem.eql(u8, function_decl.name, "body")) return true,
            else => {},
        }
    }
    return false;
}

fn isBodyRule(rule: syntax.ast.NamedRule) bool {
    return rule.name.segments.len == 1 and std.mem.eql(u8, rule.name.segments[0].text, "body");
}

fn isWidgetSurface(ctx: *shared.Context, form_decl: syntax.ast.ConstructFormDecl) bool {
    const families = ctx.form_families orelse return false;
    const form_families = families.get(form_decl.name) orelse return false;
    for (form_families) |family| {
        if (std.mem.eql(u8, family, "Widget")) return true;
    }
    return false;
}

fn findBodyRule(form_decl: syntax.ast.ConstructFormDecl) ?syntax.ast.NamedRule {
    for (form_decl.body.members) |member| {
        if (member != .named_rule) continue;
        if (isBodyRule(member.named_rule)) return member.named_rule;
    }
    return null;
}

fn canHoistFieldIntoBody(field: syntax.ast.FieldDecl) bool {
    if (field.annotations.len != 0) return false;
    if (field.body != null) return false;
    if (field.value == null) return false;
    return !std.mem.eql(u8, field.name, "body");
}

fn syntheticBodyField(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    rule: syntax.ast.NamedRule,
    hoisted_fields: []const syntax.ast.FieldDecl,
) !syntax.ast.FieldDecl {
    return .{
        .annotations = &.{},
        .storage = .immutable,
        .name = "body",
        .type_expr = try familyTypeExpr(ctx, form_decl, rule.span),
        .value = null,
        .body = if (rule.block) |body| try blockWithHoistedLocals(ctx, body, hoisted_fields) else null,
        .span = rule.span,
    };
}

fn blockWithHoistedLocals(
    ctx: *shared.Context,
    block: syntax.ast.Block,
    hoisted_fields: []const syntax.ast.FieldDecl,
) !syntax.ast.Block {
    if (hoisted_fields.len == 0) return block;
    var statements = std.array_list.Managed(syntax.ast.Statement).init(ctx.allocator);
    for (hoisted_fields) |field| {
        try statements.append(.{ .let_stmt = .{
            .annotations = &.{},
            .storage = field.storage,
            .name = field.name,
            .type_expr = field.type_expr,
            .value = field.value,
            .span = field.span,
        } });
    }
    try statements.appendSlice(block.statements);
    return .{
        .statements = try statements.toOwnedSlice(),
        .span = block.span,
    };
}

fn familyTypeExpr(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    span: source_pkg.Span,
) !*syntax.ast.TypeExpr {
    const family_name = blk: {
        if (ctx.form_families) |families| {
            if (families.get(form_decl.name)) |items| {
                if (items.len != 0) break :blk items[0];
            }
        }
        break :blk form_decl.construct_name.segments[form_decl.construct_name.segments.len - 1].text;
    };

    const segments = try ctx.allocator.alloc(syntax.ast.NameSegment, 1);
    segments[0] = .{ .text = family_name, .span = span };
    const type_expr = try ctx.allocator.create(syntax.ast.TypeExpr);
    type_expr.* = .{ .named = .{ .segments = segments, .span = span } };
    return type_expr;
}

fn emitInvalidBodySection(ctx: *shared.Context, span: source_pkg.Span, help: []const u8) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM154",
        .title = "invalid body section",
        .message = "This declaration's `body` section does not match the widget app surface.",
        .labels = &.{diagnostics.primaryLabel(span, "invalid body section")},
        .help = help,
    });
}
