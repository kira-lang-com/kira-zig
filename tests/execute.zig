const builtin = @import("builtin");
const std = @import("std");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const diagnostics = @import("kira_diagnostics");
const vm_runtime = @import("kira_vm_runtime");
const compare = @import("compare.zig");
const discovery = @import("discovery.zig");

pub const Options = struct {
    hybrid_runner_path: ?[]const u8 = null,
    profile: bool = false,
};

pub const JobReport = struct {
    output: []const u8,
    passed: usize,
    failed: usize,
};

pub fn runBackendJob(
    allocator: std.mem.Allocator,
    case: discovery.Case,
    backend: discovery.Backend,
    options: Options,
) !JobReport {
    var reporter = BufferedReporter.init(allocator);
    var system = build.BuildSystem.init(allocator);
    var profiles: [3]PhaseProfile = .{ .{}, .{}, .{} };

    runBackendMatrix(allocator, &system, case, backend, &reporter, options, &profiles) catch |err| {
        if (reporter.failed == 0) {
            const label = try backendLabel(allocator, case.name, backend);
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
    if (case.expectation.check.result == .pass and case.expectation.build.result == .pass) {
        profiles[phaseIndex(.check)] = .{ .kind = .assumed_pass };
        reporter.pass(try matrixLabel(allocator, case.name, backend, .check));
    } else {
        try runExpectedPhase(allocator, system, case, backend, .check, case.expectation.check, &stopped, reporter, options, &profiles[phaseIndex(.check)]);
    }
    try runExpectedPhase(allocator, system, case, backend, .build, case.expectation.build, &stopped, reporter, options, &profiles[phaseIndex(.build)]);
    try runExpectedPhase(allocator, system, case, backend, .run, case.expectation.run, &stopped, reporter, options, &profiles[phaseIndex(.run)]);
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
    profile.* = actual.profile;
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
    profile: PhaseProfile = .{},
};

const PhaseProfile = struct {
    kind: Kind = .not_run,
    duration_ns: u64 = 0,
    cache_status: build.CacheStatus = .not_checked,
    cache_restore_ns: u64 = 0,
    cache_store_ns: u64 = 0,

    const Kind = enum {
        not_run,
        assumed_pass,
        blocked,
        executed,
    };
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
    const start = nowTimestamp();
    const result = try system.checkForBackend(case.source_path, executionTarget(backend));
    return .{
        .result = if (result.failed()) .fail else .pass,
        .diagnostics = result.diagnostics,
        .stage = if (result.failure_stage) |stage| fromBuildStage(stage) else null,
        .profile = .{
            .kind = .executed,
            .duration_ns = elapsedNs(start),
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
    var tmp = try makeTmpDir(allocator);
    defer tmp.cleanup();

    const start = nowTimestamp();
    const output_path = try buildOutputPath(allocator, tmp, backend);
    const result = try system.build(.{
        .source_path = case.source_path,
        .output_path = output_path,
        .target = .{ .execution = executionTarget(backend) },
    });
    return actualFromBuildOutcome(result, elapsedNs(start));
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
    var tmp = try makeTmpDir(allocator);
    defer tmp.cleanup();

    const start = nowTimestamp();
    const output_path = try buildOutputPath(allocator, tmp, .vm);
    const result = try system.build(.{
        .source_path = case.source_path,
        .output_path = output_path,
        .target = .{ .execution = .vm },
    });
    if (result.failed() or result.diagnostics.len != 0) {
        return actualFromBuildOutcome(result, elapsedNs(start));
    }

    const module = try system.readBytecode(output_path);
    var output: std.Io.Writer.Allocating = .init(allocator);

    var vm = vm_runtime.Vm.init(allocator);
    try vm.runMain(&module, &output.writer);
    return .{
        .result = .pass,
        .stdout = try output.toOwnedSlice(),
        .profile = .{
            .kind = .executed,
            .duration_ns = elapsedNs(start),
            .cache_status = result.cache_status,
            .cache_restore_ns = result.cache_restore_ns,
            .cache_store_ns = result.cache_store_ns,
        },
    };
}

fn runLlvmPhase(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) !PhaseActual {
    var tmp = try makeTmpDir(allocator);
    defer tmp.cleanup();

    const start = nowTimestamp();
    const output_path = try makeBackendOutputPath(allocator, tmp, "llvm", build.executableExtension());
    const result = try system.build(.{
        .source_path = case.source_path,
        .output_path = output_path,
        .target = .{ .execution = .llvm_native },
    });
    if (result.failed() or result.diagnostics.len != 0) {
        return actualFromBuildOutcome(result, elapsedNs(start));
    }

    const executable = findExecutable(result.artifacts) orelse return error.MissingExecutableArtifact;
    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const child = try std.process.run(allocator, io_impl.io(), .{
        .argv = &.{executable.path},
    });
    defer allocator.free(child.stderr);
    try expectExitedZero(child.term);
    try compare.expectEmptyText(allocator, child.stderr);
    return .{
        .result = .pass,
        .stdout = child.stdout,
        .profile = .{
            .kind = .executed,
            .duration_ns = elapsedNs(start),
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
    var tmp = try makeTmpDir(allocator);
    defer tmp.cleanup();

    const start = nowTimestamp();
    const manifest_path = try makeBackendOutputPath(allocator, tmp, "hybrid", ".khm");
    const result = try system.build(.{
        .source_path = case.source_path,
        .output_path = manifest_path,
        .target = .{ .execution = .hybrid },
    });
    if (result.failed() or result.diagnostics.len != 0) {
        return actualFromBuildOutcome(result, elapsedNs(start));
    }

    const runner = options.hybrid_runner_path orelse return error.MissingHybridRunner;
    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const child = try std.process.run(allocator, io_impl.io(), .{
        .argv = &.{ runner, manifest_path },
    });
    defer allocator.free(child.stderr);
    try expectExitedZero(child.term);
    try compare.expectEmptyText(allocator, child.stderr);
    return .{
        .result = .pass,
        .stdout = child.stdout,
        .profile = .{
            .kind = .executed,
            .duration_ns = elapsedNs(start),
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
        .stage = if (result.failure_stage) |stage| fromBuildStage(stage) else null,
        .profile = .{
            .kind = .executed,
            .duration_ns = duration_ns,
            .cache_status = result.cache_status,
            .cache_restore_ns = result.cache_restore_ns,
            .cache_store_ns = result.cache_store_ns,
        },
    };
}

fn findExecutable(artifacts: []const build_def.Artifact) ?build_def.Artifact {
    for (artifacts) |artifact| {
        if (artifact.kind == .executable) return artifact;
    }
    return null;
}

const TmpDir = struct {
    allocator: std.mem.Allocator,
    sub_path: []const u8,
    dir: std.Io.Dir,

    fn cleanup(self: *TmpDir) void {
        self.dir.close(std.Options.debug_io);
        std.Io.Dir.cwd().deleteTree(std.Options.debug_io, self.sub_path) catch {};
        self.allocator.free(self.sub_path);
    }
};

fn makeTmpDir(allocator: std.mem.Allocator) !TmpDir {
    var bytes: [8]u8 = undefined;
    std.Options.debug_io.random(&bytes);
    const suffix = std.mem.readInt(u64, &bytes, .little);
    const sub_path = try std.fmt.allocPrint(allocator, ".zig-cache/corpus-{x}", .{suffix});
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, sub_path);
    const dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, sub_path, .{});
    return .{ .allocator = allocator, .sub_path = sub_path, .dir = dir };
}

fn inheritedProcessEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        .wasi, .emscripten, .freestanding, .other => .empty,
        else => .{ .block = .{ .slice = currentPosixEnvironBlock() } },
    };
}

fn currentPosixEnvironBlock() [:null]const ?[*:0]const u8 {
    if (!builtin.link_libc) return &.{};

    const environ = std.c.environ;
    var len: usize = 0;
    while (environ[len] != null) : (len += 1) {}
    return environ[0..len :null];
}

fn buildOutputPath(allocator: std.mem.Allocator, tmp: TmpDir, backend: discovery.Backend) ![]const u8 {
    return switch (backend) {
        .vm => makeBackendOutputPath(allocator, tmp, "vm", ".kbc"),
        .llvm => makeBackendOutputPath(allocator, tmp, "llvm", build.executableExtension()),
        .hybrid => makeBackendOutputPath(allocator, tmp, "hybrid", ".khm"),
    };
}

fn makeBackendOutputPath(
    allocator: std.mem.Allocator,
    tmp: TmpDir,
    backend_name: []const u8,
    extension: []const u8,
) ![]const u8 {
    try tmp.dir.createDirPath(std.Options.debug_io, backend_name);
    const backend_root = try tmp.dir.realPathFileAlloc(std.Options.debug_io, backend_name, allocator);
    const file_name = try std.fmt.allocPrint(allocator, "main{s}", .{extension});
    return std.fs.path.join(allocator, &.{ backend_root, file_name });
}

fn expectExitedZero(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
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

fn backendLabel(
    allocator: std.mem.Allocator,
    case_name: []const u8,
    backend: discovery.Backend,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} [{s}]", .{ case_name, backendName(backend) });
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

fn phaseIndex(phase: discovery.Phase) usize {
    return switch (phase) {
        .check => 0,
        .build => 1,
        .run => 2,
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

const BufferedReporter = struct {
    output: std.Io.Writer.Allocating,
    passed: usize = 0,
    failed: usize = 0,
    write_error: ?anyerror = null,

    fn init(allocator: std.mem.Allocator) BufferedReporter {
        return .{ .output = .init(allocator) };
    }

    pub fn pass(self: *BufferedReporter, label: []const u8) void {
        self.passed += 1;
        self.print("PASS {s}\n", .{label});
    }

    pub fn fail(self: *BufferedReporter, label: []const u8, err: anyerror) void {
        self.failed += 1;
        self.print("FAIL {s}: {s}\n", .{ label, @errorName(err) });
    }

    fn print(self: *BufferedReporter, comptime fmt: []const u8, args: anytype) void {
        if (self.write_error != null) return;
        self.output.writer.print(fmt, args) catch |err| {
            self.write_error = err;
        };
    }

    fn writeTimingSummary(self: *BufferedReporter, case_name: []const u8, backend: discovery.Backend, profiles: *const [3]PhaseProfile) void {
        if (self.write_error != null) return;

        self.output.writer.print("TIME {s} [{s}]: ", .{ case_name, backendName(backend) }) catch |err| {
            self.write_error = err;
            return;
        };

        const phases = [_]discovery.Phase{ .check, .build, .run };
        for (phases, 0..) |phase, index| {
            if (index != 0) {
                self.output.writer.writeAll(", ") catch |err| {
                    self.write_error = err;
                    return;
                };
            }
            writePhaseProfile(&self.output.writer, phase, profiles[index]) catch |err| {
                self.write_error = err;
                return;
            };
        }

        self.output.writer.writeByte('\n') catch |err| {
            self.write_error = err;
        };
    }

    fn finish(self: *BufferedReporter) !JobReport {
        if (self.write_error) |err| return err;
        return .{
            .output = try self.output.toOwnedSlice(),
            .passed = self.passed,
            .failed = self.failed,
        };
    }
};

fn writePhaseProfile(writer: *std.Io.Writer, phase: discovery.Phase, profile: PhaseProfile) !void {
    try writer.print("{s}=", .{phaseName(phase)});
    switch (profile.kind) {
        .not_run => try writer.writeAll("not-run"),
        .assumed_pass => try writer.writeAll("assumed-pass"),
        .blocked => try writer.writeAll("blocked"),
        .executed => {
            try writeDuration(writer, profile.duration_ns);
            if (profile.cache_status != .not_checked) {
                try writer.writeAll(" cache=");
                try writer.writeAll(cacheStatusName(profile.cache_status));
                if (profile.cache_restore_ns != 0) {
                    try writer.writeAll("(restore=");
                    try writeDuration(writer, profile.cache_restore_ns);
                    try writer.writeByte(')');
                }
                if (profile.cache_store_ns != 0) {
                    try writer.writeAll("(store=");
                    try writeDuration(writer, profile.cache_store_ns);
                    try writer.writeByte(')');
                }
            }
        },
    }
}

fn writeDuration(writer: *std.Io.Writer, ns: u64) !void {
    if (ns >= std.time.ns_per_ms) {
        const whole = ns / std.time.ns_per_ms;
        const tenths = (ns % std.time.ns_per_ms) / (std.time.ns_per_ms / 10);
        if (tenths == 0) {
            try writer.print("{d}ms", .{whole});
        } else {
            try writer.print("{d}.{d}ms", .{ whole, tenths });
        }
        return;
    }
    if (ns >= std.time.ns_per_us) {
        const whole = ns / std.time.ns_per_us;
        try writer.print("{d}us", .{whole});
        return;
    }
    try writer.print("{d}ns", .{ns});
}

fn cacheStatusName(status: build.CacheStatus) []const u8 {
    return switch (status) {
        .not_checked => "none",
        .hit => "hit",
        .miss => "miss",
        .stored => "stored",
    };
}

fn nowTimestamp() std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
}

fn elapsedNs(start: std.Io.Clock.Timestamp) u64 {
    const duration_ns = start.durationTo(std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake)).raw.toNanoseconds();
    return @intCast(@max(duration_ns, 0));
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
