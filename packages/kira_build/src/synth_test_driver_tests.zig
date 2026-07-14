//! Unit tests for pure-Kira test-driver synthesis, focused on the structural
//! equality path (synth_test_driver_eq.zig). Each test parses a small program,
//! runs `injectTestDriver`, and inspects the resulting AST for the synthesized
//! comparator functions and the driver's dispatch.

const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const parser = @import("kira_parser");
const syntax = @import("kira_syntax_model");
const synth = @import("synth_test_driver.zig");

fn parse(allocator: std.mem.Allocator, text: []const u8) !syntax.ast.Program {
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = try parser.parseSource(allocator, text, &diags);
    try std.testing.expect(!diagnostics.hasErrors(diags.items));
    return program;
}

fn hasFunction(program: syntax.ast.Program, name: []const u8) bool {
    for (program.functions) |fd| {
        if (std.mem.eql(u8, fd.name, name)) return true;
    }
    return false;
}

test "struct-returning Test synthesizes a recursive comparator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const program = try parse(allocator,
        \\struct Pt { var x: Int var y: Int }
        \\Test TEq {
        \\    test { return Pt { x: 1, y: 2 } }
        \\    expect { let e: Result<Pt, TestFailure> = Result.Ok(Pt { x: 1, y: 2 }); return e }
        \\}
    );

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const out = try synth.injectTestDriver(allocator, program, &diags);
    try std.testing.expect(!diagnostics.hasErrors(diags.items));
    try std.testing.expect(hasFunction(out, synth.driver_function_name));
    try std.testing.expect(hasFunction(out, "__kira_test_eq_Pt"));
}

test "scalar-returning Test does not synthesize a comparator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const program = try parse(allocator,
        \\Test TInt {
        \\    test { return 7 }
        \\    expect { let e: Result<Int, TestFailure> = Result.Ok(7); return e }
        \\}
    );

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const out = try synth.injectTestDriver(allocator, program, &diags);
    try std.testing.expect(!diagnostics.hasErrors(diags.items));
    try std.testing.expect(hasFunction(out, synth.driver_function_name));
    try std.testing.expect(!hasFunction(out, "__kira_test_eq_Int"));
}

test "nested struct field pulls in the nested comparator transitively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const program = try parse(allocator,
        \\struct Pt { var x: Int var y: Int }
        \\struct Seg { var from: Pt var to: Pt }
        \\Test TSeg {
        \\    test { return Seg { from: Pt { x: 1, y: 2 }, to: Pt { x: 3, y: 4 } } }
        \\    expect { let e: Result<Seg, TestFailure> = Result.Ok(Seg { from: Pt { x: 1, y: 2 }, to: Pt { x: 3, y: 4 } }); return e }
        \\}
    );

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const out = try synth.injectTestDriver(allocator, program, &diags);
    try std.testing.expect(!diagnostics.hasErrors(diags.items));
    try std.testing.expect(hasFunction(out, "__kira_test_eq_Seg"));
    try std.testing.expect(hasFunction(out, "__kira_test_eq_Pt"));
}

test "hand-written eq_ bridge suppresses synthesis for that type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const program = try parse(allocator,
        \\struct Pt { var x: Int var y: Int }
        \\function eq_Pt(a: borrow Pt, b: borrow Pt) -> Bool { return a.x == b.x }
        \\Test TEq {
        \\    test { return Pt { x: 1, y: 2 } }
        \\    expect { let e: Result<Pt, TestFailure> = Result.Ok(Pt { x: 1, y: 2 }); return e }
        \\}
    );

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const out = try synth.injectTestDriver(allocator, program, &diags);
    try std.testing.expect(!diagnostics.hasErrors(diags.items));
    // The user's eq_Pt is authoritative; no synthesized comparator is emitted.
    try std.testing.expect(!hasFunction(out, "__kira_test_eq_Pt"));
    try std.testing.expect(hasFunction(out, "eq_Pt"));
}

test "payload-carrying enum result without a bridge is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const program = try parse(allocator,
        \\enum Shape { Circle(Int) Empty }
        \\Test TShape {
        \\    test { return Shape.Circle(3) }
        \\    expect { let e: Result<Shape, TestFailure> = Result.Ok(Shape.Circle(3)); return e }
        \\}
    );

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const out = try synth.injectTestDriver(allocator, program, &diags);
    // Refusal: a KTEST001 error is appended and no driver is injected.
    try std.testing.expect(diagnostics.hasErrors(diags.items));
    try std.testing.expect(!hasFunction(out, synth.driver_function_name));
}
