const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");

// Content blocks accept widget-producing expressions. Primitive literals are rejected here so
// validation cannot confuse raw host values with real construct content.

pub fn validateBlock(ctx: *shared.Context, block: model.BuilderBlock, element_type: []const u8) anyerror!void {
    for (block.items) |item| {
        switch (item) {
            .expr => |expr_item| try validateValue(ctx, expr_item.expr, expr_item.span, element_type),
            .if_item => |if_item| {
                try validateBlock(ctx, if_item.then_block, element_type);
                if (if_item.else_block) |else_block| try validateBlock(ctx, else_block, element_type);
            },
            .for_item => |for_item| try validateBlock(ctx, for_item.body, element_type),
            .switch_item => |switch_item| {
                for (switch_item.cases) |case_node| try validateBlock(ctx, case_node.body, element_type);
                if (switch_item.default_block) |default_block| try validateBlock(ctx, default_block, element_type);
            },
        }
    }
}

fn validateValue(ctx: *shared.Context, expr: *model.Expr, span: source_pkg.Span, element_type: []const u8) anyerror!void {
    const found = model.exprType(expr.*);
    const found_label: ?[]const u8 = switch (found.kind) {
        .string, .c_string => "String",
        .integer => "Int",
        .float => "Float",
        .boolean => "Bool",
        else => null,
    };
    if (found_label) |label| {
        const text_hint = if (found.kind == .string or found.kind == .c_string)
            "; use Text(...) if visible text was intended"
        else
            "";
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM098",
            .title = "content value is not a widget",
            .message = try std.fmt.allocPrint(ctx.allocator, "Kira expected {s} content, found {s}{s}.", .{ element_type, label, text_hint }),
            .labels = &.{
                diagnostics.primaryLabel(span, "this value is not a widget"),
            },
            .help = "Content blocks accept widget-producing expressions, not raw values.",
        });
        return error.DiagnosticsEmitted;
    }
}
