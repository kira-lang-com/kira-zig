const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const parser = @import("parser.zig");

test "parses imports functions and construct declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = try parser.parseSource(
        allocator,
        "import UI as Kit\n" ++
            "/// demo\n" ++
            "construct Widget { annotations { @State; } requires { function render() } lifecycle { onAppear() {} } }\n" ++
            "Widget Button(title: String) { @State let count: Int = 0; content { Text(title) } }\n" ++
            "@Main function entry(): Int { let x: Float = 12; print(x); return 0; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 1), program.imports.len);
    try std.testing.expectEqual(@as(usize, 3), program.decls.len);
    try std.testing.expectEqual(@as(usize, 1), program.functions.len);
}

test "reports removed declaration syntax diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = parser.parseSource(allocator, "type OldShape { let value: Int = 0 }", &diags);
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try std.testing.expectEqualStrings("removed type declaration syntax", diags.items[0].title);
    }
    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = parser.parseSource(allocator, "@Doc(\"old\")\nstruct Shape { let value: Int = 0 }", &diags);
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try std.testing.expectEqualStrings("removed @Doc annotation", diags.items[0].title);
    }
    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = parser.parseSource(allocator, "struct Shape { static let zero: Int = 0 }", &diags);
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try std.testing.expectEqualStrings("removed static keyword", diags.items[0].title);
    }
}

test "parses type aliases and async functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = try parser.parseSource(
        allocator,
        "type Byte = U8\n" ++
            "async function load() -> Byte { return 1 }\n",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 2), program.decls.len);
    try std.testing.expectEqualStrings("Byte", program.decls[0].type_alias_decl.name);
    try std.testing.expect(program.decls[1].function_decl.is_async);
}

test "parses annotation declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = try parser.parseSource(
        allocator,
        "annotation State { }\n" ++
            "annotation Attribute { parameters { index: Int } }\n" ++
            "annotation InputMapping { parameters { priority: Int = 0 blocksLowerPriorityMappings: Bool = false } }\n",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 3), program.decls.len);
    try std.testing.expectEqualStrings("State", program.decls[0].annotation_decl.name);
    try std.testing.expectEqual(@as(usize, 0), program.decls[0].annotation_decl.parameters.len);
    try std.testing.expectEqualStrings("Attribute", program.decls[1].annotation_decl.name);
    try std.testing.expectEqual(@as(usize, 1), program.decls[1].annotation_decl.parameters.len);
    try std.testing.expectEqualStrings("index", program.decls[1].annotation_decl.parameters[0].name);
    try std.testing.expectEqual(@as(usize, 2), program.decls[2].annotation_decl.parameters.len);
    try std.testing.expect(program.decls[2].annotation_decl.parameters[0].default_value != null);
    try std.testing.expect(program.decls[2].annotation_decl.parameters[1].default_value != null);
}
