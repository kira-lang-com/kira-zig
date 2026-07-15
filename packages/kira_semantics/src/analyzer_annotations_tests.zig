const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const model = @import("kira_semantics_model");
const syntax = @import("kira_syntax_model");
const analyzer = @import("analyzer.zig");
const support = @import("analyzer_test_support.zig");
const analyzeSource = support.analyzeSource;
const parseSource = support.parseSource;
const expectFirstDiagnosticTitle = support.expectFirstDiagnosticTitle;
const findTypeDeclByName = support.findTypeDeclByName;
test "validates annotation declarations and fills defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "annotation State { }\n" ++
            "annotation Attribute { parameters { index: Int } }\n" ++
            "annotation InputMapping { parameters { priority: Int = 0 blocksLowerPriorityMappings: Bool = false } }\n" ++
            "construct Widget { annotations { @State; @Attribute; @InputMapping; } }\n" ++
            "Widget Button() {\n" ++
            "    @State let isPressed: Bool = false;\n" ++
            "    @Attribute(0) let position: Float = 0.0;\n" ++
            "    @InputMapping let mapping: Int = 1;\n" ++
            "    content { }\n" ++
            "}\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 3), analyzed.annotations.len);
    try std.testing.expectEqual(@as(usize, 1), analyzed.forms.len);
    try std.testing.expectEqual(@as(usize, 3), analyzed.forms[0].fields.len);
    try std.testing.expectEqual(@as(usize, 1), analyzed.forms[0].fields[1].annotations.len);
    try std.testing.expectEqual(@as(usize, 1), analyzed.forms[0].fields[1].annotations[0].arguments.len);
    try std.testing.expectEqual(@as(i64, 0), analyzed.forms[0].fields[1].annotations[0].arguments[0].value.integer);
    try std.testing.expectEqual(@as(usize, 2), analyzed.forms[0].fields[2].annotations[0].arguments.len);
    try std.testing.expectEqual(@as(i64, 0), analyzed.forms[0].fields[2].annotations[0].arguments[0].value.integer);
    try std.testing.expectEqual(false, analyzed.forms[0].fields[2].annotations[0].arguments[1].value.boolean);
}

test "reports annotation schema errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "annotation Attribute { parameters { index: Int } }\n" ++
                "construct Widget { annotations { @Attribute; } }\n" ++
                "Widget Button() { @Attribute let position: Float = 0.0; content { } }\n" ++
                "@Main function entry() { return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "missing annotation parameter");
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "annotation Attribute { parameters { index: Int } }\n" ++
                "construct Widget { annotations { @Attribute; } }\n" ++
                "Widget Button() { @Attribute(\"zero\") let position: Float = 0.0; content { } }\n" ++
                "@Main function entry() { return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "annotation parameter type mismatch");
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "annotation State { }\n" ++
                "construct Widget { annotations { @State; } }\n" ++
                "Widget Button() { @State(1) let isPressed: Bool = false; content { } }\n" ++
                "@Main function entry() { return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "annotation does not accept parameters");
    }
}

test "reports undeclared annotations in construct allowlists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "construct Widget { annotations { @State; } }\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try expectFirstDiagnosticTitle(diags.items, "unknown annotation");
}

test "reports duplicate annotation declarations and parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "annotation State { }\n" ++
                "annotation State { }\n" ++
                "@Main function entry() { return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "duplicate annotation declaration");
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "annotation Attribute { parameters { index: Int index: Int } }\n" ++
                "@Main function entry() { return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "duplicate annotation parameter");
    }
}

test "reports invalid annotation parameter defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "annotation Attribute { parameters { index: Int = \"zero\" } }\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try expectFirstDiagnosticTitle(diags.items, "annotation parameter type mismatch");
}

test "validates annotation targets capabilities and generated overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const analyzed = try analyzeSource(
            allocator,
            "capability Labeling { generated { overridable function label(): Int { return 1; } } }\n" ++
                "annotation Tagged { targets: class uses Labeling }\n" ++
                "@Tagged class Item { override function label(): Int { return 2; } }\n" ++
                "@Main function entry() { return; }",
            &diags,
        );
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
        try std.testing.expectEqual(@as(usize, 1), analyzed.capabilities.len);
        try std.testing.expectEqual(@as(usize, 1), analyzed.annotations[0].generated_functions.len);
    }
    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "annotation StructOnly { targets: struct }\n" ++
                "@StructOnly class Item {}\n" ++
                "@Main function entry() { return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "invalid annotation target");
    }
    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "annotation Tagged { targets: class generated { function label(): Int { return 1; } } }\n" ++
                "@Tagged class Item { override function label(): Int { return 2; } }\n" ++
                "@Main function entry() { return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "generated member is not overridable");
    }
    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "capability A { generated { function label(): Int { return 1; } } }\n" ++
                "capability B { generated { function label(): Int { return 2; } } }\n" ++
                "annotation Tagged { targets: class uses A, B }\n" ++
                "@Tagged class Item {}\n" ++
                "@Main function entry() { return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "duplicate generated member");
    }
}

