const std = @import("std");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const diagnostics = @import("kira_diagnostics");
const hybrid_runtime = @import("kira_hybrid_runtime");
const vm_runtime = @import("kira_vm_runtime");
const compare = @import("compare.zig");
const discovery = @import("discovery.zig");

pub const Options = struct {
    hybrid_runner_path: ?[]const u8 = null,
};

pub fn runCase(allocator: std.mem.Allocator, case: discovery.Case, reporter: anytype, options: Options) !void {
    var system = build.BuildSystem.init(allocator);
    for (case.expectation.backends) |backend| {
        try runBackendMatrix(allocator, &system, case, backend, reporter, options);
    }
}

fn runBackendMatrix(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    backend: discovery.Backend,
    reporter: anytype,
    options: Options,
) !void {
    var stopped = false;
    try runExpectedPhase(allocator, system, case, backend, .check, case.expectation.check, &stopped, reporter, options);
    try runExpectedPhase(allocator, system, case, backend, .build, case.expectation.build, &stopped, reporter, options);
    try runExpectedPhase(allocator, system, case, backend, .run, case.expectation.run, &stopped, reporter, options);
}

fn runExpectedPhase(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    backend: discovery.Backend,
    phase: discovery.Phase,
    expected: discovery.PhaseExpectation,
    stopped: *bool,
    reporter: anytype,
    options: Options,
) !void {
    if (expected.result == .blocked) {
        const label = try matrixLabel(allocator, case.name, backend, phase);
        if (!stopped.*) {
            const detail = try std.fmt.allocPrint(
                allocator,
                "{s} expected blocked, actual reachable",
                .{label},
            );
            reporter.fail(detail, error.ExpectationFailed);
            return error.ExpectationFailed;
        }
        reporter.pass(label);
        return;
    }

    if (stopped.*) {
        const label = try matrixLabel(allocator, case.name, backend, phase);
        const detail = try std.fmt.allocPrint(
            allocator,
            "{s} expected {s}, actual blocked by an earlier phase",
            .{ label, expectedResultName(expected.result) },
        );
        reporter.fail(detail, error.ExpectationFailed);
        return error.ExpectationFailed;
    }

    const actual = runPhase(allocator, system, case, backend, phase, options) catch |err| {
        const label = try matrixLabel(allocator, case.name, backend, phase);
        reporter.fail(label, err);
        return err;
    };
    if (actual.result == .fail) stopped.* = true;

    comparePhase(allocator, case.name, backend, phase, expected, actual, reporter) catch |err| {
        return err;
    };
}

const PhaseActual = struct {
    result: discovery.ExpectedResult,
    stdout: ?[]const u8 = null,
    diagnostics: []const diagnostics.Diagnostic = &.{},
    stage: ?discovery.Stage = null,
};

fn runPhase(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    backend: discovery.Backend,
    phase: discovery.Phase,
    options: Options,
) !PhaseActual {
    return switch (phase) {
        .check => runCheckPhase(allocator, case, backend),
        .build => runBuildPhase(allocator, system, case, backend),
        .run => runRunPhase(allocator, system, case, backend, options),
    };
}

fn runCheckPhase(
    allocator: std.mem.Allocator,
    case: discovery.Case,
    backend: discovery.Backend,
) !PhaseActual {
    const result = try build.checkFileForBackend(allocator, case.source_path, executionTarget(backend));
    return .{
        .result = if (result.failed()) .fail else .pass,
        .diagnostics = result.diagnostics,
        .stage = if (result.failure_stage) |stage| fromBuildStage(stage) else null,
    };
}

fn runBuildPhase(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    backend: discovery.Backend,
) !PhaseActual {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try buildOutputPath(allocator, tmp, backend);
    const result = try system.build(.{
        .source_path = case.source_path,
        .output_path = output_path,
        .target = .{ .execution = executionTarget(backend) },
    });
    return .{
        .result = if (result.failed()) .fail else .pass,
        .diagnostics = result.diagnostics,
        .stage = if (result.failure_stage) |stage| fromBuildStage(stage) else null,
    };
}

fn runRunPhase(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    backend: discovery.Backend,
    options: Options,
) !PhaseActual {
    return switch (backend) {
        .vm => runVmPhase(allocator, system, case),
        .llvm => runLlvmPhase(allocator, system, case),
        .hybrid => runHybridPhase(allocator, system, case, options),
    };
}

fn comparePhase(
    allocator: std.mem.Allocator,
    case_name: []const u8,
    backend: discovery.Backend,
    phase: discovery.Phase,
    expected: discovery.PhaseExpectation,
    actual: PhaseActual,
    reporter: anytype,
) !void {
    const label = try matrixLabel(allocator, case_name, backend, phase);
    if (actual.result != expected.result) {
        const detail = try std.fmt.allocPrint(
            allocator,
            "{s} expected {s}, actual {s}",
            .{ label, expectedResultName(expected.result), expectedResultName(actual.result) },
        );
        reporter.fail(detail, error.ExpectationFailed);
        return error.ExpectationFailed;
    }

    switch (expected.result) {
        .pass => {
            if (phase == .run) {
                compare.expectStdout(allocator, actual.stdout orelse "", expected.stdout orelse "") catch |err| {
                    const detail = try std.fmt.allocPrint(allocator, "{s} expected pass, actual stdout mismatch", .{label});
                    reporter.fail(detail, err);
                    return err;
                };
            }
        },
        .fail => {
            compare.expectDiagnostic(
                actual.diagnostics,
                expected.diagnostic_code orelse return error.MissingDiagnosticExpectation,
                expected.diagnostic_title orelse return error.MissingDiagnosticExpectation,
            ) catch |err| {
                const actual_diag = firstDiagnostic(actual.diagnostics);
                const detail = try std.fmt.allocPrint(
                    allocator,
                    "{s} expected fail {s}/{s}, actual fail {s}/{s}",
                    .{
                        label,
                        expected.diagnostic_code orelse "",
                        expected.diagnostic_title orelse "",
                        actual_diag.code,
                        actual_diag.title,
                    },
                );
                reporter.fail(detail, err);
                return err;
            };
            if (expected.stage) |stage| {
                if (actual.stage == null or actual.stage.? != stage) {
                    const detail = try std.fmt.allocPrint(
                        allocator,
                        "{s} expected fail at {s}, actual fail at {s}",
                        .{ label, stageName(stage), if (actual.stage) |actual_stage| stageName(actual_stage) else "unknown" },
                    );
                    reporter.fail(detail, error.ExpectationFailed);
                    return error.ExpectationFailed;
                }
            }
        },
        .blocked => unreachable,
    }
    reporter.pass(label);
}

fn runVmPhase(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) !PhaseActual {
    const result = try system.compileVm(case.source_path);
    if (result.failed() or result.diagnostics.len != 0) {
        return .{
            .result = .fail,
            .diagnostics = result.diagnostics,
            .stage = if (result.failure_stage) |stage| fromBuildStage(stage) else null,
        };
    }

    var output = std.array_list.Managed(u8).init(allocator);

    var vm = vm_runtime.Vm.init(allocator);
    try vm.runMain(&result.bytecode_module.?, output.writer());
    return .{
        .result = .pass,
        .stdout = try output.toOwnedSlice(),
    };
}

fn runLlvmPhase(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) !PhaseActual {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try makeBackendOutputPath(allocator, tmp, "llvm", build.executableExtension());
    const result = try system.buildNativeArtifact(.{
        .source_path = case.source_path,
        .output_path = output_path,
        .target = .{ .execution = .llvm_native },
    });
    if (result.failed() or result.diagnostics.len != 0) {
        return .{
            .result = .fail,
            .diagnostics = result.diagnostics,
            .stage = if (result.failure_stage) |stage| fromBuildStage(stage) else null,
        };
    }

    const executable = findExecutable(result.artifacts) orelse return error.MissingExecutableArtifact;
    const child = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{executable.path},
    });
    defer allocator.free(child.stderr);
    try expectExitedZero(child.term);
    try compare.expectEmptyText(allocator, child.stderr);
    return .{
        .result = .pass,
        .stdout = child.stdout,
    };
}

fn runHybridPhase(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    options: Options,
) !PhaseActual {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest_path = try makeBackendOutputPath(allocator, tmp, "hybrid", ".khm");
    const result = try system.buildHybridArtifact(.{
        .source_path = case.source_path,
        .output_path = manifest_path,
        .target = .{ .execution = .hybrid },
    });
    if (result.failed() or result.diagnostics.len != 0) {
        return .{
            .result = .fail,
            .diagnostics = result.diagnostics,
            .stage = if (result.failure_stage) |stage| fromBuildStage(stage) else null,
        };
    }

    const runner = options.hybrid_runner_path orelse return error.MissingHybridRunner;
    const child = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ runner, manifest_path },
    });
    defer allocator.free(child.stderr);
    try expectExitedZero(child.term);
    try compare.expectEmptyText(allocator, child.stderr);
    return .{
        .result = .pass,
        .stdout = child.stdout,
    };
}

fn findExecutable(artifacts: []const build_def.Artifact) ?build_def.Artifact {
    for (artifacts) |artifact| {
        if (artifact.kind == .executable) return artifact;
    }
    return null;
}

fn buildOutputPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, backend: discovery.Backend) ![]const u8 {
    return switch (backend) {
        .vm => makeBackendOutputPath(allocator, tmp, "vm", ".kbc"),
        .llvm => makeBackendOutputPath(allocator, tmp, "llvm", build.executableExtension()),
        .hybrid => makeBackendOutputPath(allocator, tmp, "hybrid", ".khm"),
    };
}

fn makeBackendOutputPath(
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    backend_name: []const u8,
    extension: []const u8,
) ![]const u8 {
    try tmp.dir.makePath(backend_name);
    const backend_root = try tmp.dir.realpathAlloc(allocator, backend_name);
    const file_name = try std.fmt.allocPrint(allocator, "main{s}", .{extension});
    return std.fs.path.join(allocator, &.{ backend_root, file_name });
}

fn expectExitedZero(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.CommandFailed,
    }
}

fn matrixLabel(
    allocator: std.mem.Allocator,
    case_name: []const u8,
    backend: discovery.Backend,
    phase: discovery.Phase,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} [{s} {s}]", .{ case_name, backendName(backend), phaseName(phase) });
}

fn backendName(backend: discovery.Backend) []const u8 {
    return switch (backend) {
        .vm => "vm",
        .llvm => "llvm",
        .hybrid => "hybrid",
    };
}

fn phaseName(phase: discovery.Phase) []const u8 {
    return switch (phase) {
        .check => "check",
        .build => "build",
        .run => "run",
    };
}

fn expectedResultName(result: discovery.ExpectedResult) []const u8 {
    return switch (result) {
        .pass => "pass",
        .fail => "fail",
        .blocked => "blocked",
    };
}

fn stageName(stage: discovery.Stage) []const u8 {
    return switch (stage) {
        .lexer => "lexer",
        .parser => "parser",
        .graph => "graph",
        .semantics => "semantics",
        .ir => "ir",
        .backend_prepare => "backend_prepare",
    };
}

fn executionTarget(backend: discovery.Backend) build_def.ExecutionTarget {
    return switch (backend) {
        .vm => .vm,
        .llvm => .llvm_native,
        .hybrid => .hybrid,
    };
}

fn fromBuildStage(stage: build.FrontendStage) discovery.Stage {
    return switch (stage) {
        .lexer => .lexer,
        .parser => .parser,
        .graph => .graph,
        .semantics => .semantics,
        .ir => .ir,
        .backend_prepare => .backend_prepare,
    };
}

const DiagnosticSummary = struct {
    code: []const u8,
    title: []const u8,
};

fn firstDiagnostic(items: []const diagnostics.Diagnostic) DiagnosticSummary {
    if (items.len == 0) return .{ .code = "<none>", .title = "<none>" };
    return .{
        .code = items[0].code orelse "<none>",
        .title = items[0].title,
    };
}

test "phase comparison catches unexpected run failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var reporter = TestReporter{};
    try std.testing.expectError(error.ExpectationFailed, comparePhase(
        arena.allocator(),
        "tests/pass/run/example",
        .hybrid,
        .run,
        .{ .result = .pass, .stdout = "ok\n" },
        .{ .result = .fail },
        &reporter,
    ));
    try std.testing.expectEqual(@as(usize, 1), reporter.failed);
}

const TestReporter = struct {
    passed: usize = 0,
    failed: usize = 0,

    pub fn pass(self: *TestReporter, _: []const u8) void {
        self.passed += 1;
    }

    pub fn fail(self: *TestReporter, _: []const u8, _: anyerror) void {
        self.failed += 1;
    }
};
