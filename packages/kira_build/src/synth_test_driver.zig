//! Pure-Kira test driver synthesis.
//!
//! In test mode the compiler can synthesize a Kira entry function that runs
//! every `Test` declaration's `expect`/`test` sections, compares the result in
//! Kira (`==`), and prints a `PASS`/`FAIL`/`SKIP` line per test. Running that
//! driver on a backend is how `kira test` executes the suite without any
//! backend-specific Zig comparison override — so the same Test runs on vm,
//! llvm, and hybrid (and FFI works on hybrid because the driver is ordinary
//! Kira that bridges into @Native through the normal path).
//!
//! Trap-expectation tests (`expect` returns `Result.Error(...)`) cannot be run
//! from pure Kira yet — a hard abort (array OOB / divide-by-zero) is not
//! catchable via `attempt`/`handle` — so the driver SKIPs them by only calling
//! `test()` inside the `Ok` arm. Making those catchable is a separate runtime
//! change (phase 2).

const std = @import("std");
const syntax = @import("kira_syntax_model");
const diagnostics = @import("kira_diagnostics");
const parser = @import("kira_parser");
const eq = @import("synth_test_driver_eq.zig");

/// The synthesized driver function's name. The test runner invokes it by name.
pub const driver_function_name = "__kira_test_main";

fn isTestForm(form: syntax.ast.ConstructFormDecl) bool {
    const segments = form.construct_name.segments;
    return segments.len != 0 and std.mem.eql(u8, segments[segments.len - 1].text, "Test");
}

/// Returns `program` augmented with the synthesized driver function, or the
/// original program unchanged when it declares no `Test`s.
pub fn injectTestDriver(
    allocator: std.mem.Allocator,
    program: syntax.ast.Program,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !syntax.ast.Program {
    const Test = struct { name: []const u8, form: syntax.ast.ConstructFormDecl };
    var tests = std.array_list.Managed(Test).init(allocator);
    defer tests.deinit();
    for (program.decls) |decl| {
        if (decl != .construct_form_decl) continue;
        const form = decl.construct_form_decl;
        if (!isTestForm(form)) continue;
        try tests.append(.{ .name = form.name, .form = form });
    }
    if (tests.items.len == 0) return program;

    // Type environment for structural-equality synthesis: struct/enum decls plus
    // any authoritative `eq_<T>` bridges (hand-written or `@Derive(Equatable)`).
    var env = try eq.Env.build(allocator, program);

    // Per-test comparison dispatch, and the set of struct comparators to
    // synthesize (transitively). A `null` dispatch keeps the scalar `==` path.
    var dispatch = std.array_list.Managed(?[]const u8).init(allocator);
    defer dispatch.deinit();
    var needed: std.StringHashMapUnmanaged(void) = .{};
    for (tests.items) |t| {
        const value_type = eq.resultValueType(t.form);
        switch (try eq.topLevelDispatch(&env, value_type)) {
            .scalar => try dispatch.append(null),
            .comparator => |fn_name| {
                try dispatch.append(fn_name);
                if (std.mem.startsWith(u8, fn_name, eq.synth_prefix))
                    try needed.put(allocator, fn_name[eq.synth_prefix.len..], {});
            },
            .refuse => |type_name| {
                try eq.refuseTopLevel(&env, diags, type_name, t.form.span);
                return program;
            },
        }
    }
    try eq.expandNeeded(&env, &needed);

    var src: std.Io.Writer.Allocating = .init(allocator);
    defer src.deinit();
    const writer = &src.writer;

    // Synthesize the recursive struct comparators the driver dispatches through.
    // A refusal (unsupported field type with no `eq_` bridge) aborts injection so
    // the build fails loudly with a KTEST001 diagnostic — never silent-wrong.
    var needed_it = needed.iterator();
    while (needed_it.next()) |entry| {
        if (!try eq.emitStructComparator(&env, writer, entry.key_ptr.*, diags))
            return program;
    }

    try writer.print("function {s}() {{\n", .{driver_function_name});
    for (tests.items, dispatch.items) |t, cmp| {
        const name = t.name;
        // The string literals bake the test name in at synthesis time (Kira has
        // no string concatenation), so each line is self-describing.
        //
        // Each marker line is prefixed with a NUL (`\0`) sentinel. The driver's
        // PASS/FAIL/KTRAP output is captured on the same stdout stream as any
        // output the tests themselves print, so without a sentinel a test that
        // printed e.g. "PASS x" would be miscounted as a test result. The runner
        // only treats NUL-prefixed lines as driver markers; ordinary test output
        // never begins with a NUL.
        //
        // `condition` is `__actual == __expected` for scalar results, or a
        // structural comparator call `<eq_fn>(__actual, __expected)` for struct
        // results. Comparators take `borrow` params, so neither operand is moved.
        const condition = if (cmp) |fn_name|
            try std.fmt.allocPrint(allocator, "{s}(__actual, __expected)", .{fn_name})
        else
            "__actual == __expected";
        try writer.print(
            "    match {s}__expect() {{\n" ++
                "        Ok(__expected) -> {{\n" ++
                "            let __actual = {s}__test()\n" ++
                "            if {s} {{ print(\"\\0PASS {s}\") }} else {{ print(\"\\0FAIL {s} (value mismatch)\") }}\n" ++
                "        }}\n" ++
                // A trap-expectation test (expect = Result.Error): the driver must
                // NOT call test() here (a hard abort would kill the whole driver).
                // Emit a marker so the runner re-runs test() in isolation and
                // checks that it traps.
                "        Error(__failure) -> {{ print(\"\\0KTRAP {s}\") }}\n" ++
                "    }}\n",
            .{ name, name, condition, name, name, name },
        );
    }
    try writer.writeAll("    return\n}\n");

    const driver_program = try parser.parseSource(allocator, src.written(), diags);
    if (diagnostics.hasErrors(diags.items)) return program;

    // The parser records a top-level function in BOTH `decls` (as a
    // `.function_decl`) and `functions`; semantics reads `decls`. Extend both,
    // keeping the per-list origin arrays aligned (a root origin per driver item).
    var decls = std.array_list.Managed(syntax.ast.Decl).init(allocator);
    try decls.appendSlice(program.decls);
    try decls.appendSlice(driver_program.decls);
    var decl_origins = std.array_list.Managed(syntax.ast.DeclOrigin).init(allocator);
    try decl_origins.appendSlice(program.decl_origins);
    while (decl_origins.items.len < program.decls.len) try decl_origins.append(.{});
    for (driver_program.decls) |_| try decl_origins.append(.{});

    var functions = std.array_list.Managed(syntax.ast.FunctionDecl).init(allocator);
    try functions.appendSlice(program.functions);
    try functions.appendSlice(driver_program.functions);
    var function_origins = std.array_list.Managed(syntax.ast.DeclOrigin).init(allocator);
    try function_origins.appendSlice(program.function_origins);
    while (function_origins.items.len < program.functions.len) try function_origins.append(.{});
    for (driver_program.functions) |_| try function_origins.append(.{});

    return .{
        .imports = program.imports,
        .decls = try decls.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
        .import_origins = program.import_origins,
        .decl_origins = try decl_origins.toOwnedSlice(),
        .function_origins = try function_origins.toOwnedSlice(),
    };
}
