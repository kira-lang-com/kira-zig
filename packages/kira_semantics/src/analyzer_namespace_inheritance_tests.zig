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
test "struct methods lower like value-oriented instance behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "struct Size { let width: I64 = 2 function doubled() -> I64 { return width * 2; } }\n" ++
            "@Main function entry() { let size = Size(); print(size.doubled()); return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqualStrings("Size.doubled", analyzed.functions[0].name);
}

test "allows imported construct and callable names in the global namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzer.analyzeWithImports(
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
    try std.testing.expectEqualStrings("Widget", analyzed.forms[0].construct.construct_name);
}

test "root declarations shadow dependency declarations without duplicate leakage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    var program = try parseSource(
        allocator,
        "struct Color { let r: Int = 0; }\n" ++
            "struct Color { let value: Int = 7; }\n" ++
            "@Main function entry() { let color = Color(); print(color.value); return; }",
        &diags,
    );
    const origins = try allocator.alloc(syntax.ast.DeclOrigin, program.decls.len);
    for (origins) |*origin| origin.* = .{};
    origins[0] = .{ .package_name = "KiraGraphics", .source_path = "KiraGraphics/Color.kira" };
    program.decl_origins = origins;

    const analyzed = try analyzer.analyze(allocator, program, &diags);

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const color = findTypeDeclByName(analyzed, "Color") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), color.fields.len);
    try std.testing.expectEqualStrings("value", color.fields[0].name);
}

test "duplicate declarations still fail within one dependency namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    var program = try parseSource(
        allocator,
        "struct Color { let r: Int = 0; }\n" ++
            "struct Color { let g: Int = 0; }\n" ++
            "@Main function entry() { return; }",
        &diags,
    );
    const origins = try allocator.alloc(syntax.ast.DeclOrigin, program.decls.len);
    for (origins) |*origin| origin.* = .{ .package_name = "KiraGraphics", .source_path = "KiraGraphics/Color.kira" };
    origins[2] = .{};
    program.decl_origins = origins;

    const result = analyzer.analyze(allocator, program, &diags);

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try expectFirstDiagnosticTitle(diags.items, "duplicate top-level name");
}

test "lowers any construct parameters as structured construct constraints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "construct Widget {}\n" ++
            "@Runtime function accept(value: any Widget) { return; }\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(model.Type.construct_any, analyzed.functions[0].params[0].ty.kind);
    try std.testing.expectEqualStrings("any Widget", analyzed.functions[0].params[0].ty.name.?);
    try std.testing.expectEqualStrings("Widget", analyzed.functions[0].params[0].ty.construct_constraint.?.construct_name);
}

test "class methods can read fields through implicit self" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "class Counter { let value: Int = 1; function current(): Int { return value; } }\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 2), analyzed.functions.len);
}

test "class methods can call sibling methods through implicit self" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "class Counter { let value: Int = 1; function current(): Int { return value; } function mirror(): Int { return current(); } }\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 3), analyzed.functions.len);
}

test "reports inheritance cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "class Left extends Right {}\n" ++
            "class Right extends Left {}\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try expectFirstDiagnosticTitle(diags.items, "inheritance cycle");
}

test "reports duplicate direct parents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "class Base {}\n" ++
            "class Child extends Base, Base {}\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try expectFirstDiagnosticTitle(diags.items, "duplicate parent type");
}

test "reports ambiguous inherited field lookups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "class Left { let value: I64 = 1 }\n" ++
            "class Right { let value: I64 = 2 }\n" ++
            "class Child extends Left, Right {\n" ++
            "    function read(): I64 { return value; }\n" ++
            "}\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try expectFirstDiagnosticTitle(diags.items, "ambiguous inherited field lookup");
}

test "reports ambiguous inherited method lookups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "class Left { function ping(): I64 { return 1; } }\n" ++
            "class Right { function ping(): I64 { return 2; } }\n" ++
            "class Child extends Left, Right {\n" ++
            "    function read(): I64 { return ping(); }\n" ++
            "}\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try expectFirstDiagnosticTitle(diags.items, "ambiguous inherited method lookup");
}

test "allows type-qualified constant member lookup outside inheritance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "class Left { let value: I64 = 1 }\n" ++
            "class Right { let value: I64 = 2 }\n" ++
            "class Child extends Left {\n" ++
            "    function read(): I64 { return Right.value; }\n" ++
            "}\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 2), analyzed.functions.len);
}


// Unit coverage for the file-scoped import visibility helpers on the lowering
// Context (imports are per-file, not package-wide). Exercises the subtle bits:
// same-package access, per-file import sets, generic-enum base gating, the
// package-scoped qualified key, and the synthetic (empty-path) escape hatch.
test "file-scoped import visibility helpers gate dependency symbols per file" {
    const shared = @import("lower_shared.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);

    var owners = std.StringHashMapUnmanaged([]const u8){};
    try owners.put(allocator, "printLine", "Foundation");
    try owners.put(allocator, "Result", "Foundation");
    try owners.put(allocator, "TestRuntime", "Foundation");

    var file_imports = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)){};
    var importer_set = std.StringHashMapUnmanaged(void){};
    try importer_set.put(allocator, "Foundation", {});
    try file_imports.put(allocator, "/pkg/app/importer.kira", importer_set);
    try file_imports.put(allocator, "/pkg/app/sibling.kira", .{});

    var ctx = shared.Context{
        .allocator = allocator,
        .diagnostics = &diags,
        .imported_symbol_owner = &owners,
        .file_module_imports = &file_imports,
    };

    // A file that imports Foundation sees Foundation's symbols.
    ctx.current_source_path = "/pkg/app/importer.kira";
    try std.testing.expect(ctx.importedSymbolVisible("printLine"));
    try std.testing.expect(ctx.moduleVisible("Foundation"));
    try std.testing.expect(ctx.enumSymbolVisible("Result__Int__TestFailure"));
    try std.testing.expect(ctx.qualifiedSymbolVisible("Foundation.printLine"));
    try std.testing.expect(ctx.qualifiedSymbolVisible("TestRuntime.report"));
    try std.testing.expect(ctx.missingImportForSymbol("printLine") == null);

    // A sibling that does NOT import Foundation cannot see them; the generic
    // enum instance is gated through its base enum, and the qualified key too.
    ctx.current_source_path = "/pkg/app/sibling.kira";
    try std.testing.expect(!ctx.importedSymbolVisible("printLine"));
    try std.testing.expect(!ctx.enumSymbolVisible("Result__Int__TestFailure"));
    try std.testing.expect(!ctx.qualifiedSymbolVisible("Foundation.printLine"));
    try std.testing.expectEqualStrings("Foundation", ctx.missingImportForSymbol("printLine").?);

    // A dependency TYPE's member key (`Type.method`) is gated through the type's owner.
    try std.testing.expect(!ctx.qualifiedSymbolVisible("TestRuntime.report"));
    // A dotted key whose root and member are both non-dependency names is never gated.
    try std.testing.expect(ctx.qualifiedSymbolVisible("SomeType.method"));
    // A root/local/builtin name (absent from the owner map) is always visible.
    try std.testing.expect(ctx.importedSymbolVisible("someLocalHelper"));

    // A file in Foundation itself sees its own package's symbols without importing.
    ctx.current_package = "Foundation";
    ctx.current_source_path = "/foundation/app/Test.kira";
    try std.testing.expect(ctx.importedSymbolVisible("Result"));

    // Compiler-generated / synthetic code (empty source path) is never gated.
    ctx.current_package = null;
    ctx.current_source_path = "";
    try std.testing.expect(ctx.importedSymbolVisible("printLine"));
    try std.testing.expect(ctx.enumSymbolVisible("Result__Int__TestFailure"));
}
