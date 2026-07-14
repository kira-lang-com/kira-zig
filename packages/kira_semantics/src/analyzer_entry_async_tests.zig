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

test "async function lowers with is_async metadata preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = try analyzeSource(
        allocator,
        "async function work() -> Int {\n" ++
            "    return 41\n" ++
            "}\n" ++
            "@Main function entry() {\n" ++
            "    print(work());\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );

    // Suspend-free spine: the `async function` runs like a synchronous function
    // but keeps its `is_async` intent so later executor/reactor phases can find it.
    var found_async = false;
    for (program.functions) |func| {
        if (std.mem.eql(u8, func.name, "work")) {
            try std.testing.expect(func.is_async);
            found_async = true;
        }
    }
    try std.testing.expect(found_async);
}

test "Task spawn and await lower to deferred task nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    // `Task { <literal> }` lowers to a ready task and `handle.await` to a join
    // point; both must lower cleanly.
    _ = try analyzeSource(
        allocator,
        "@Main function entry() {\n" ++
            "    let handle = Task { 41 }\n" ++
            "    let joined = handle.await\n" ++
            "    print(joined)\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );
}

test "Task body that is not a call or literal is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    // The restricted slice defers direct calls and wraps pure literals; an
    // arbitrary expression body is rejected with KSEM159.
    const result = analyzeSource(
        allocator,
        "@Main function entry() {\n" ++
            "    let x = 1\n" ++
            "    let handle = Task { x + 1 }\n" ++
            "    print(handle.await)\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expect(diags.items.len > 0);
    try std.testing.expectEqualStrings("unsupported task body", diags.items[0].title);
}

test "await on a non-task value is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "@Main function entry() {\n" ++
            "    let value = 1\n" ++
            "    let joined = value.await\n" ++
            "    print(joined)\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expect(diags.items.len > 0);
    try std.testing.expectEqualStrings("task operation requires a task handle", diags.items[0].title);
}

test "task handle used as a plain value is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    // The handle is opaque: arithmetic on it must fail with KSEM158 so no code
    // can depend on its transparent runtime representation.
    const result = analyzeSource(
        allocator,
        "@Main function entry() {\n" ++
            "    let handle = Task { 41 }\n" ++
            "    print(handle + 1)\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expect(diags.items.len > 0);
    try std.testing.expectEqualStrings("task handle can only be awaited, cancelled, or detached", diags.items[0].title);
}

test "task handle passed as an argument is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = analyzeSource(
        allocator,
        "function consume(value: Int) -> Int { return value }\n" ++
            "@Main function entry() {\n" ++
            "    let handle = Task { 41 }\n" ++
            "    print(consume(handle))\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expect(diags.items.len > 0);
    try std.testing.expectEqualStrings("task handle can only be awaited, cancelled, or detached", diags.items[0].title);
}

test "task handle requestCancel and detach lower to task operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    _ = try analyzeSource(
        allocator,
        "@Main function entry() {\n" ++
            "    let handle = Task { 1 }\n" ++
            "    handle.requestCancel()\n" ++
            "    handle.detach()\n" ++
            "    return;\n" ++
            "}",
        &diags,
    );
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

