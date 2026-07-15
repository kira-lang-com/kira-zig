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
test "supports function types trailing callbacks and callable values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "function sink(value: Int) { print(value); return; }\n" ++
            "function register(handler: (Int) -> Void) { return; }\n" ++
            "@Main function entry() {\n" ++
            "    let callback: (Int) -> Void = sink;\n" ++
            "    register { value in sink(value); }\n" ++
            "    callback(1);\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const entry = analyzed.functions[2];
    try std.testing.expect(entry.body[0].let_stmt.value.?.* == .function_ref);
    try std.testing.expect(entry.body[1].expr_stmt.expr.* == .call);
    try std.testing.expect(entry.body[1].expr_stmt.expr.call.args[0].* == .callback);
    try std.testing.expect(entry.body[2].expr_stmt.expr.* == .call_value);
}

test "callable values preserve borrow mut parameter ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "struct Counter { var value: Int }\n" ++
            "function mutate(counter: borrow mut Counter) { counter.value = counter.value + 1; return; }\n" ++
            "@Main function entry() {\n" ++
            "    let callback: (borrow mut Counter) -> Void = mutate;\n" ++
            "    var counter = Counter { value: 0 };\n" ++
            "    callback(counter);\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const entry = analyzed.functions[analyzed.functions.len - 1];
    try std.testing.expect(entry.body[2].expr_stmt.expr.* == .call_value);
}

test "supports native callback state handles and recovered access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "struct CounterState { var count: Int }\n" ++
            "@Native function onTick(data: RawPtr) { var state = nativeRecover<CounterState>(data); state.count = state.count + 1; return; }\n" ++
            "@Main function entry() { var state = nativeState(CounterState { count: 0 }); var token = nativeUserData(state); var recovered = nativeRecover<CounterState>(token); recovered.count = recovered.count + 1; return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    const callback_recover = analyzed.functions[0].body[0].let_stmt.value.?.native_recover;
    try std.testing.expectEqual(model.Type.native_state_view, callback_recover.ty.kind);
    try std.testing.expectEqualStrings("CounterState", callback_recover.ty.name.?);

    const entry = analyzed.functions[1];
    try std.testing.expectEqual(model.Type.native_state, entry.body[0].let_stmt.ty.kind);
    try std.testing.expect(entry.body[1].let_stmt.value.?.* == .native_user_data);
    try std.testing.expectEqual(model.Type.native_state_view, entry.body[2].let_stmt.ty.kind);
    try std.testing.expect(entry.body[2].let_stmt.value.?.* == .native_recover);
}

test "rejects native callback state misuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "struct CounterState { var count: Int }\n" ++
                "@Main function entry() { var value = CounterState { count: 0 }; var token = nativeUserData(value); return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "nativeUserData requires native state");
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "struct CounterState { var count: Int }\n" ++
                "@Main function entry() { var state = nativeRecover<CounterState>(0); return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "nativeRecover requires RawPtr");
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "struct LeftState { var count: Int }\n" ++
                "struct RightState { var total: Int }\n" ++
                "@Main function entry() { var state = nativeState(LeftState { count: 0 }); var value = nativeRecover<RightState>(nativeUserData(state)); return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "native state type mismatch");
    }

    {
        var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        const result = analyzeSource(
            allocator,
            "@FFI.Struct { layout: c; }\n" ++
                "struct CState { var count: Int }\n" ++
                "@Main function entry() { var state = nativeState(CState { count: 0 }); return; }",
            &diags,
        );
        try std.testing.expectError(error.DiagnosticsEmitted, result);
        try expectFirstDiagnosticTitle(diags.items, "native state requires a Kira-owned type");
    }
}

test "allows indirect FFI usage through native functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    _ = try analyzeSource(
        allocator,
        "@FFI.Extern { library: testlib; symbol: ffi_value; abi: c; }\n" ++
            "function ffi_value(): I64;\n" ++
            "@Native function readViaNative(): I64 { return ffi_value(); }\n" ++
            "@Main function entry() { readViaNative(); return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "preserves trailing builder trees on call expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzer.analyzeWithImports(
        allocator,
        try parseSource(
            allocator,
            "import UI\n" ++
                "Widget Screen() {\n" ++
                "    content {\n" ++
                "        Column(\"root\") {\n" ++
                "            Text(\"hello\")\n" ++
                "        }\n" ++
                "    }\n" ++
                "}\n" ++
                "@Main function entry() { return; }",
            &diags,
        ),
        .{
            .constructs = &.{"Widget"},
            .callables = &.{ "Column", "Text" },
        },
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const content = analyzed.forms[0].content orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), content.items.len);
    try std.testing.expect(content.items[0] == .expr);
    try std.testing.expect(content.items[0].expr.expr.* == .call);
    try std.testing.expectEqual(@as(usize, 1), content.items[0].expr.expr.call.args.len);
    try std.testing.expect(content.items[0].expr.expr.call.trailing_builder != null);
    try std.testing.expectEqual(@as(usize, 1), content.items[0].expr.expr.call.trailing_builder.?.items.len);
}

test "reports override signature mismatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "class Base { function ping(value: I64): I64 { return value; } }\n" ++
            "class Child extends Base {\n" ++
            "    override function ping(): I64 { return 1; }\n" ++
            "}\n" ++
            "@Main function entry() { return; }",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try expectFirstDiagnosticTitle(diags.items, "override signature mismatch");
}

test "field default overrides reuse the inherited slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "class Base { let value: I64 = 1 }\n" ++
            "class Child extends Base {\n" ++
            "    override let value = 2;\n" ++
            "}\n" ++
            "@Main function entry() { let child: Child = Child(); return; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const child = findTypeDeclByName(analyzed, "Child") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), child.fields.len);
    try std.testing.expectEqual(@as(u32, 0), child.fields[0].slot_index);
    try std.testing.expect(child.fields[0].default_value != null);
    try std.testing.expectEqualStrings("value", child.fields[0].name);
    try std.testing.expect(child.fields[0].default_value.?.* == .integer);
    try std.testing.expectEqual(@as(i64, 2), child.fields[0].default_value.?.integer.value);
}

test "array count lowers as a dedicated expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "struct Item { let value: I64 = 1 }\n" ++
            "@Main function entry() {\n" ++
            "    let items = [Item()]\n" ++
            "    let count = items.count\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const count_stmt = analyzed.functions[analyzed.entry_index].body[1].let_stmt;
    try std.testing.expect(count_stmt.value != null);
    try std.testing.expect(count_stmt.value.?.* == .array_len);
    try std.testing.expectEqual(model.Type.integer, count_stmt.value.?.array_len.ty.kind);
}

test "string count lowers as a dedicated expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const analyzed = try analyzeSource(
        allocator,
        "@Main function entry() {\n" ++
            "    let title = \"KIRA\"\n" ++
            "    let count = title.count\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    const count_stmt = analyzed.functions[analyzed.entry_index].body[1].let_stmt;
    try std.testing.expect(count_stmt.value != null);
    try std.testing.expect(count_stmt.value.?.* == .string_len);
    try std.testing.expectEqual(model.Type.integer, count_stmt.value.?.string_len.ty.kind);
}

