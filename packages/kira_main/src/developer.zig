const std = @import("std");
const api = @import("api.zig");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const bytecode = @import("kira_bytecode");
const diagnostics = @import("kira_diagnostics");
const kira_project = @import("kira_project");
const source_pkg = @import("kira_source");
const runtime_abi = @import("kira_runtime_abi");
const vm_runtime = @import("kira_vm_runtime");
const hybrid_runtime = @import("kira_hybrid_runtime");
const wrappers = @import("runtime_wrappers.zig");
const failtest = @import("developer_failtest.zig");
const tests_config = @import("developer_tests_config.zig");
const manifest_pkg = @import("kira_manifest");
const decode = @import("developer_test_decode.zig");
const leak = @import("developer_leak.zig");
const parity = @import("developer_parity.zig");
const ProgressReport = @import("developer_progress_report.zig").ProgressReport;

const TestExpectation = decode.TestExpectation;
const ExpectedKiraError = decode.ExpectedKiraError;

/// Empty NUL-terminated C string returned when no report has been produced yet.
const empty_report: [:0]const u8 = "";

pub const DeveloperFacade = struct {
    arena: std.heap.ArenaAllocator,
    /// The report is an owned, heap-grown, NUL-terminated string rather than a
    /// fixed array: a manifest-driven backend matrix (e.g. tests-kik/harness on
    /// [vm, llvm, hybrid]) emits well over 64 KiB of PASS/CHECK lines. A fixed
    /// buffer silently truncated the tail — dropping the last backend leg's
    /// `test result [..]` line and the combined tally — which read as the run
    /// dying mid-output while exiting 0 (fake success). An owned buffer that
    /// grows to the exact output size can never truncate.
    report_owned: ?[:0]u8 = null,
    error_buffer: [1025]u8 = [_]u8{0} ** 1025,

    pub fn create() !*DeveloperFacade {
        const developer = try std.heap.c_allocator.create(DeveloperFacade);
        developer.* = .{
            .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        };
        return developer;
    }

    pub fn destroy(self: *DeveloperFacade) void {
        self.arena.deinit();
        if (self.report_owned) |owned| std.heap.c_allocator.free(owned);
        std.heap.c_allocator.destroy(self);
    }

    pub fn check(self: *DeveloperFacade, path: []const u8, backend: api.KiraDeveloperBackend) !bool {
        self.reset();
        build.setNativePreparationMode(.resolve_only);
        defer build.setNativePreparationMode(.full);

        const allocator = self.arena.allocator();
        const input = (try self.resolveInputForCommand(path)) orelse return false;
        const target_backend = selectedBackend(input, backend);
        var system = build.BuildSystem.init(allocator);
        const result = switch (input.target.target_kind) {
            .library => try system.checkPackageRoot(input.target.source_root.?),
            .executable, .example, .source_file => blk: {
                const source_path = input.target.source_path.?;
                // `kira check` is the public executable-validity contract: it runs the
                // executable-obligation verifier for the backend the program would build/run
                // with (explicit backend > project default > vm), not a frontend-only pass.
                // A program that passes `kira check --backend X` is guaranteed to clear the
                // executable phase gate for X, so build/run cannot later hit a lowering gap.
                const resolved_backend = target_backend orelse input.default_backend orelse .vm;
                break :blk try system.checkForBackend(source_path, resolved_backend);
            },
        };
        if (!diagnostics.hasErrors(result.diagnostics)) {
            try self.setReport("check passed\n");
            return true;
        }
        try self.setDiagnosticsReport(&result.source, result.diagnostics);
        return false;
    }

    pub fn buildPackage(self: *DeveloperFacade, path: []const u8, backend: api.KiraDeveloperBackend) !bool {
        self.reset();
        build.setNativePreparationMode(.artifacts_only);
        defer build.setNativePreparationMode(.full);

        const allocator = self.arena.allocator();
        const input = (try self.resolveInputForCommand(path)) orelse return false;
        const resolved_backend = selectedBackend(input, backend) orelse input.default_backend orelse .vm;
        var system = build.BuildSystem.init(allocator);
        if (input.target.target_kind == .library) {
            const result = try system.checkPackageRoot(input.target.source_root.?);
            if (diagnostics.hasErrors(result.diagnostics)) {
                try self.setDiagnosticsReport(&result.source, result.diagnostics);
                return false;
            }
            try self.setReportFmt("built library {s}\n", .{input.target.source_root.?});
            return true;
        }

        const source_path = input.target.source_path.?;
        const output_root = try outputRoot(allocator, input.target.root_path);
        try ensurePath(output_root);
        const output_path = try defaultOutputPath(
            allocator,
            output_root,
            input.target.project_name orelse std.fs.path.stem(source_path),
            resolved_backend,
        );
        const result = try system.build(.{
            .source_path = source_path,
            .output_path = output_path,
            .target = .{ .execution = resolved_backend },
        });
        if (result.failed()) {
            try self.setDiagnosticsReport(if (result.source) |*compiled_source| compiled_source else null, result.diagnostics);
            return false;
        }
        try self.setReport("Successfully built\n");
        return true;
    }

    pub fn testPackage(self: *DeveloperFacade, path: []const u8, backend: api.KiraDeveloperBackend) !bool {
        self.reset();
        // Test functions execute through the VM runner. The VM can additionally
        // dispatch into @Native packages when the leaf is built for hybrid, so
        // `--backend hybrid` (and a hybrid project default) is supported and lets
        // FFI / native-bridge code be exercised as Foundation `Test` declarations.
        // llvm/wasm produce a standalone native artifact rather than VM-runnable
        // Test functions, so they remain unsupported here.
        if (backend == .wasm32_emscripten) {
            try self.setReport("error[KCLI020]: unsupported test backend\n  kira test executes Test functions through the build-time VM; wasm is not supported.\n");
            return false;
        }
        build.setNativePreparationMode(.artifacts_only);
        defer build.setNativePreparationMode(.full);

        const allocator = self.arena.allocator();
        const leaves = try discoverTestLeaves(allocator, path);
        // A test root may be a directory of child packages (for example the
        // tests-kik corpus) with no manifest of its own. Preserve that flow,
        // while still rendering schema diagnostics when a root manifest exists
        // but is invalid.
        const root_input = self.resolveInputForCommand(path) catch |err| switch (err) {
            error.ProjectManifestNotFound => null,
            else => return err,
        };
        if (root_input == null and self.report_owned != null) return false;

        // Read the manifest `Tests { backends, phase }` config (best-effort). A
        // package without it keeps the historical single-backend behavior.
        const project_manifest: ?manifest_pkg.ProjectManifest = if (root_input) |input|
            if (input.target.project) |project| project.manifest else null
        else
            null;
        const plan = try tests_config.resolvePlan(allocator, project_manifest, backend);

        var full = ProgressReport.init(allocator);
        defer full.deinit();
        var aggregate = TestReport{};

        // Test declarations run once per planned backend (each must end 0-failed);
        // a manifest-driven matrix prints a per-backend tally.
        for (plan.backends) |entry| {
            var backend_report = TestReport{};
            for (leaves) |leaf| {
                if (leaves.len > 1) try full.writer.print("suite {s}\n", .{leaf});
                if (tests_config.runsCheck(plan.phase)) {
                    backend_report.add(try self.checkLeaf(leaf, entry.backend, &full.writer));
                }
                if (tests_config.runsExecute(plan.phase)) {
                    backend_report.add(try self.executeLeaf(leaf, entry.backend, &full.writer));
                }
            }
            if (plan.from_manifest) {
                try full.writer.print("test result [{s}]: {d} passed; {d} failed; {d} total\n", .{
                    entry.label, backend_report.passed, backend_report.failed, backend_report.total,
                });
            }
            aggregate.add(backend_report);
        }

        // FailTests are compiled once per their own declared backends, entirely
        // runner-side, and tallied into the same PASS/FAIL stream. They are
        // compile-time (so they still evaluate under the Check phase) and
        // backend-independent, so they run once rather than per planned backend.
        for (leaves) |leaf| {
            const ft = try failtest.runForLeaf(allocator, leaf, &full.writer);
            aggregate.add(.{ .passed = ft.passed, .failed = ft.failed, .total = ft.total });
        }

        // Cross-backend `@Main` stdout parity (KIRA_TEST_PARITY=1) and native
        // `@Main` leak check (KIRA_TEST_CHECK_LEAKS=1): only when the package
        // declares a `Tests { backends }` matrix AND carries an `@Main`. Replaces
        // the legacy corpus's exact-stdout-across-backends and native leaks
        // guarantees for the packages (harness, hybrid-bridge, string-primitives)
        // whose READMEs document the parity/leak run.
        if ((parity.enabled() or leak.enabled()) and plan.from_manifest) {
            const targets = try parityTargets(allocator, plan.backends);
            for (leaves) |leaf| {
                const input = resolveInput(allocator, leaf) catch continue;
                const source_path = input.target.source_path orelse continue;
                const root = input.target.root_path orelse ".";
                if (!parity.hasMain(allocator, root, source_path)) continue;
                const output_root = try outputRoot(allocator, input.target.root_path);
                try ensurePath(output_root);
                const skip_diff = parity.mainIsNative(allocator, root, source_path);
                const pr = try parity.run(allocator, source_path, input.target.root_path, output_root, targets, leak.enabled(), skip_diff, &full.writer);
                aggregate.add(.{ .passed = pr.passed, .failed = pr.failed, .total = pr.total });
            }
        }

        try full.writer.print("test result: {d} passed; {d} failed; {d} total\n", .{
            aggregate.passed,
            aggregate.failed,
            aggregate.total,
        });
        try self.setReport(full.written());
        return aggregate.failed == 0;
    }

    /// Check phase: compile/analyze a leaf's `Test` declarations for `backend`
    /// without executing their bodies. A clean compile counts as one pass; a
    /// compile failure counts as one fail and its diagnostics are written.
    fn checkLeaf(self: *DeveloperFacade, input_path: []const u8, backend: api.KiraDeveloperBackend, writer: anytype) !TestReport {
        const allocator = self.arena.allocator();
        const input = try resolveInput(allocator, input_path);
        const source_path = input.target.source_path orelse return error.ProjectEntrypointNotFound;
        const target = tests_config.checkTarget(backend);
        const result = try build.compileFileForBackendWithOptions(allocator, source_path, target, null, &.{}, .{
            .allow_runtime_direct_ffi = true,
            .require_main = false,
            .test_mode = true,
            .synthesize_test_driver = false,
        });
        if (result.failed()) {
            try writeDiagnostics(writer, &result.source, result.diagnostics);
            try writer.print("FAIL {s} (check)\n", .{input.target.displayPath()});
            return .{ .failed = 1, .total = 1 };
        }
        try writer.print("CHECK {s}\n", .{input.target.displayPath()});
        return .{ .passed = 1, .total = 1 };
    }

    pub fn report(self: *DeveloperFacade) [*:0]const u8 {
        if (self.report_owned) |owned| return owned.ptr;
        return empty_report.ptr;
    }

    pub fn lastError(self: *DeveloperFacade) [*:0]const u8 {
        return @ptrCast(&self.error_buffer);
    }

    fn executeLeaf(self: *DeveloperFacade, input_path: []const u8, backend: api.KiraDeveloperBackend, writer: anytype) !TestReport {
        const allocator = self.arena.allocator();
        const input = try resolveInput(allocator, input_path);
        const source_path = input.target.source_path orelse return error.ProjectEntrypointNotFound;
        const expected_diagnostic = try discoverExpectedDiagnostic(allocator, input.target.root_path orelse std.fs.path.dirname(source_path) orelse ".");
        // Test functions run on the VM. When `--backend hybrid` is explicitly
        // requested the leaf is compiled for hybrid so its @Native packages
        // produce native libraries the VM dispatches into, letting FFI /
        // native-bridge code be exercised as `Test` declarations. Bare `kira test`
        // stays on the VM (fast) regardless of the project's default backend.
        // Tests EXECUTE on the build-time VM (comptime; backend-independent), so
        // the verdict is identical on every backend. A non-vm `--backend` is a
        // parity check: the program must additionally compile/codegen for that
        // backend (verified below), but the test outcome itself is the single
        // build-time result. @Native packages can't build for vm, so they execute
        // under the hybrid bridge instead.
        const test_backend: build_def.ExecutionTarget = if (backend == .hybrid) .hybrid else .vm;
        // Default: the pure-Kira test driver — synthesize a Kira entry that runs
        // every Test, compares in Kira (`==`), and reports PASS/FAIL, with trap
        // tests re-run in isolation and checked for the abort. No Zig comparison
        // override. KIRA_LEGACY_TEST=1 falls back to the historical Zig runner.
        const pure_test = std.c.getenv("KIRA_LEGACY_TEST") == null;
        // Under hybrid the driver must run through the hybrid runtime so its
        // @Native/FFI calls bridge — which needs the linked native library only
        // the artifact build produces. Take the dedicated hybrid path.
        if (pure_test and backend == .hybrid) {
            const output_root = try outputRoot(allocator, input.target.root_path);
            try ensurePath(output_root);
            return executeViaHybridDriver(allocator, source_path, output_root, writer);
        }
        const result = try build.compileFileForBackendWithOptions(allocator, source_path, test_backend, null, &.{}, .{
            .allow_runtime_direct_ffi = true,
            .require_main = false,
            .test_mode = true,
            .synthesize_test_driver = pure_test,
        });
        if (result.failed()) {
            // A native-FFI suite's @Native packages cannot run on the VM, so its
            // verdict build fails with KBE001. Such a suite is inherently hybrid-
            // shaped (VM runtime + native bridge) and cannot be a pure native
            // LLVM executable, so the pure-LLVM codegen gate does not apply --
            // hybrid IS its native form. When a native-capable backend was
            // requested, run the (backend-independent) verdict through the hybrid
            // driver instead of reporting a spurious failure.
            if (expected_diagnostic == null and pure_test and backend == .llvm and
                isNativeBackendRequiredError(result.diagnostics))
            {
                const output_root = try outputRoot(allocator, input.target.root_path);
                try ensurePath(output_root);
                return executeViaHybridDriver(allocator, source_path, output_root, writer);
            }
            if (expected_diagnostic) |expected| {
                const actual = firstErrorCode(result.diagnostics) orelse "";
                if (std.mem.eql(u8, expected, actual)) {
                    try writer.print("PASS {s} (diagnostic {s})\n", .{ input.target.displayPath(), expected });
                    return .{ .passed = 1, .total = 1 };
                }
                try writer.print("FAIL {s} (wrong diagnostic: expected {s}, got {s})\n", .{ input.target.displayPath(), expected, if (actual.len == 0) "<none>" else actual });
                return .{ .failed = 1, .total = 1 };
            }
            try writeDiagnostics(writer, &result.source, result.diagnostics);
            return .{ .failed = 1, .total = 1 };
        }
        if (expected_diagnostic) |expected| {
            try writer.print("FAIL {s} (expected diagnostic {s}, but program succeeded)\n", .{ input.target.displayPath(), expected });
            return .{ .failed = 1, .total = 1 };
        }
        // Full backend parity: `--backend llvm` additionally proves the program
        // clears the LLVM executable phase gate (codegens for native). The test
        // verdict itself is the backend-independent build-time VM run below.
        if (backend == .llvm) {
            if (try llvmTestParityFailure(allocator, source_path, pure_test, input.target.displayPath(), writer)) |parity_failure| return parity_failure;
        }
        if (pure_test) return executeViaDriver(allocator, result, writer);
        return executeCompiledTests(allocator, result, writer);
    }

    fn setDiagnosticsReport(self: *DeveloperFacade, source: ?*const source_pkg.SourceFile, items: []const diagnostics.Diagnostic) !void {
        var output: std.Io.Writer.Allocating = .init(self.arena.allocator());
        defer output.deinit();
        try writeDiagnostics(&output.writer, source, items);
        try self.setReport(output.written());
    }

    fn resolveInputForCommand(self: *DeveloperFacade, path: []const u8) !?ResolvedInput {
        const allocator = self.arena.allocator();
        var manifest_diagnostics = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        defer manifest_diagnostics.deinit();
        const target = kira_project.resolveTargetFromPathWithDiagnostics(allocator, path, &manifest_diagnostics) catch |err| {
            if (err == error.DiagnosticsEmitted) {
                try self.setDiagnosticsReport(null, manifest_diagnostics.items);
                return null;
            }
            return err;
        };
        return .{
            .target = target,
            .default_backend = if (target.project) |project| parseExecutionTarget(project.manifest.execution_mode) catch null else null,
        };
    }

    fn setReportFmt(self: *DeveloperFacade, comptime fmt: []const u8, args: anytype) !void {
        var output: std.Io.Writer.Allocating = .init(self.arena.allocator());
        defer output.deinit();
        try output.writer.print(fmt, args);
        try self.setReport(output.written());
    }

    fn setReport(self: *DeveloperFacade, message: []const u8) !void {
        // Grow to the exact message size — never truncate. A truncated report
        // that drops a backend leg's result line is indistinguishable from a
        // crash and must never be presented as success.
        const owned = try std.heap.c_allocator.allocSentinel(u8, message.len, 0);
        @memcpy(owned[0..message.len], message);
        if (self.report_owned) |old| std.heap.c_allocator.free(old);
        self.report_owned = owned;
    }

    fn setError(self: *DeveloperFacade, message: []const u8) void {
        const length = @min(message.len, self.error_buffer.len - 1);
        @memcpy(self.error_buffer[0..length], message[0..length]);
        self.error_buffer[length] = 0;
        if (length + 1 < self.error_buffer.len) @memset(self.error_buffer[length + 1 ..], 0);
    }

    fn reset(self: *DeveloperFacade) void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        if (self.report_owned) |owned| {
            std.heap.c_allocator.free(owned);
            self.report_owned = null;
        }
        @memset(&self.error_buffer, 0);
    }
};

const ResolvedInput = struct {
    target: kira_project.ResolvedTarget,
    default_backend: ?build_def.ExecutionTarget = null,
};

const test_runtime = @import("developer_test_runtime.zig");
const TestReport = test_runtime.TestReport;
const executeCompiledTests = test_runtime.executeCompiledTests;
const executeViaDriver = test_runtime.executeViaDriver;
const executeViaHybridDriver = test_runtime.executeViaHybridDriver;
const discoverTestLeaves = test_runtime.discoverTestLeaves;
const discoverExpectedDiagnostic = test_runtime.discoverExpectedDiagnostic;
const firstErrorCode = test_runtime.firstErrorCode;
const isNativeBackendRequiredError = test_runtime.isNativeBackendRequiredError;
const llvmTestParityFailure = test_runtime.llvmTestParityFailure;
const writeDiagnostics = test_runtime.writeDiagnostics;

pub export fn kira_developer_create() callconv(.c) ?*DeveloperFacade {
    return DeveloperFacade.create() catch null;
}

pub export fn kira_developer_destroy(developer: ?*DeveloperFacade) callconv(.c) void {
    if (developer) |value| value.destroy();
}

pub export fn kira_developer_check(developer: ?*DeveloperFacade, path: ?[*:0]const u8, backend: api.KiraDeveloperBackend) callconv(.c) api.KiraStatus {
    return runDeveloperCommand(developer, path, backend, DeveloperFacade.check);
}

pub export fn kira_developer_build(developer: ?*DeveloperFacade, path: ?[*:0]const u8, backend: api.KiraDeveloperBackend) callconv(.c) api.KiraStatus {
    return runDeveloperCommand(developer, path, backend, DeveloperFacade.buildPackage);
}

pub export fn kira_developer_test(developer: ?*DeveloperFacade, path: ?[*:0]const u8, backend: api.KiraDeveloperBackend) callconv(.c) api.KiraStatus {
    return runDeveloperCommand(developer, path, backend, DeveloperFacade.testPackage);
}

pub export fn kira_developer_report(developer: ?*DeveloperFacade) callconv(.c) ?[*:0]const u8 {
    if (developer == null) return null;
    return developer.?.report();
}

pub export fn kira_developer_last_error(developer: ?*DeveloperFacade) callconv(.c) ?[*:0]const u8 {
    if (developer == null) return null;
    return developer.?.lastError();
}

fn runDeveloperCommand(
    developer: ?*DeveloperFacade,
    path: ?[*:0]const u8,
    backend: api.KiraDeveloperBackend,
    comptime command: fn (*DeveloperFacade, []const u8, api.KiraDeveloperBackend) anyerror!bool,
) api.KiraStatus {
    if (developer == null or path == null) return .fail;
    const ok = command(developer.?, wrappers.cStringSlice(path.?), backend) catch |err| {
        developer.?.setError(@errorName(err));
        return .fail;
    };
    return if (ok) .ok else .fail;
}

fn resolveInput(allocator: std.mem.Allocator, path: []const u8) !ResolvedInput {
    const target = try kira_project.resolveTargetFromPath(allocator, path);
    return .{
        .target = target,
        .default_backend = if (target.project) |project| parseExecutionTarget(project.manifest.execution_mode) catch null else null,
    };
}

fn selectedBackend(input: ResolvedInput, backend: api.KiraDeveloperBackend) ?build_def.ExecutionTarget {
    return switch (backend) {
        .default => input.default_backend,
        .vm => .vm,
        .llvm => .llvm_native,
        .hybrid => .hybrid,
        .wasm32_emscripten => .wasm32_emscripten,
    };
}

/// Map the resolved `kira test` backend matrix to execution targets for the
/// cross-backend `@Main` parity/leak run. `.default` resolves to vm; wasm is
/// dropped (its parity is the corpus wasm matrix's concern).
fn parityTargets(allocator: std.mem.Allocator, entries: []const tests_config.BackendEntry) ![]build_def.ExecutionTarget {
    var list = std.array_list.Managed(build_def.ExecutionTarget).init(allocator);
    for (entries) |entry| {
        const target: build_def.ExecutionTarget = switch (entry.backend) {
            .default, .vm => .vm,
            .llvm => .llvm_native,
            .hybrid => .hybrid,
            .wasm32_emscripten => continue,
        };
        try list.append(target);
    }
    return list.toOwnedSlice();
}

fn parseExecutionTarget(text: []const u8) !build_def.ExecutionTarget {
    if (std.mem.eql(u8, text, "vm")) return .vm;
    if (std.mem.eql(u8, text, "llvm") or std.mem.eql(u8, text, "llvm_native")) return .llvm_native;
    if (std.mem.eql(u8, text, "wasm") or std.mem.eql(u8, text, "wasm32-emscripten")) return .wasm32_emscripten;
    if (std.mem.eql(u8, text, "hybrid")) return .hybrid;
    return error.InvalidProjectExecutionMode;
}

fn outputRoot(allocator: std.mem.Allocator, project_root: ?[]const u8) ![]u8 {
    if (project_root) |root| return std.fs.path.join(allocator, &.{ root, ".kira-build" });
    return allocator.dupe(u8, ".kira-build");
}

fn ensurePath(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, path);
}

fn defaultOutputPath(allocator: std.mem.Allocator, output_root: []const u8, stem: []const u8, backend: build_def.ExecutionTarget) ![]const u8 {
    return switch (backend) {
        .vm => std.fmt.allocPrint(allocator, "{s}/{s}.kbc", .{ output_root, stem }),
        .llvm_native => std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ output_root, stem, build.executableExtension() }),
        .wasm32_emscripten => std.fmt.allocPrint(allocator, "{s}/{s}.js", .{ output_root, stem }),
        .hybrid => std.fmt.allocPrint(allocator, "{s}/{s}.khm", .{ output_root, stem }),
    };
}

test "developer facade checks and tests through C API boundary" {
    const developer = (kira_developer_create() orelse return error.CreateDeveloperFailed);
    defer kira_developer_destroy(developer);
    try std.testing.expectEqual(api.KiraStatus.ok, kira_developer_check(developer, "examples/hello", .vm));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(kira_developer_report(developer).?), "check passed") != null);
}
