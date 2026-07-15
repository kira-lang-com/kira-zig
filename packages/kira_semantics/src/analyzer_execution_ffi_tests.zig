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

test "preserves type execution annotations and class annotation flexibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "annotation Tagged { targets: class }\n" ++
            "@Native struct NativeValue {}\n" ++
            "@Runtime struct RuntimeValue {}\n" ++
            "@Tagged @Native class NativeBox {}\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    var saw_native = false;
    var saw_runtime = false;
    for (analyzed.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, "NativeValue")) {
            saw_native = true;
            try std.testing.expectEqual(model.FunctionExecution.native, type_decl.execution);
        }
        if (std.mem.eql(u8, type_decl.name, "RuntimeValue")) {
            saw_runtime = true;
            try std.testing.expectEqual(model.FunctionExecution.runtime, type_decl.execution);
        }
    }
    try std.testing.expect(saw_native);
    try std.testing.expect(saw_runtime);
}

test "rejects non execution struct annotations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "annotation Tagged { targets: struct }\n" ++
            "@Tagged struct Value {}\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try expectFirstDiagnosticTitle(diags.items, "invalid struct annotation");
}

test "requires @Native only for direct FFI use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const extern_decl =
        "@FFI.Extern { library: testlib; symbol: ffi_value; abi: c; }\n" ++
        "function ffi_value(): I64;\n";

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            extern_decl ++
                "@Main\n" ++
                "function entry() {\n" ++
                "    ffi_value();\n" ++
                "    return;\n" ++
                "}",
            &diags,
        );

        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "direct FFI requires @Native");
        try std.testing.expectEqualStrings("KSEM093", diags.items[0].code.?);
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        _ = try analyzeSource(
            allocator,
            extern_decl ++
                "@Main\n" ++
                "function entry() {\n" ++
                "    let value = wrapper();\n" ++
                "    print(value);\n" ++
                "    return;\n" ++
                "}\n" ++
                "\n" ++
                "@Native\n" ++
                "function nativeHelper(): I64 {\n" ++
                "    return ffi_value();\n" ++
                "}\n" ++
                "\n" ++
                "function wrapper(): I64 {\n" ++
                "    return nativeHelper();\n" ++
                "}",
            &diags,
        );

        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            extern_decl ++
                "@Main\n" ++
                "function entry() {\n" ++
                "    let callback: () -> I64 = ffi_value;\n" ++
                "    return;\n" ++
                "}",
            &diags,
        );

        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "direct FFI requires @Native");
    }
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

test "enforces declaration typing and initialization rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        _ = try analyzeSource(
            allocator,
            "@Main\nfunction entry() { var text: String; var value: Float = 12.0; value = 13.0; return; }",
            &diags,
        );
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "@Main\nfunction entry() { var value: Float = 12; return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try std.testing.expectEqualStrings("initializer does not match declared type", diags.items[0].title);
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "@Main\nfunction entry() { var value: String; print(value); return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try std.testing.expectEqualStrings("local is not initialized", diags.items[0].title);
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

test "rejects removed content-channel schema surface" {
    // Construct 2.0 (item 6): a construct that declares a named content channel
    // (`content { name { count 1.. } }`) is rejected — the channel surface is removed.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "annotation State { }\n" ++
            "construct Widget { annotations { @State; } content { content { count 1.. } } lifecycle { onAppear() {} } }\n" ++
            "Widget Button() { @State let count: Int = 0; }\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expectEqualStrings("content channels are removed", diags.items[0].title);
}

test "allows struct methods and constant members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "struct Point {\n" ++
            "    let x: Float = 0.0;\n" ++
            "    let y: Float = 0.0;\n" ++
            "    let zero: Point = Point(x: 0.0, y: 0.0);\n" ++
            "    function distanceTo(other: borrow Point) -> Float { return x + other.x; }\n" ++
            "}\n" ++
            "@Main function entry() { let start = Point.zero; let end = Point { x: 2.0, y: 3.0 }; print(end.distanceTo(other: start)); return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 2), analyzed.functions.len);
    try std.testing.expectEqualStrings("Point.distanceTo", analyzed.functions[0].name);
}

test "lowers sparse FFI struct construction as zero-filled construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "@FFI.Struct { layout: c; }\n" ++
            "struct Example {\n" ++
            "    var a: U8\n" ++
            "    var b: U8\n" ++
            "    var c: U8\n" ++
            "}\n" ++
            "@Main function entry() {\n" ++
            "    let first = Example();\n" ++
            "    let second = Example { b: 7 };\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const entry = analyzed.functions[0];
    try std.testing.expect(entry.body[0].let_stmt.value.?.* == .construct);
    try std.testing.expectEqual(model.ConstructFillMode.zeroed_ffi_c_layout, entry.body[0].let_stmt.value.?.construct.fill_mode);
    try std.testing.expectEqual(@as(usize, 0), entry.body[0].let_stmt.value.?.construct.fields.len);
    try std.testing.expect(entry.body[1].let_stmt.value.?.* == .construct);
    try std.testing.expectEqual(model.ConstructFillMode.zeroed_ffi_c_layout, entry.body[1].let_stmt.value.?.construct.fill_mode);
    try std.testing.expectEqual(@as(usize, 1), entry.body[1].let_stmt.value.?.construct.fields.len);
    try std.testing.expectEqual(@as(u32, 1), entry.body[1].let_stmt.value.?.construct.fields[0].field_index.?);
}

test "reports loop control outside loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "@Main function entry() { break; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "break requires a loop");
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "@Main function entry() { continue; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "continue requires a loop");
    }
}

