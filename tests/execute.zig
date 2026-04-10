const std = @import("std");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const hybrid_runtime = @import("kira_hybrid_runtime");
const vm_runtime = @import("kira_vm_runtime");
const compare = @import("compare.zig");
const discovery = @import("discovery.zig");

pub const Options = struct {
    hybrid_runner_path: ?[]const u8 = null,
};

pub fn runCase(allocator: std.mem.Allocator, case: discovery.Case, reporter: anytype, options: Options) !void {
    var system = build.BuildSystem.init(allocator);
    switch (case.expectation.mode) {
        .check => try runCheck(allocator, &system, case, reporter),
        .run => try runExecutable(allocator, &system, case, reporter, options),
        .fail => try runFailure(allocator, &system, case, reporter),
    }
}

fn runCheck(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case, reporter: anytype) !void {
    _ = allocator;
    const result = system.check(case.source_path) catch |err| {
        reporter.fail(case.name, err);
        return err;
    };
    compare.expectNoDiagnostics(result) catch |err| {
        reporter.fail(case.name, err);
        return err;
    };
    reporter.pass(case.name);
}

fn runExecutable(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    reporter: anytype,
    options: Options,
) !void {
    if (case.expectation.backends.len == 0) return error.MissingBackendMatrix;
    const expected_stdout = case.expectation.stdout orelse return error.MissingStdoutExpectation;
    var baseline_stdout: ?[]u8 = null;
    defer if (baseline_stdout) |stdout| allocator.free(stdout);

    for (case.expectation.backends) |backend| {
        const label = try backendLabel(allocator, case.name, backend);
        const actual_stdout = switch (backend) {
            .vm => runVm(allocator, system, case) catch |err| {
                reporter.fail(label, err);
                return err;
            },
            .llvm => runLlvm(allocator, system, case) catch |err| {
                reporter.fail(label, err);
                return err;
            },
            .hybrid => runHybrid(allocator, system, case, options) catch |err| {
                reporter.fail(label, err);
                return err;
            },
        };
        const keep_stdout = baseline_stdout == null;
        defer if (!keep_stdout) allocator.free(actual_stdout);

        compare.expectStdout(allocator, actual_stdout, expected_stdout) catch |err| {
            reporter.fail(label, err);
            return err;
        };

        if (baseline_stdout) |baseline| {
            compare.expectStdout(allocator, actual_stdout, baseline) catch |err| {
                reporter.fail(label, err);
                return err;
            };
        } else {
            baseline_stdout = actual_stdout;
        }
        reporter.pass(label);
    }
}

fn runFailure(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case, reporter: anytype) !void {
    if (case.expectation.backends.len == 0) {
        const result = build.checkFile(allocator, case.source_path) catch |err| {
            reporter.fail(case.name, err);
            return err;
        };
        compare.expectDiagnostic(
            result.diagnostics,
            case.expectation.diagnostic_code orelse return error.MissingDiagnosticExpectation,
            case.expectation.diagnostic_title orelse return error.MissingDiagnosticExpectation,
        ) catch |err| {
            reporter.fail(case.name, err);
            return err;
        };
        if (case.expectation.stage) |stage| {
            compare.expectStage(result.failure_stage, stage) catch |err| {
                reporter.fail(case.name, err);
                return err;
            };
        }
        reporter.pass(case.name);
        return;
    }

    for (case.expectation.backends) |backend| {
        const label = try backendLabel(allocator, case.name, backend);
        switch (backend) {
            .vm => runVmFailure(allocator, system, case) catch |err| {
                reporter.fail(label, err);
                return err;
            },
            .llvm => runLlvmFailure(allocator, system, case) catch |err| {
                reporter.fail(label, err);
                return err;
            },
            .hybrid => runHybridFailure(allocator, system, case) catch |err| {
                reporter.fail(label, err);
                return err;
            },
        }
        reporter.pass(label);
    }
}

fn runVm(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) ![]u8 {
    const result = try system.compileVm(case.source_path);
    try std.testing.expect(!result.failed());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);

    var output = std.array_list.Managed(u8).init(allocator);

    var vm = vm_runtime.Vm.init(allocator);
    try vm.runMain(&result.bytecode_module.?, output.writer());
    return output.toOwnedSlice();
}

fn runVmFailure(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) !void {
    const result = try system.compileVm(case.source_path);
    try std.testing.expect(result.failed());
    try compare.expectDiagnostic(
        result.diagnostics,
        case.expectation.diagnostic_code orelse return error.MissingDiagnosticExpectation,
        case.expectation.diagnostic_title orelse return error.MissingDiagnosticExpectation,
    );
    if (case.expectation.stage) |stage| {
        try compare.expectStage(result.failure_stage, stage);
    }
    _ = allocator;
}

fn runLlvm(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) ![]u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try makeBackendOutputPath(allocator, tmp, "llvm", build.executableExtension());
    const result = try system.buildNativeArtifact(.{
        .source_path = case.source_path,
        .output_path = output_path,
        .target = .{ .execution = .llvm_native },
    });
    try std.testing.expect(!result.failed());
    try std.testing.expect(result.diagnostics.len == 0);

    const executable = findExecutable(result.artifacts) orelse return error.MissingExecutableArtifact;
    const child = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{executable.path},
    });
    defer allocator.free(child.stderr);
    try expectExitedZero(child.term);
    try compare.expectEmptyText(allocator, child.stderr);
    return child.stdout;
}

fn runLlvmFailure(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try makeBackendOutputPath(allocator, tmp, "llvm", build.executableExtension());
    const result = try system.buildNativeArtifact(.{
        .source_path = case.source_path,
        .output_path = output_path,
        .target = .{ .execution = .llvm_native },
    });
    try std.testing.expect(result.failed());
    try compare.expectDiagnostic(
        result.diagnostics,
        case.expectation.diagnostic_code orelse return error.MissingDiagnosticExpectation,
        case.expectation.diagnostic_title orelse return error.MissingDiagnosticExpectation,
    );
}

fn runHybrid(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    options: Options,
) ![]u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest_path = try makeBackendOutputPath(allocator, tmp, "hybrid", ".khm");
    const result = try system.buildHybridArtifact(.{
        .source_path = case.source_path,
        .output_path = manifest_path,
        .target = .{ .execution = .hybrid },
    });
    try std.testing.expect(!result.failed());
    try std.testing.expect(result.diagnostics.len == 0);

    const runner = options.hybrid_runner_path orelse return error.MissingHybridRunner;
    const child = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ runner, manifest_path },
    });
    defer allocator.free(child.stderr);
    try expectExitedZero(child.term);
    try compare.expectEmptyText(allocator, child.stderr);
    return child.stdout;
}

fn runHybridFailure(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest_path = try makeBackendOutputPath(allocator, tmp, "hybrid", ".khm");
    const result = try system.buildHybridArtifact(.{
        .source_path = case.source_path,
        .output_path = manifest_path,
        .target = .{ .execution = .hybrid },
    });
    try std.testing.expect(result.failed());
    try compare.expectDiagnostic(
        result.diagnostics,
        case.expectation.diagnostic_code orelse return error.MissingDiagnosticExpectation,
        case.expectation.diagnostic_title orelse return error.MissingDiagnosticExpectation,
    );
}

fn findExecutable(artifacts: []const build_def.Artifact) ?build_def.Artifact {
    for (artifacts) |artifact| {
        if (artifact.kind == .executable) return artifact;
    }
    return null;
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

fn backendLabel(allocator: std.mem.Allocator, case_name: []const u8, backend: discovery.Backend) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} [{s}]", .{ case_name, backendName(backend) });
}

fn backendName(backend: discovery.Backend) []const u8 {
    return switch (backend) {
        .vm => "vm",
        .llvm => "llvm",
        .hybrid => "hybrid",
    };
}
