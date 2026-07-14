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

// A dependency package whose manifest name (owner) differs from the module root a file
// writes: `Package UILibrary { moduleRoot "UI" }`. The importer writes `import UI`, but the
// owner index keys UILibrary's symbols by "UILibrary". The graph builder records the owner on
// the import origin (`module_owner_package`), so `import UI` must grant visibility to symbols
// owned by UILibrary — and a missing-import hint must name the importable root "UI", never
// the owner "UILibrary". `import_source_path` places the `import UI` statement in a file.
fn buildSplitModulePaletteProgram(
    allocator: std.mem.Allocator,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
    import_source_path: []const u8,
) !syntax.ast.Program {
    var program = try parseSource(
        allocator,
        "import UI\n" ++
            "struct Palette { let value: Int = 7; }\n" ++
            "@Main function entry() { let p = Palette(); print(p.value); return; }",
        diags,
    );
    // decls: [0] dependency `struct Palette` owned by UILibrary, [1] the root `@Main` file.
    const decl_origins = try allocator.alloc(syntax.ast.DeclOrigin, program.decls.len);
    for (decl_origins) |*origin| origin.* = .{ .source_path = "app/main.kira" };
    decl_origins[0] = .{ .package_name = "UILibrary", .source_path = "uilib/UI.kira" };
    program.decl_origins = decl_origins;

    // The module root written is "UI" but the owning package is "UILibrary".
    const import_origins = try allocator.alloc(syntax.ast.DeclOrigin, program.imports.len);
    for (import_origins) |*origin| origin.* = .{
        .source_path = import_source_path,
        .module_owner_package = "UILibrary",
    };
    program.import_origins = import_origins;
    return program;
}

test "import of a module root grants visibility to its owning package's symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `import UI` in the referencing file records the owner "UILibrary" too, so the
    // dependency `Palette` (owned by UILibrary) resolves.
    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const program = try buildSplitModulePaletteProgram(allocator, &diags, "app/main.kira");
        const analyzed = try analyzer.analyze(allocator, program, &diags);
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
        try std.testing.expect(findTypeDeclByName(analyzed, "Palette") != null);
    }

    // When only a SIBLING file imports UI, the gate rejects `Palette` in main.kira — and the
    // hint must name the importable module root ("import UI"), never the owner package name
    // ("import UILibrary" would not resolve).
    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const program = try buildSplitModulePaletteProgram(allocator, &diags, "app/other.kira");
        try std.testing.expectError(error.DiagnosticsEmitted, analyzer.analyze(allocator, program, &diags));
        try std.testing.expect(diags.items.len > 0);
        var hints_module_root = false;
        for (diags.items) |item| {
            if (item.help) |help| {
                try std.testing.expect(std.mem.indexOf(u8, help, "UILibrary") == null);
                if (std.mem.indexOf(u8, help, "import UI") != null) hints_module_root = true;
            }
            try std.testing.expect(std.mem.indexOf(u8, item.message, "UILibrary") == null);
        }
        try std.testing.expect(hints_module_root);
    }
}

// Type ANNOTATIONS are gated by the declaring file's imports too: a sibling file must not
// use a dependency type in a parameter/return/field position without importing its module.
fn buildSignatureVisibilityProgram(
    allocator: std.mem.Allocator,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
    sibling_imports_foundation: bool,
) !syntax.ast.Program {
    var program = try parseSource(
        allocator,
        "import Foundation\n" ++
            "struct TestResult { let ok: Bool = true; }\n" ++
            "function usesIt(x: TestResult) { return; }\n" ++
            "struct Holder { let r: TestResult; }\n" ++
            "@Main function entry() { return; }",
        diags,
    );
    // decls: [0] dependency `struct TestResult` owned by Foundation; [1] `usesIt` and
    // [2] `Holder` live in the sibling file; [3] entry lives in the importing file.
    const decl_origins = try allocator.alloc(syntax.ast.DeclOrigin, program.decls.len);
    decl_origins[0] = .{ .package_name = "Foundation", .source_path = "foundation/app/Test.kira" };
    decl_origins[1] = .{ .source_path = "app/sibling.kira" };
    decl_origins[2] = .{ .source_path = "app/sibling.kira" };
    decl_origins[3] = .{ .source_path = "app/main.kira" };
    program.decl_origins = decl_origins;

    const import_origins = try allocator.alloc(syntax.ast.DeclOrigin, program.imports.len);
    for (import_origins) |*origin| origin.* = .{
        .source_path = if (sibling_imports_foundation) "app/sibling.kira" else "app/main.kira",
    };
    program.import_origins = import_origins;
    return program;
}

test "signature types using a dependency type require the declaring file's import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The declaring file imports Foundation: parameter and field types resolve cleanly.
    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const program = try buildSignatureVisibilityProgram(allocator, &diags, true);
        _ = try analyzer.analyze(allocator, program, &diags);
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    }

    // Only ANOTHER file imports Foundation: the sibling's `x: TestResult` / `let r: TestResult`
    // annotations are rejected with an import hint naming Foundation.
    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const program = try buildSignatureVisibilityProgram(allocator, &diags, false);
        try std.testing.expectError(error.DiagnosticsEmitted, analyzer.analyze(allocator, program, &diags));
        try expectFirstDiagnosticTitle(diags.items, "type is not visible in this file");
        try std.testing.expect(std.mem.indexOf(u8, diags.items[0].help.?, "import Foundation") != null);
    }
}

test "import alias colliding with a local declaration reports a duplicate name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);

    // `import Foundation as Foo` next to a local `struct Foo` names the same top-level symbol
    // twice; the alias would otherwise shadow or misresolve the local decl, so it is rejected.
    const result = analyzeSource(
        allocator,
        "import Foundation as Foo\n" ++
            "struct Foo { let value: Int = 1; }\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try expectFirstDiagnosticTitle(diags.items, "duplicate top-level name");
}

test "same import alias in different files with no local collision is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);

    // Imports are file-scoped, so two sibling files may bind the same alias without conflict;
    // only a repeat within one file (or a clash with a local decl) is a duplicate.
    var program = try parseSource(
        allocator,
        "import Bar as Shared\n" ++
            "import Baz as Shared\n" ++
            "@Main function entry() { return; }",
        &diags,
    );
    const import_origins = try allocator.alloc(syntax.ast.DeclOrigin, program.imports.len);
    import_origins[0] = .{ .source_path = "app/a.kira" };
    import_origins[1] = .{ .source_path = "app/b.kira" };
    program.import_origins = import_origins;

    _ = try analyzer.analyze(allocator, program, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}
