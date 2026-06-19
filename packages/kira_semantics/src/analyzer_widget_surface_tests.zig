const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const model = @import("kira_semantics_model");
const analyzer = @import("analyzer.zig");

fn analyzeSource(
    allocator: std.mem.Allocator,
    text: []const u8,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !model.Program {
    const lexer = @import("kira_lexer");
    const parser = @import("kira_parser");
    const source_pkg = @import("kira_source");

    const source = try source_pkg.SourceFile.initOwned(allocator, "test.kira", text);
    const tokens = try lexer.tokenize(allocator, &source, diags);
    const program = try parser.parse(allocator, tokens, diags);
    return analyzer.analyze(allocator, program, diags);
}

test "header params and body sections synthesize widget fields and accessors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "struct FoundationUiContext {}\n" ++
            "struct FoundationView { let label: String = \"\" }\n" ++
            "\n" ++
            "construct Widget {\n" ++
            "    @Required let body: Widget\n" ++
            "    function lower(context: borrow FoundationUiContext) -> FoundationView {\n" ++
            "        return body.lower(context)\n" ++
            "    }\n" ++
            "}\n" ++
            "\n" ++
            "Widget Text(text: String) {\n" ++
            "    function lower(context: borrow FoundationUiContext) -> FoundationView {\n" ++
            "        return FoundationView { label: text }\n" ++
            "    }\n" ++
            "}\n" ++
            "\n" ++
            "Widget Button(title: String) {\n" ++
            "    body {\n" ++
            "        Text(title)\n" ++
            "    }\n" ++
            "}\n" ++
            "\n" ++
            "@Main function entry() {\n" ++
            "    let root = Button(title = \"Hello\")\n" ++
            "    return\n" ++
            "}\n",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    const button = findTypeDeclByName(analyzed, "Button") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), button.fields.len);
    try std.testing.expectEqualStrings("title", button.fields[0].name);

    try std.testing.expect(findFunctionByName(analyzed, "Button.body") != null);
    try std.testing.expect(findFunctionByName(analyzed, "Button.lower") != null);

    const root_init = analyzed.functions[analyzed.entry_index].body[0].let_stmt.value.?.construct;
    try std.testing.expectEqual(@as(usize, 1), root_init.fields.len);
    try std.testing.expectEqualStrings("title", root_init.fields[0].field_name.?);
}

test "constructors win over same-name imported functions for app-surface calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const lexer = @import("kira_lexer");
    const parser = @import("kira_parser");
    const source_pkg = @import("kira_source");

    const source = try source_pkg.SourceFile.initOwned(
        allocator,
        "test.kira",
        "import UI\n" ++
            "@Main function entry() {\n" ++
            "    Text(\"hello\")\n" ++
            "    UI.Text(\"world\")\n" ++
            "    return\n" ++
            "}\n",
    );
    const tokens = try lexer.tokenize(allocator, &source, &diags);
    const program = try parser.parse(allocator, tokens, &diags);
    const analyzed = try analyzer.analyzeWithImports(
        allocator,
        program,
        .{
            .constructs = &.{"Widget"},
            .functions = &.{
                .{ .name = "Text", .params = &.{.{ .kind = .string }}, .return_type = .{ .kind = .string } },
            },
            .types = &.{
                .{
                    .name = "Text",
                    .fields = &.{
                        .{ .name = "text", .storage = .immutable, .ty = .{ .kind = .string } },
                    },
                },
            },
        },
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const entry = analyzed.functions[analyzed.entry_index];
    try std.testing.expect(entry.body[0].expr_stmt.expr.* == .construct);
    try std.testing.expect(entry.body[1].expr_stmt.expr.* == .construct);
}

fn findTypeDeclByName(program: model.Program, name: []const u8) ?model.TypeDecl {
    for (program.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
    }
    return null;
}

fn findFunctionByName(program: model.Program, name: []const u8) ?model.Function {
    for (program.functions) |function_decl| {
        if (std.mem.eql(u8, function_decl.name, name)) return function_decl;
    }
    return null;
}
