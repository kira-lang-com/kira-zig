const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const model = @import("kira_semantics_model");
const syntax = @import("kira_syntax_model");
pub const ImportedGlobals = @import("imported_globals.zig").ImportedGlobals;
const lowering = @import("lower_to_hir.zig");

pub fn analyze(allocator: std.mem.Allocator, program: syntax.ast.Program, out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic)) !model.Program {
    return analyzeWithImports(allocator, program, .{}, out_diagnostics);
}

pub fn analyzeWithImports(
    allocator: std.mem.Allocator,
    program: syntax.ast.Program,
    imported_globals: ImportedGlobals,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !model.Program {
    return lowering.lowerProgram(allocator, program, imported_globals, out_diagnostics);
}

fn analyzeSource(allocator: std.mem.Allocator, text: []const u8, diags: *std.array_list.Managed(diagnostics.Diagnostic)) !model.Program {
    const lexer = @import("kira_lexer");
    const parser = @import("kira_parser");
    const source_pkg = @import("kira_source");

    const source = try source_pkg.SourceFile.initOwned(allocator, "test.kira", text);
    const tokens = try lexer.tokenize(allocator, &source, diags);
    const program = try parser.parse(allocator, tokens, diags);
    return analyze(allocator, program, diags);
}

test "reports missing @Main entrypoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(allocator, "function helper() { return; }", &diags);

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expect(diags.items.len > 0);
    try std.testing.expectEqualStrings("missing @Main entrypoint", diags.items[0].title);
}

test "reports multiple @Main entrypoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "@Main\nfunction first() { return; }\n@Main\nfunction second() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expect(diags.items.len > 0);
    try std.testing.expectEqualStrings("multiple @Main entrypoints", diags.items[0].title);
}

test "preserves explicit @Native and @Runtime execution semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "@Main\n" ++
            "@Native\n" ++
            "function entry() { helper(); return; }\n" ++
            "@Runtime\n" ++
            "function helper() { return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 2), analyzed.functions.len);
    try std.testing.expectEqual(model.FunctionExecution.native, analyzed.functions[0].execution);
    try std.testing.expectEqual(model.FunctionExecution.runtime, analyzed.functions[1].execution);
}

test "reports conflicting execution annotations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "@Main\n@Native\n@Runtime\nfunction entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("conflicting execution annotations", diags.items[0].title);
}

test "requires explicit parameter types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "@Main\nfunction entry(value) { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expectEqualStrings("parameter type is required", diags.items[0].title);
}

test "allows explicit literal coercion but rejects ambiguous inference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        _ = try analyzeSource(
            allocator,
            "@Main\nfunction entry() { let value: Float = 12; return; }",
            &diags,
        );
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "@Main\nfunction entry(): Float { let value = 12; return value; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try std.testing.expectEqualStrings("type mismatch", diags.items[0].title);
    }
}

test "validates construct-driven requirements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "construct Widget { annotations { @State; } requires { content; } lifecycle { onAppear() {} } }\n" ++
            "Widget Button() { @State let count: Int = 0; }\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expectEqualStrings("missing required content block", diags.items[0].title);
}

test "allows imported construct and callable names in the global namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeWithImports(
        allocator,
        try parseSource(
            allocator,
            "import UI\n" ++
                "Widget DashboardShell() {\n" ++
                "    content {\n" ++
                "        Card(\"Operations\")\n" ++
                "    }\n" ++
                "    onAppear() { return; }\n" ++
                "}\n" ++
                "@Main function entry() { return; }",
            &diags,
        ),
        .{
            .constructs = &.{"Widget"},
            .callables = &.{"Card"},
        },
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 1), analyzed.forms.len);
    try std.testing.expectEqualStrings("Widget", analyzed.forms[0].construct_name);
}

fn parseSource(
    allocator: std.mem.Allocator,
    text: []const u8,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !syntax.ast.Program {
    const lexer = @import("kira_lexer");
    const parser = @import("kira_parser");
    const source_pkg = @import("kira_source");

    const source = try source_pkg.SourceFile.initOwned(allocator, "test.kira", text);
    const tokens = try lexer.tokenize(allocator, &source, diags);
    return parser.parse(allocator, tokens, diags);
}
