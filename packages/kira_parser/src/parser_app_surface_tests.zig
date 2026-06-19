const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const syntax = @import("kira_syntax_model");
const parser = @import("parser.zig");

test "parses widget app surface call arguments body sections and For blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = try parser.parseSource(
        allocator,
        "Widget HeroCard(title: String, subtitle: String) {\n" ++
            "    body {\n" ++
            "        Text(title)\n" ++
            "            .font(size = 28.0, weight = FontWeight.Bold)\n" ++
            "            .opacity(0.72)\n" ++
            "    }\n" ++
            "}\n" ++
            "\n" ++
            "@Main function entry() {\n" ++
            "    UI.VStack(spacing = 18.0) {\n" ++
            "        Text(\"A\")\n" ++
            "        For(project in projects) {\n" ++
            "            ProjectRow(project = project)\n" ++
            "        }\n" ++
            "    }\n" ++
            "    return\n" ++
            "}\n",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const form_decl = program.decls[0].construct_form_decl;
    try std.testing.expectEqual(@as(usize, 2), form_decl.params.len);
    try std.testing.expect(form_decl.body.members[0] == .named_rule);
    try std.testing.expectEqualStrings("body", form_decl.body.members[0].named_rule.name.segments[0].text);

    const entry_expr = program.functions[0].body.?.statements[0].expr_stmt.expr;
    try std.testing.expect(entry_expr.* == .call);
    try std.testing.expectEqual(@as(usize, 1), entry_expr.call.args.len);
    try std.testing.expectEqualStrings("spacing", entry_expr.call.args[0].label.?);
    try std.testing.expect(entry_expr.call.trailing_builder != null);
    try std.testing.expectEqual(@as(usize, 2), entry_expr.call.trailing_builder.?.items.len);
    try std.testing.expect(entry_expr.call.trailing_builder.?.items[1] == .for_item);

    const for_item = entry_expr.call.trailing_builder.?.items[1].for_item;
    try std.testing.expectEqualStrings("project", for_item.binding_name);
    try std.testing.expectEqual(@as(usize, 1), for_item.body.items.len);
    try std.testing.expect(for_item.body.items[0] == .expr);
    try std.testing.expect(for_item.body.items[0].expr.expr.* == .call);
    try std.testing.expectEqualStrings("project", for_item.body.items[0].expr.expr.call.args[0].label.?);
}

test "parses equals labels without affecting struct literal colons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = try parser.parseSource(
        allocator,
        "struct Project { let name: String let count: Int }\n" ++
            "@Main function entry() {\n" ++
            "    let project = Project { name: \"Kira UI\", count: 3 }\n" ++
            "    HeroCard(title = project.name, subtitle = \"Ready\")\n" ++
            "    return\n" ++
            "}\n",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const project_init = program.functions[0].body.?.statements[0].let_stmt.value.?;
    try std.testing.expect(project_init.* == .struct_literal);
    try std.testing.expectEqual(@as(usize, 2), project_init.struct_literal.fields.len);

    const hero_call = program.functions[0].body.?.statements[1].expr_stmt.expr;
    try std.testing.expect(hero_call.* == .call);
    try std.testing.expectEqualStrings("title", hero_call.call.args[0].label.?);
    try std.testing.expectEqualStrings("subtitle", hero_call.call.args[1].label.?);
}

test "parses default parameter values on app-surface methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = try parser.parseSource(
        allocator,
        "extend Widget {\n" ++
            "    function font(size: Float, weight: FontWeight = FontWeight.Regular) -> Widget {\n" ++
            "        return self\n" ++
            "    }\n" ++
            "}\n" ++
            "@Main function entry() { return }\n",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const font_fn = program.decls[0].extend_decl.members[0].function_decl;
    try std.testing.expectEqual(@as(usize, 2), font_fn.params.len);
    try std.testing.expect(font_fn.params[1].default_value != null);
}
