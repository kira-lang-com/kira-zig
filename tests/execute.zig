const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");
const vm_runtime = @import("kira_vm_runtime");
const compare = @import("compare.zig");
const discovery = @import("discovery.zig");
const reporting = @import("reporting.zig");
const support = @import("execute_support.zig");
pub const Options = struct {
    hybrid_runner_path: ?[]const u8 = null,
    profile: bool = false,
    phases: PhaseSet = .all,
};
pub const JobReport = reporting.JobReport;
const PhaseProfile = reporting.PhaseProfile;
pub const PhaseSet = support.PhaseSet;

// any number of build/check jobs may run concurrently — they take the shared (read)
var process_state_lock: support.RwLock = .{};

pub fn runBackendJob(
    allocator: std.mem.Allocator,
    case: discovery.Case,
    backend: discovery.Backend,
    options: Options,
) !JobReport {
    var reporter = reporting.BufferedReporter.init(allocator);
    var system = build.BuildSystem.init(allocator);
    var profiles: [3]PhaseProfile = .{ .{}, .{}, .{} };

    runBackendMatrix(allocator, &system, case, backend, &reporter, options, &profiles) catch |err| {
        if (reporter.failed == 0) {
            const label = try support.backendLabel(allocator, case.name, backend);
            reporter.fail(label, err);
        }
    };

    if (options.profile) reporter.writeTimingSummary(case.name, backend, &profiles);
    return reporter.finish();
}
pub fn runCase(allocator: std.mem.Allocator, case: discovery.Case, reporter: anytype, options: Options) !void {
    var system = build.BuildSystem.init(allocator);
    for (case.expectation.backends) |backend| {
        var profiles: [3]PhaseProfile = .{ .{}, .{}, .{} };
        runBackendMatrix(allocator, &system, case, backend, reporter, options, &profiles) catch {};
    }
}

fn runBackendMatrix(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    backend: discovery.Backend,
    reporter: anytype,
    options: Options,
    profiles: *[3]PhaseProfile,
) !void {
    var stopped = false;
    if (options.phases.includes(.check) and case.expectation.check.result == .pass and case.expectation.build.result == .pass) {
        profiles[phaseIndex(.check)] = .{ .kind = .assumed_pass };
        reporter.pass(try support.matrixLabel(allocator, case.name, backend, .check));
    } else if (options.phases.includes(.check)) {
        try runExpectedPhase(allocator, system, case, backend, .check, case.expectation.check, &stopped, reporter, options, &profiles[phaseIndex(.check)]);
    }
    if (options.phases.includes(.build)) {
        try runExpectedPhase(allocator, system, case, backend, .build, case.expectation.build, &stopped, reporter, options, &profiles[phaseIndex(.build)]);
    }
    if (options.phases.includes(.run)) {
        try runExpectedPhase(allocator, system, case, backend, .run, case.expectation.run, &stopped, reporter, options, &profiles[phaseIndex(.run)]);
    }
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
    profile: *PhaseProfile,
) !void {
    if (expected.result == .blocked) {
        profile.* = .{ .kind = .blocked };
        const label = try support.matrixLabel(allocator, case.name, backend, phase);
        if (!stopped.*) {
            const detail = try std.fmt.allocPrint(
                allocator,
                "{s} expected blocked, actual reachable",
                .{label},
            );
            reportFailure(reporter, detail, error.ExpectationFailed, .{
                .case_name = case.name,
                .backend = backend,
                .phase = phase,
                .signature = try std.fmt.allocPrint(allocator, "expectation:{s}:blocked-reachable", .{support.phaseName(phase)}),
            });
            return error.ExpectationFailed;
        }
        reporter.pass(label);
        return;
    }

    if (stopped.*) {
        const label = try support.matrixLabel(allocator, case.name, backend, phase);
        const detail = try std.fmt.allocPrint(
            allocator,
            "{s} expected {s}, actual blocked by an earlier phase",
            .{ label, support.expectedResultName(expected.result) },
        );
        reportFailure(reporter, detail, error.ExpectationFailed, .{
            .case_name = case.name,
            .backend = backend,
            .phase = phase,
            .signature = try std.fmt.allocPrint(allocator, "expectation:{s}:blocked-by-earlier-phase", .{support.phaseName(phase)}),
        });
        return error.ExpectationFailed;
    }

    const actual = runPhase(allocator, system, case, backend, phase, options) catch |err| {
        const label = try support.matrixLabel(allocator, case.name, backend, phase);
        reportFailure(reporter, label, err, .{
            .case_name = case.name,
            .backend = backend,
            .phase = phase,
            .signature = try std.fmt.allocPrint(allocator, "internal:{s}:{s}:{s}", .{ support.backendName(backend), support.phaseName(phase), @errorName(err) }),
        });
        return err;
    };
    profile.* = actual.profile;
    if (actual.result == .fail) stopped.* = true;

    comparePhase(allocator, case.name, case.source_path, backend, phase, expected, actual, reporter) catch |err| {
        return err;
    };
}

const PhaseActual = struct {
    result: discovery.ExpectedResult,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    trace: ?[]const u8 = null,
    diagnostics: []const diagnostics.Diagnostic = &.{},
    stage: ?discovery.Stage = null,
    profile: PhaseProfile = .{},
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
        .check => runCheckPhase(allocator, system, case, backend),
        .build => runBuildPhase(allocator, system, case, backend),
        .run => runRunPhase(allocator, system, case, backend, options),
    };
}

fn runCheckPhase(
    _: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    backend: discovery.Backend,
) !PhaseActual {
    process_state_lock.lockShared();
    defer process_state_lock.unlockShared();

    const start = support.nowTimestamp();
    const result = try system.checkForBackend(case.source_path, support.executionTarget(backend));
    return .{
        .result = if (result.failed()) .fail else .pass,
        .diagnostics = result.diagnostics,
        .stage = if (result.failure_stage) |stage| support.fromBuildStage(stage) else null,
        .profile = .{
            .kind = .executed,
            .duration_ns = support.elapsedNs(start),
            .cache_status = result.cache_status,
            .cache_restore_ns = result.cache_restore_ns,
            .cache_store_ns = result.cache_store_ns,
        },
    };
}

fn runBuildPhase(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    backend: discovery.Backend,
) !PhaseActual {
    process_state_lock.lockShared();
    defer process_state_lock.unlockShared();

    var tmp = try support.makeTmpDir(allocator);
    defer tmp.cleanup();

    const start = support.nowTimestamp();
    const output_path = try support.buildOutputPath(allocator, tmp, backend);
    const result = try system.build(.{
        .source_path = case.source_path,
        .output_path = output_path,
        .target = .{ .execution = support.executionTarget(backend) },
    });
    return actualFromBuildOutcome(result, support.elapsedNs(start));
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
    source_path: []const u8,
    backend: discovery.Backend,
    phase: discovery.Phase,
    expected: discovery.PhaseExpectation,
    actual: PhaseActual,
    reporter: anytype,
) !void {
    const label = try support.matrixLabel(allocator, case_name, backend, phase);
    if (actual.result != expected.result) {
        const detail = try std.fmt.allocPrint(
            allocator,
            "{s} expected {s}, actual {s}",
            .{ label, support.expectedResultName(expected.result), support.expectedResultName(actual.result) },
        );
        reportFailure(reporter, detail, error.ExpectationFailed, try reporting.failureDetail(
            allocator,
            case_name,
            source_path,
            backend,
            phase,
            "result-mismatch",
            failureActual(actual),
        ));
        return error.ExpectationFailed;
    }

    switch (expected.result) {
        .pass => {
            if (phase == .run) {
                compare.expectStdout(allocator, actual.stdout orelse "", expected.stdout orelse "") catch |err| {
                    const detail = try std.fmt.allocPrint(allocator, "{s} expected pass, actual stdout mismatch", .{label});
                    reportFailure(reporter, detail, err, try reporting.failureDetail(
                        allocator,
                        case_name,
                        source_path,
                        backend,
                        phase,
                        "stdout-mismatch",
                        failureActual(actual),
                    ));
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
                const actual_diag = support.firstDiagnostic(actual.diagnostics);
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
                reportFailure(reporter, detail, err, try reporting.failureDetail(
                    allocator,
                    case_name,
                    source_path,
                    backend,
                    phase,
                    "diagnostic-mismatch",
                    failureActual(actual),
                ));
                return err;
            };
            if (expected.stage) |stage| {
                if (actual.stage == null or actual.stage.? != stage) {
                    const detail = try std.fmt.allocPrint(
                        allocator,
                        "{s} expected fail at {s}, actual fail at {s}",
                        .{ label, support.stageName(stage), if (actual.stage) |actual_stage| support.stageName(actual_stage) else "unknown" },
                    );
                    reportFailure(reporter, detail, error.ExpectationFailed, try reporting.failureDetail(
                        allocator,
                        case_name,
                        source_path,
                        backend,
                        phase,
                        "stage-mismatch",
                        failureActual(actual),
                    ));
                    return error.ExpectationFailed;
                }
            }
        },
        .blocked => unreachable,
    }
    reporter.pass(label);
}

fn runVmPhase(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) !PhaseActual {
    process_state_lock.lock();
    defer process_state_lock.unlock();

    var tmp = try support.makeTmpDir(allocator);
    defer tmp.cleanup();

    const start = support.nowTimestamp();
    const output_path = try support.buildOutputPath(allocator, tmp, .vm);
    const result = try system.build(.{
        .source_path = case.source_path,
        .output_path = output_path,
        .target = .{ .execution = .vm },
    });
    if (result.failed() or result.diagnostics.len != 0) {
        return actualFromBuildOutcome(result, support.elapsedNs(start));
    }

    const module = try system.readBytecode(output_path);
    var output: std.Io.Writer.Allocating = .init(allocator);
    const run_cwd = try support.runtimeCwdForCase(allocator, case);
    defer allocator.free(run_cwd);

    var vm = vm_runtime.Vm.init(allocator);
    var original_cwd = try std.Io.Dir.cwd().openDir(std.Options.debug_io, ".", .{});
    defer {
        std.process.setCurrentDir(std.Options.debug_io, original_cwd) catch {};
        original_cwd.close(std.Options.debug_io);
    }
    var run_dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, run_cwd, .{});
    defer run_dir.close(std.Options.debug_io);
    try std.process.setCurrentDir(std.Options.debug_io, run_dir);

    var ffi_dispatcher = vm_runtime.FfiDispatcher.init(allocator, &module);
    defer ffi_dispatcher.deinit();
    for (result.native_libraries) |library| {
        try ffi_dispatcher.registerLibrary(library.name, library.artifact_path);
    }
    try vm.runMainWithHooks(&module, &output.writer, .{
        .context = &ffi_dispatcher,
        .call_native = vm_runtime.FfiDispatcher.hook,
    });
    return .{
        .result = .pass,
        .stdout = try output.toOwnedSlice(),
        .profile = .{
            .kind = .executed,
            .duration_ns = support.elapsedNs(start),
            .cache_status = result.cache_status,
            .cache_restore_ns = result.cache_restore_ns,
            .cache_store_ns = result.cache_store_ns,
        },
    };
}

fn runLlvmPhase(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) !PhaseActual {
    process_state_lock.lockShared();
    defer process_state_lock.unlockShared();

    var tmp = try support.makeTmpDir(allocator);
    defer tmp.cleanup();

    const start = support.nowTimestamp();
    const output_path = try support.makeBackendOutputPath(allocator, tmp, "llvm", build.executableExtension());
    const result = try system.build(.{
        .source_path = case.source_path,
        .output_path = output_path,
        .target = .{ .execution = .llvm_native },
    });
    if (result.failed() or result.diagnostics.len != 0) {
        return actualFromBuildOutcome(result, support.elapsedNs(start));
    }

    const executable = support.findExecutable(result.artifacts) orelse return error.MissingExecutableArtifact;
    const run_cwd = try support.runtimeCwdForCase(allocator, case);
    defer allocator.free(run_cwd);
    const process_environ = support.inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const child = try std.process.run(allocator, io_impl.io(), .{
        .argv = &.{executable.path},
        .cwd = .{ .path = run_cwd },
    });
    defer allocator.free(child.stderr);
    if (support.expectExitedZero(child.term)) |_| {} else |_| {
        return .{
            .result = .fail,
            .stdout = child.stdout,
            .stderr = child.stderr,
            .trace = try reporting.childTrace(allocator, "llvm", child.term, child.stdout, child.stderr),
            .profile = .{
                .kind = .executed,
                .duration_ns = support.elapsedNs(start),
                .cache_status = result.cache_status,
                .cache_restore_ns = result.cache_restore_ns,
                .cache_store_ns = result.cache_store_ns,
            },
        };
    }
    compare.expectEmptyText(allocator, child.stderr) catch {
        return .{
            .result = .fail,
            .stdout = child.stdout,
            .stderr = child.stderr,
            .trace = try reporting.childTrace(allocator, "llvm", child.term, child.stdout, child.stderr),
            .profile = .{
                .kind = .executed,
                .duration_ns = support.elapsedNs(start),
                .cache_status = result.cache_status,
                .cache_restore_ns = result.cache_restore_ns,
                .cache_store_ns = result.cache_store_ns,
            },
        };
    };
    return .{
        .result = .pass,
        .stdout = child.stdout,
        .profile = .{
            .kind = .executed,
            .duration_ns = support.elapsedNs(start),
            .cache_status = result.cache_status,
            .cache_restore_ns = result.cache_restore_ns,
            .cache_store_ns = result.cache_store_ns,
        },
    };
}

fn runHybridPhase(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    options: Options,
) !PhaseActual {
    process_state_lock.lockShared();
    defer process_state_lock.unlockShared();

    var tmp = try support.makeTmpDir(allocator);
    defer tmp.cleanup();

    const start = support.nowTimestamp();
    const manifest_path = try support.makeBackendOutputPath(allocator, tmp, "hybrid", ".khm");
    const result = try system.build(.{
        .source_path = case.source_path,
        .output_path = manifest_path,
        .target = .{ .execution = .hybrid },
    });
    if (result.failed() or result.diagnostics.len != 0) {
        return actualFromBuildOutcome(result, support.elapsedNs(start));
    }

    const runner = options.hybrid_runner_path orelse return error.MissingHybridRunner;
    const runner_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, runner, allocator);
    defer allocator.free(runner_path);
    const run_cwd = try support.runtimeCwdForCase(allocator, case);
    defer allocator.free(run_cwd);
    const process_environ = support.inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const child = try std.process.run(allocator, io_impl.io(), .{
        .argv = &.{ runner_path, manifest_path },
        .cwd = .{ .path = run_cwd },
    });
    defer allocator.free(child.stderr);
    if (support.expectExitedZero(child.term)) |_| {} else |_| {
        return .{
            .result = .fail,
            .stdout = child.stdout,
            .stderr = child.stderr,
            .trace = try reporting.hybridFailureTrace(allocator, child, manifest_path, runner_path, run_cwd),
            .profile = .{
                .kind = .executed,
                .duration_ns = support.elapsedNs(start),
                .cache_status = result.cache_status,
                .cache_restore_ns = result.cache_restore_ns,
                .cache_store_ns = result.cache_store_ns,
            },
        };
    }
    compare.expectEmptyText(allocator, child.stderr) catch {
        return .{
            .result = .fail,
            .stdout = child.stdout,
            .stderr = child.stderr,
            .trace = try reporting.hybridFailureTrace(allocator, child, manifest_path, runner_path, run_cwd),
            .profile = .{
                .kind = .executed,
                .duration_ns = support.elapsedNs(start),
                .cache_status = result.cache_status,
                .cache_restore_ns = result.cache_restore_ns,
                .cache_store_ns = result.cache_store_ns,
            },
        };
    };
    return .{
        .result = .pass,
        .stdout = child.stdout,
        .profile = .{
            .kind = .executed,
            .duration_ns = support.elapsedNs(start),
            .cache_status = result.cache_status,
            .cache_restore_ns = result.cache_restore_ns,
            .cache_store_ns = result.cache_store_ns,
        },
    };
}

fn actualFromBuildOutcome(result: build.BuildArtifactOutcome, duration_ns: u64) PhaseActual {
    return .{
        .result = if (result.failed()) .fail else .pass,
        .diagnostics = result.diagnostics,
        .stage = if (result.failure_stage) |stage| support.fromBuildStage(stage) else null,
        .profile = .{
            .kind = .executed,
            .duration_ns = duration_ns,
            .cache_status = result.cache_status,
            .cache_restore_ns = result.cache_restore_ns,
            .cache_store_ns = result.cache_store_ns,
        },
    };
}

fn reportFailure(reporter: anytype, label: []const u8, err: anyerror, detail: reporting.FailureDetail) void {
    const Reporter = @TypeOf(reporter.*);
    if (@hasDecl(Reporter, "failDetailed")) {
        reporter.failDetailed(label, err, detail) catch reporter.fail(label, err);
    } else {
        reporter.fail(label, err);
    }
}

fn failureActual(actual: PhaseActual) reporting.PhaseFailureActual {
    return .{
        .result = actual.result,
        .stdout = actual.stdout,
        .stderr = actual.stderr,
        .trace = actual.trace,
        .diagnostics = actual.diagnostics,
        .stage = actual.stage,
    };
}

fn phaseIndex(phase: discovery.Phase) usize {
    return switch (phase) {
        .check => 0,
        .build => 1,
        .run => 2,
    };
}

test "phase comparison catches unexpected run failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var reporter = TestReporter{};
    try std.testing.expectError(error.ExpectationFailed, comparePhase(
        arena.allocator(),
        "tests/pass/run/example",
        "tests/pass/run/example/main.kira",
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
    pub fn pass(self: *TestReporter, _: []const u8) void { self.passed += 1; }
    pub fn fail(self: *TestReporter, _: []const u8, _: anyerror) void { self.failed += 1; }
};
