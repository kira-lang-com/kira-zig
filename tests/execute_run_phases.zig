// Backend run-phase execution for the corpus runner: build + execute a case on
// vm (in-process), llvm (native child process, optional leak pass), and hybrid
// (runner child process). Split out of tests/execute.zig (Core Law #5); the
// phase orchestration/comparison driver stays there.
const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");
const vm_runtime = @import("kira_vm_runtime");
const compare = @import("compare.zig");
const discovery = @import("discovery.zig");
const leak_check = @import("leak_check.zig");
const reporting = @import("reporting.zig");
const support = @import("execute_support.zig");

const PhaseProfile = reporting.PhaseProfile;

pub const PhaseActual = struct {
    result: discovery.ExpectedResult,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    trace: ?[]const u8 = null,
    diagnostics: []const diagnostics.Diagnostic = &.{},
    stage: ?discovery.Stage = null,
    profile: PhaseProfile = .{},
};

pub fn actualFromBuildOutcome(result: build.BuildArtifactOutcome, duration_ns: u64) PhaseActual {
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

pub fn runVmPhase(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) !PhaseActual {
    support.process_state_lock.lock();
    defer support.process_state_lock.unlock();

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

pub fn runLlvmPhase(allocator: std.mem.Allocator, system: *build.BuildSystem, case: discovery.Case) !PhaseActual {
    support.process_state_lock.lockShared();
    defer support.process_state_lock.unlockShared();

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
    // Leak pass (expect.toml `check_leaks = true`, or KIRA_CORPUS_CHECK_LEAKS=1
    // for every runnable llvm case): the native binary must exit with zero
    // leaked allocations under macOS `leaks --atExit`.
    if (leak_check.enabledFor(case.expectation.check_leaks)) {
        const report = try leak_check.run(allocator, io_impl.io(), executable.path, run_cwd);
        if (report.leaked) {
            return .{
                .result = .fail,
                .stdout = child.stdout,
                .stderr = report.summary,
                .trace = try std.fmt.allocPrint(allocator, "llvm leak check failed:\n{s}", .{report.summary}),
                .profile = .{
                    .kind = .executed,
                    .duration_ns = support.elapsedNs(start),
                    .cache_status = result.cache_status,
                    .cache_restore_ns = result.cache_restore_ns,
                    .cache_store_ns = result.cache_store_ns,
                },
            };
        }
    }
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

pub fn runHybridPhase(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    case: discovery.Case,
    hybrid_runner_path: ?[]const u8,
) !PhaseActual {
    support.process_state_lock.lockShared();
    defer support.process_state_lock.unlockShared();

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

    const runner = hybrid_runner_path orelse return error.MissingHybridRunner;
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
