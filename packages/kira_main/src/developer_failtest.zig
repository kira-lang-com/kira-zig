//! `FailTest` execution for `kira test`.
//!
//! A FailTest is an expected-compile-outcome test written in pure Kira (see
//! kira_syntax_model/ast.zig `FailTestDecl`). Its `source` is quoted text the
//! surrounding package never analyzes; the runner compiles that text as an
//! isolated synthetic single-file package, once per declared backend, entirely
//! runner-side — no VM involvement. A FailTest PASSES iff every declared backend
//! produces the expected outcome:
//!   * `expect { ... .Error(.Compile("CODE")) ... }` — the
//!     compile must FAIL with a diagnostic whose code or rendered text contains
//!     the substring `CODE`.
//!   * `expect { ... .Ok(1) ... }` — the compile must SUCCEED cleanly
//!     (the must-compile sentinel; `Ok(1)` is arbitrary but fixed by the grammar
//!     contract so the two forms stay symmetric on `Result<Int, TestFailure>`).
//!
//! The expected code and Ok/Error polarity are extracted TEXTUALLY from the
//! `expect` block (never executed) — the same approach synth_test_driver_eq.zig
//! uses to read a Test's result type from its annotation.

const std = @import("std");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const diagnostics = @import("kira_diagnostics");
const parser = @import("kira_parser");
const syntax = @import("kira_syntax_model");
const kira_project = @import("kira_project");
const package_manager = @import("kira_package_manager");

pub const Report = struct {
    passed: usize = 0,
    failed: usize = 0,
    total: usize = 0,
};

pub const Expectation = struct {
    /// true  => the source must compile cleanly (`.Ok`).
    /// false => the source must fail to compile with `code` (`.Compile`).
    must_compile: bool,
    /// Expected diagnostic-code substring; empty for the must-compile form.
    code: []const u8,
};

/// Extract the expected outcome from an `expect { ... }` block's raw text.
/// Returns null when the block matches neither the must-fail nor the must-compile
/// form (a malformed FailTest expectation).
pub fn extractExpectation(expect_text: []const u8) ?Expectation {
    const compile_index = std.mem.indexOf(u8, expect_text, "TestFailure.Compile") orelse
        std.mem.indexOf(u8, expect_text, ".Compile");
    if (compile_index) |idx| {
        const after = expect_text[idx..];
        const q1 = std.mem.indexOfScalar(u8, after, '"') orelse return null;
        const rest = after[q1 + 1 ..];
        const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        return .{ .must_compile = false, .code = rest[0..q2] };
    }
    if (std.mem.indexOf(u8, expect_text, "Result.Ok") != null or std.mem.indexOf(u8, expect_text, ".Ok") != null) {
        return .{ .must_compile = true, .code = "" };
    }
    return null;
}

/// Map a declared backend ident to its build target. The grammar restricts
/// `backends { ... }` to this set, so an unknown ident cannot reach here.
fn targetForBackend(name: []const u8) ?build_def.ExecutionTarget {
    if (std.mem.eql(u8, name, "vm")) return .vm;
    if (std.mem.eql(u8, name, "llvm")) return .llvm_native;
    if (std.mem.eql(u8, name, "hybrid")) return .hybrid;
    return null;
}

/// A diagnostic satisfies a must-fail expectation when its code OR its rendered
/// text (title/message) contains the expected substring.
fn diagnosticMatches(item: diagnostics.Diagnostic, code: []const u8) bool {
    if (item.code) |c| {
        if (std.mem.indexOf(u8, c, code) != null) return true;
    }
    if (std.mem.indexOf(u8, item.title, code) != null) return true;
    if (std.mem.indexOf(u8, item.message, code) != null) return true;
    return false;
}

fn anyErrorMatches(items: []const diagnostics.Diagnostic, code: []const u8) bool {
    for (items) |item| {
        if (item.severity != .@"error") continue;
        if (diagnosticMatches(item, code)) return true;
    }
    return false;
}

/// Run every FailTest in a leaf package, writing a `PASS`/`FAIL` line per test
/// and returning the tally to fold into the overall `kira test` result.
pub fn runForLeaf(allocator: std.mem.Allocator, leaf_path: []const u8, writer: anytype) !Report {
    const target = try kira_project.resolveTargetFromPath(allocator, leaf_path);
    const root = target.root_path orelse (if (target.source_path) |sp| std.fs.path.dirname(sp) orelse "." else ".");
    const scratch = try std.fs.path.join(allocator, &.{ root, ".kira-build", "failtest" });

    var files = std.array_list.Managed([]const u8).init(allocator);
    const app_dir = try std.fs.path.join(allocator, &.{ root, "app" });
    if (directoryExists(app_dir)) {
        try collectKiraFiles(allocator, app_dir, &files);
    } else if (target.source_path) |sp| {
        try files.append(sp);
    }

    var report = Report{};
    for (files.items) |file_path| {
        try runFile(allocator, file_path, root, scratch, writer, &report);
    }
    return report;
}

fn runFile(allocator: std.mem.Allocator, file_path: []const u8, root: []const u8, scratch: []const u8, writer: anytype, report: *Report) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, allocator, .limited(4 * 1024 * 1024)) catch return;
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = parser.parseSource(allocator, text, &diags) catch return;
    // A parse error in the surrounding file is reported by the main compile; here
    // we only harvest whatever FailTest declarations did parse.
    for (program.decls) |decl| {
        if (decl != .fail_test_decl) continue;
        try runOne(allocator, decl.fail_test_decl, root, scratch, writer, report);
    }
}

fn runOne(allocator: std.mem.Allocator, ft: syntax.ast.FailTestDecl, root: []const u8, scratch: []const u8, writer: anytype, report: *Report) !void {
    report.total += 1;
    const source = ft.source orelse {
        report.failed += 1;
        try writer.print("FAIL {s} (missing source)\n", .{ft.name});
        return;
    };
    const source_text = switch (source) {
        .block => |b| b,
        .string => |s| s,
    };
    const expect_text = ft.expect_text orelse {
        report.failed += 1;
        try writer.print("FAIL {s} (missing expect)\n", .{ft.name});
        return;
    };
    const expectation = extractExpectation(expect_text) orelse {
        report.failed += 1;
        try writer.print("FAIL {s} (unrecognized expect: want .Ok(...) or .Error(.Compile(\"CODE\")))\n", .{ft.name});
        return;
    };

    // Default backend when no `backends { ... }` block is declared: vm only.
    const default_backends = [_][]const u8{"vm"};
    const backends: []const []const u8 = if (ft.backends.len == 0) &default_backends else ft.backends;

    // Fixture mode: `source = "fixture(\"fixtures/<name>\")"` compiles a real
    // on-disk package DIRECTORY through the same per-backend check path. This is
    // the single-file form's escape hatch for multi-file / import-graph /
    // native-lib cases (duplicate-across-import, outside-app-import, invalid
    // callback signature). The path resolves relative to the leaf package root.
    if (parseFixtureRef(source_text)) |fixture_rel| {
        try runFixture(allocator, root, fixture_rel, backends, expectation, ft.name, writer, report);
        return;
    }

    // Write the quoted source once; it is recompiled per backend.
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, scratch) catch {};
    const source_path = try std.fs.path.join(allocator, &.{ scratch, try std.fmt.allocPrint(allocator, "{s}.kira", .{ft.name}) });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = source_path, .data = source_text });

    for (backends) |backend_name| {
        const backend = targetForBackend(backend_name) orelse {
            report.failed += 1;
            try writer.print("FAIL {s} (unknown backend {s})\n", .{ ft.name, backend_name });
            return;
        };
        // Strict per-backend semantics, mirroring `kira check --backend X`.
        // The Test driver's `allow_runtime_direct_ffi` override would suppress
        // backend-conditional rejections (e.g. KSEM093 "direct FFI requires
        // @Native" on llvm/hybrid) — exactly the diagnostics FailTests assert.
        const result = build.compileFileForBackendWithOptions(allocator, source_path, backend, null, &.{}, .{
            .require_main = false,
        }) catch |err| {
            report.failed += 1;
            try writer.print("FAIL {s} (compile error on {s}: {s})\n", .{ ft.name, backend_name, @errorName(err) });
            return;
        };
        const failed = result.failed();
        if (expectation.must_compile) {
            if (failed) {
                report.failed += 1;
                const actual = firstErrorCode(result.diagnostics) orelse "<none>";
                try writer.print("FAIL {s} (expected clean compile on {s}, got diagnostic {s})\n", .{ ft.name, backend_name, actual });
                return;
            }
        } else {
            if (!failed) {
                report.failed += 1;
                try writer.print("FAIL {s} (expected {s} on {s}, but source compiled)\n", .{ ft.name, expectation.code, backend_name });
                return;
            }
            if (!anyErrorMatches(result.diagnostics, expectation.code)) {
                report.failed += 1;
                const actual = firstErrorCode(result.diagnostics) orelse "<none>";
                try writer.print("FAIL {s} (expected {s} on {s}, got {s})\n", .{ ft.name, expectation.code, backend_name, actual });
                return;
            }
        }
    }
    report.passed += 1;
    try writer.print("PASS {s}\n", .{ft.name});
}

/// Recognize a fixture-reference source: `fixture("<relative/path>")` (the whole
/// source text is exactly that call). Returns the quoted path, or null for an
/// ordinary inline source.
pub fn parseFixtureRef(source_text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, source_text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "fixture(")) return null;
    if (!std.mem.endsWith(u8, trimmed, ")")) return null;
    const inner = std.mem.trim(u8, trimmed["fixture(".len .. trimmed.len - 1], " \t");
    if (inner.len < 2 or inner[0] != '"' or inner[inner.len - 1] != '"') return null;
    const path = inner[1 .. inner.len - 1];
    if (path.len == 0) return null;
    return path;
}

/// Compile the fixture package at `<root>/<fixture_rel>` once per declared
/// backend and assert the expectation (mirrors `kira check --backend X` on a
/// real package, so imports/import-graph layout/native-lib bindings all resolve
/// exactly as they would on disk). Passes iff every backend matches.
fn runFixture(
    allocator: std.mem.Allocator,
    root: []const u8,
    fixture_rel: []const u8,
    backends: []const []const u8,
    expectation: Expectation,
    name: []const u8,
    writer: anytype,
    report: *Report,
) !void {
    const fixture_dir = try std.fs.path.join(allocator, &.{ root, fixture_rel });
    if (!directoryExists(fixture_dir)) {
        report.failed += 1;
        try writer.print("FAIL {s} (fixture dir not found: {s})\n", .{ name, fixture_dir });
        return;
    }

    // `kira check` syncs the package before compiling; without this the module
    // map is lock-driven and a fresh checkout (no kira.lock in the fixture dir)
    // cannot resolve the fixture's path dependencies (KSEM032). The toolchain
    // version is irrelevant for fixture packages, which declare no kira_version.
    var sync_diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    defer sync_diags.deinit();
    _ = package_manager.syncProject(allocator, fixture_dir, "", .{}, &sync_diags) catch |err| {
        report.failed += 1;
        const code = firstErrorCode(sync_diags.items) orelse @errorName(err);
        try writer.print("FAIL {s} (fixture sync error: {s})\n", .{ name, code });
        return;
    };

    const target = kira_project.resolveTargetFromPath(allocator, fixture_dir) catch |err| {
        report.failed += 1;
        try writer.print("FAIL {s} (fixture resolve error: {s})\n", .{ name, @errorName(err) });
        return;
    };
    const entrypoint = target.source_path orelse {
        report.failed += 1;
        try writer.print("FAIL {s} (fixture has no entrypoint)\n", .{name});
        return;
    };

    for (backends) |backend_name| {
        const backend = targetForBackend(backend_name) orelse {
            report.failed += 1;
            try writer.print("FAIL {s} (unknown backend {s})\n", .{ name, backend_name });
            return;
        };
        var system = build.BuildSystem.init(allocator);
        const result = system.checkForBackend(entrypoint, backend) catch |err| {
            report.failed += 1;
            try writer.print("FAIL {s} (fixture check error on {s}: {s})\n", .{ name, backend_name, @errorName(err) });
            return;
        };
        const failed = result.failed();
        if (expectation.must_compile) {
            if (failed) {
                report.failed += 1;
                const actual = firstErrorCode(result.diagnostics) orelse "<none>";
                try writer.print("FAIL {s} (expected clean compile on {s}, got diagnostic {s})\n", .{ name, backend_name, actual });
                return;
            }
        } else {
            if (!failed) {
                report.failed += 1;
                try writer.print("FAIL {s} (expected {s} on {s}, but fixture compiled)\n", .{ name, expectation.code, backend_name });
                return;
            }
            if (!anyErrorMatches(result.diagnostics, expectation.code)) {
                report.failed += 1;
                const actual = firstErrorCode(result.diagnostics) orelse "<none>";
                try writer.print("FAIL {s} (expected {s} on {s}, got {s})\n", .{ name, expectation.code, backend_name, actual });
                return;
            }
        }
    }
    report.passed += 1;
    try writer.print("PASS {s} (fixture)\n", .{name});
}

fn firstErrorCode(items: []const diagnostics.Diagnostic) ?[]const u8 {
    for (items) |item| {
        if (item.severity == .@"error") return item.code orelse continue;
    }
    return null;
}

fn collectKiraFiles(allocator: std.mem.Allocator, dir_path: []const u8, out: *std.array_list.Managed([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(std.Options.debug_io);
    var it = dir.iterate();
    while (try it.next(std.Options.debug_io)) |entry| {
        const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        if (entry.kind == .directory) {
            try collectKiraFiles(allocator, child, out);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".kira")) {
            try out.append(child);
        }
    }
}

fn directoryExists(path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}

test "extractExpectation reads the must-fail form's diagnostic code" {
    const e = extractExpectation(
        "let e: Result<Int, TestFailure> = .Error(.Compile(\"KSEM107\")); return e",
    ) orelse return error.NoExpectation;
    try std.testing.expect(!e.must_compile);
    try std.testing.expectEqualStrings("KSEM107", e.code);
}

test "extractExpectation reads the must-compile Ok sentinel" {
    const e = extractExpectation(
        "let e: Result<Int, TestFailure> = .Ok(1); return e",
    ) orelse return error.NoExpectation;
    try std.testing.expect(e.must_compile);
    try std.testing.expectEqualStrings("", e.code);
}

test "extractExpectation prefers Compile over an Ok substring elsewhere" {
    // A malformed mix must still be read as must-fail (Compile wins).
    const e = extractExpectation(
        "Result.Ok(1) Result.Error(TestFailure.Compile(\"KPAR002\"))",
    ) orelse return error.NoExpectation;
    try std.testing.expect(!e.must_compile);
    try std.testing.expectEqualStrings("KPAR002", e.code);
}

test "extractExpectation rejects an unrecognized expect block" {
    try std.testing.expect(extractExpectation("return something_else") == null);
}

test "diagnosticMatches matches on code and on rendered text" {
    const by_code = diagnostics.Diagnostic{
        .severity = .@"error",
        .code = "KSEM107",
        .title = "use after move",
        .message = "value used after being moved",
        .labels = &.{},
        .help = null,
    };
    try std.testing.expect(diagnosticMatches(by_code, "KSEM107"));
    try std.testing.expect(diagnosticMatches(by_code, "after move")); // rendered text
    try std.testing.expect(!diagnosticMatches(by_code, "KSEM999"));
}

test "parseFixtureRef recognizes the fixture() form and rejects inline source" {
    try std.testing.expectEqualStrings("fixtures/foo", parseFixtureRef("fixture(\"fixtures/foo\")").?);
    try std.testing.expectEqualStrings("fixtures/bar", parseFixtureRef("  fixture(\"fixtures/bar\")\n").?);
    try std.testing.expect(parseFixtureRef("function main() {}") == null);
    try std.testing.expect(parseFixtureRef("fixture()") == null);
    try std.testing.expect(parseFixtureRef("fixture(\"\")") == null);
}

test "targetForBackend maps the grammar's three backend idents" {
    try std.testing.expectEqual(build_def.ExecutionTarget.vm, targetForBackend("vm").?);
    try std.testing.expectEqual(build_def.ExecutionTarget.llvm_native, targetForBackend("llvm").?);
    try std.testing.expectEqual(build_def.ExecutionTarget.hybrid, targetForBackend("hybrid").?);
    try std.testing.expect(targetForBackend("wasm") == null);
}
