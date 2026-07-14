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

pub const TestReport = struct {
    passed: usize = 0,
    failed: usize = 0,
    total: usize = 0,

    pub fn add(self: *TestReport, other: TestReport) void {
        self.passed += other.passed;
        self.failed += other.failed;
        self.total += other.total;
    }
};

pub fn executeCompiledTests(allocator: std.mem.Allocator, result: build.ExecutablePipelineResult, writer: anytype) !TestReport {
    const module = result.bytecode_module orelse return error.MissingBytecodeArtifact;
    var vm = vm_runtime.Vm.init(std.heap.smp_allocator);
    defer vm.deinit();
    var ffi_dispatcher = vm_runtime.FfiDispatcher.init(std.heap.smp_allocator, &module);
    defer ffi_dispatcher.deinit();
    for (result.native_libraries) |library| try ffi_dispatcher.registerLibrary(library.name, library.artifact_path);

    var report = TestReport{};
    for (module.construct_implementations) |implementation| {
        if (!std.mem.eql(u8, implementation.construct_constraint.construct_name, "Test")) continue;
        report.total += 1;
        const test_name = try std.fmt.allocPrint(allocator, "{s}__test", .{implementation.type_name});
        const expect_name = try std.fmt.allocPrint(allocator, "{s}__expect", .{implementation.type_name});
        const test_function = decode.findFunctionByName(module, test_name) orelse {
            report.failed += 1;
            try writer.print("FAIL {s} (missing test artifact)\n", .{implementation.type_name});
            continue;
        };
        const expect_function = decode.findFunctionByName(module, expect_name) orelse {
            report.failed += 1;
            try writer.print("FAIL {s} (missing expect artifact)\n", .{implementation.type_name});
            continue;
        };
        const expected = vm.runFunctionById(&module, expect_function.id, &.{}, writer, .{
            .context = &ffi_dispatcher,
            .call_native = vm_runtime.FfiDispatcher.hook,
        }) catch |err| {
            report.failed += 1;
            try writer.print("FAIL {s} ({s})\n", .{ implementation.type_name, @errorName(err) });
            continue;
        };
        const expectation = decode.decodeTestExpectation(&vm, &module, expect_function.return_type, expected) catch |err| {
            report.failed += 1;
            try writer.print("FAIL {s} (invalid expected Result: {s})\n", .{ implementation.type_name, @errorName(err) });
            continue;
        };
        try executeOneTest(&report, &vm, &module, test_function, expectation, &ffi_dispatcher, writer, implementation.type_name);
    }
    return report;
}

/// Execute the synthesized pure-Kira test driver: run `__kira_test_main` (which
/// runs every Test, compares in Kira, and prints PASS/FAIL/SKIP) and tally its
/// output. No Zig comparison override — the suite ran as ordinary Kira.
pub fn executeViaDriver(allocator: std.mem.Allocator, result: build.ExecutablePipelineResult, writer: anytype) !TestReport {
    const module = result.bytecode_module orelse return error.MissingBytecodeArtifact;
    const driver = decode.findFunctionByName(module, "__kira_test_main") orelse return .{};

    var vm = vm_runtime.Vm.init(std.heap.smp_allocator);
    defer vm.deinit();
    var ffi_dispatcher = vm_runtime.FfiDispatcher.init(std.heap.smp_allocator, &module);
    defer ffi_dispatcher.deinit();
    for (result.native_libraries) |library| try ffi_dispatcher.registerLibrary(library.name, library.artifact_path);

    var captured: std.Io.Writer.Allocating = .init(allocator);
    defer captured.deinit();
    _ = vm.runFunctionById(&module, driver.id, &.{}, &captured.writer, .{
        .context = &ffi_dispatcher,
        .call_native = vm_runtime.FfiDispatcher.hook,
    }) catch |err| {
        try writer.print("FAIL <test-driver> ({s})\n", .{@errorName(err)});
        return .{ .failed = 1, .total = 1 };
    };

    var report = try tallyDriverOutput(allocator, captured.written(), writer, VmTrapChecker{
        .vm = &vm,
        .module = &module,
        .ffi_dispatcher = &ffi_dispatcher,
    });
    // Leak gate (KIRA_TEST_CHECK_LEAKS=1): after every Test in the suite has run
    // and dropped its locals, the VM heap and native-layout tallies must be back
    // to zero. A non-zero live count is a leak — fail the suite with a clear line.
    try gateVmLeaks(allocator, &vm, &report, writer);
    return report;
}

/// Append a leak failure to `report` when leak gating is on and `vm` still holds
/// live managed/native objects after a suite run. Preserves the legacy VM memory
/// report guarantee (`heap.count() == 0`).
fn gateVmLeaks(allocator: std.mem.Allocator, vm: *const vm_runtime.Vm, report: *TestReport, writer: anytype) !void {
    if (!leak.enabled()) return;
    const live = leak.vmLiveCount(vm);
    if (live == 0) return;
    report.failed += 1;
    report.total += 1;
    try writer.print("FAIL <leak-gate> ({d} live VM objects after tests: {s})\n", .{ live, leak.vmLeakSummary(allocator, vm) });
}

/// Parse the synthesized driver's PASS/FAIL/KTRAP lines into a TestReport.
/// PASS/FAIL lines are forwarded as-is. A `KTRAP <name>` line is a
/// trap-expectation test the driver could not run inline (a hard abort would
/// kill the whole driver): `trap_ctx.traps(allocator, name)` re-runs that test's
/// `test()` in isolation and reports whether it trapped — turning it into a real
/// PASS/FAIL. `trap_ctx` is backend-specific (VM or hybrid).
fn tallyDriverOutput(allocator: std.mem.Allocator, output: []const u8, writer: anytype, trap_ctx: anytype) !TestReport {
    var report = TestReport{};
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len == 0) continue;
        // Driver markers are NUL-prefixed (see synth_test_driver.zig). Anything
        // else is ordinary output the tests themselves printed onto the shared
        // stdout stream: forward it for visibility, but never count it as a
        // result (a test that printed "PASS x" must not become a passed test).
        if (raw_line[0] != 0) {
            try writer.print("{s}\n", .{raw_line});
            continue;
        }
        const line = raw_line[1..];
        if (std.mem.startsWith(u8, line, "KTRAP ")) {
            const name = line["KTRAP ".len..];
            const outcome = try trap_ctx.traps(allocator, name);
            if (outcome.trapped and outcome.message_matched) {
                report.passed += 1;
                try writer.print("PASS {s}\n", .{name});
            } else if (!outcome.trapped) {
                report.failed += 1;
                try writer.print("FAIL {s} (expected a runtime trap, but the test produced a value)\n", .{name});
            } else {
                report.failed += 1;
                try writer.print("FAIL {s} (trap message mismatch: expected to contain \"{s}\", got \"{s}\")\n", .{ name, outcome.expected, outcome.actual });
            }
        } else {
            try writer.print("{s}\n", .{line});
            if (std.mem.startsWith(u8, line, "PASS ")) {
                report.passed += 1;
            } else if (std.mem.startsWith(u8, line, "FAIL ")) {
                report.failed += 1;
            }
        }
    }
    report.total = report.passed + report.failed;
    return report;
}

/// The expected runtime-failure message for a trap test: run its `__expect()`
/// (pure Kira) and decode the `Result.Error(TestFailure ...)` payload. Returns
/// "" when there is no specific message to match (or anything fails to decode),
/// in which case any trap is accepted -- matching the legacy substring check's
/// empty-message case. The result is duped so it survives the subsequent
/// `__test()` run (which clobbers the VM's error buffer).
fn expectedTrapMessage(
    allocator: std.mem.Allocator,
    vm: *vm_runtime.Vm,
    module: *const bytecode.Module,
    name: []const u8,
    run_options: vm_runtime.Hooks,
) []const u8 {
    const expect_name = std.fmt.allocPrint(allocator, "{s}__expect", .{name}) catch return "";
    const expect_fn = decode.findFunctionByName(module.*, expect_name) orelse return "";
    var discard: std.Io.Writer.Allocating = .init(allocator);
    defer discard.deinit();
    const value = vm.runFunctionById(module, expect_fn.id, &.{}, &discard.writer, run_options) catch return "";
    const expectation = decode.decodeTestExpectation(vm, module, expect_fn.return_type, value) catch return "";
    return switch (expectation) {
        .expected_error => |expected_error| allocator.dupe(u8, expected_error.message) catch "",
        .ok => "",
    };
}

/// Same as `expectedTrapMessage`, but evaluates `<name>__expect()` THROUGH THE
/// HYBRID BRIDGE so an expect block that calls @Native/FFI runs correctly (the
/// embedded VM with empty hooks would otherwise abort or mis-evaluate it). The
/// resulting value is still a pure-Kira `Result`, so it decodes against the
/// runtime's own VM + module exactly as the pure-VM path does.
fn expectedTrapMessageHybrid(
    allocator: std.mem.Allocator,
    runtime: *hybrid_runtime.HybridRuntime,
    name: []const u8,
) []const u8 {
    const expect_name = std.fmt.allocPrint(allocator, "{s}__expect", .{name}) catch return "";
    const expect_fn = decode.findFunctionByName(runtime.module, expect_name) orelse return "";
    var discard: std.Io.Writer.Allocating = .init(allocator);
    defer discard.deinit();
    const value = runtime.runFunctionForValue(expect_fn.id, &discard.writer) catch return "";
    const expectation = decode.decodeTestExpectation(&runtime.vm, &runtime.module, expect_fn.return_type, value) catch return "";
    return switch (expectation) {
        .expected_error => |expected_error| allocator.dupe(u8, expected_error.message) catch "",
        .ok => "",
    };
}

/// Outcome of re-running a trap-expectation test's `test()` in isolation.
const TrapResult = struct {
    /// The test raised a runtime trap (the abort the driver could not catch).
    trapped: bool,
    /// The trap's message contained the expected substring, or no specific
    /// message was named. Only meaningful when `trapped`.
    message_matched: bool,
    actual: []const u8 = "",
    expected: []const u8 = "",
};

/// Re-runs a trap-expectation test's `test()` on the build-time VM and reports
/// whether it raised the expected runtime failure: it must trap, and (when the
/// test named a specific failure message) the trap's message must contain it, so
/// a divide-by-zero cannot satisfy a test that expected a "recursion" trap.
const VmTrapChecker = struct {
    vm: *vm_runtime.Vm,
    module: *const bytecode.Module,
    ffi_dispatcher: *vm_runtime.FfiDispatcher,

    fn traps(self: VmTrapChecker, allocator: std.mem.Allocator, name: []const u8) !TrapResult {
        const run_options = vm_runtime.Hooks{
            .context = self.ffi_dispatcher,
            .call_native = vm_runtime.FfiDispatcher.hook,
        };
        const expected = expectedTrapMessage(allocator, self.vm, self.module, name, run_options);
        const fn_name = try std.fmt.allocPrint(allocator, "{s}__test", .{name});
        const func = decode.findFunctionByName(self.module.*, fn_name) orelse return .{ .trapped = false, .message_matched = false };
        var discard: std.Io.Writer.Allocating = .init(allocator);
        defer discard.deinit();
        _ = self.vm.runFunctionById(self.module, func.id, &.{}, &discard.writer, run_options) catch {
            const actual = allocator.dupe(u8, self.vm.lastError() orelse "") catch "";
            return .{
                .trapped = true,
                .message_matched = expected.len == 0 or std.mem.indexOf(u8, actual, expected) != null,
                .actual = actual,
                .expected = expected,
            };
        };
        return .{ .trapped = false, .message_matched = false };
    }
};

/// Same, but re-runs the trap test through the hybrid runtime (so a trapping
/// @Native-bridged test is detected too). The expected-message check matches the
/// VM path: the trap must occur and, when a message was named, contain it. The
/// expected message is decoded by running `__expect()` THROUGH THE BRIDGE (so an
/// expect block that calls @Native/FFI evaluates correctly), and the actual trap
/// message comes from the runtime's VM error buffer.
const HybridTrapChecker = struct {
    runtime: *hybrid_runtime.HybridRuntime,

    fn traps(self: HybridTrapChecker, allocator: std.mem.Allocator, name: []const u8) !TrapResult {
        const expected = expectedTrapMessageHybrid(allocator, self.runtime, name);
        const fn_name = try std.fmt.allocPrint(allocator, "{s}__test", .{name});
        const fn_id = blk: {
            for (self.runtime.manifest.functions) |function| {
                if (std.mem.eql(u8, function.name, fn_name)) break :blk function.id;
            }
            return .{ .trapped = false, .message_matched = false };
        };
        var discard: std.Io.Writer.Allocating = .init(allocator);
        defer discard.deinit();
        self.runtime.runFunctionWithWriter(fn_id, &discard.writer) catch {
            const actual = allocator.dupe(u8, self.runtime.vm.lastError() orelse "") catch "";
            return .{
                .trapped = true,
                .message_matched = expected.len == 0 or std.mem.indexOf(u8, actual, expected) != null,
                .actual = actual,
                .expected = expected,
            };
        };
        return .{ .trapped = false, .message_matched = false };
    }
};

/// Run the pure-Kira test driver under the hybrid runtime so @Native/FFI calls
/// bridge: build the leaf for hybrid (with the driver + Test sections), load the
/// manifest, and invoke `__kira_test_main` through the bridge, capturing output.
pub fn executeViaHybridDriver(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    output_root: []const u8,
    project_root: []const u8,
    writer: anytype,
) !TestReport {
    const stem = std.fs.path.stem(source_path);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/{s}.test.khm", .{ output_root, stem });
    var system = build.BuildSystem.init(allocator);
    const outcome = try system.build(.{
        .source_path = source_path,
        .output_path = manifest_path,
        .target = .{ .execution = .hybrid },
        .test_mode = true,
        .synthesize_test_driver = true,
    });
    if (outcome.failed()) {
        if (outcome.source) |source| {
            try writeDiagnostics(writer, &source, outcome.diagnostics);
        }
        return .{ .failed = 1, .total = 1 };
    }
    const manifest_artifact = blk: {
        for (outcome.artifacts) |artifact| {
            if (artifact.kind == .hybrid_manifest) break :blk artifact;
        }
        return error.MissingHybridManifestArtifact;
    };
    const manifest = try hybrid_runtime.loadHybridModule(allocator, manifest_artifact.path);
    var runtime = try hybrid_runtime.HybridRuntime.init(allocator, manifest);
    defer runtime.deinit();

    const driver_id = blk: {
        for (manifest.functions) |function| {
            if (std.mem.eql(u8, function.name, "__kira_test_main")) break :blk function.id;
        }
        return .{}; // no tests
    };

    var captured: std.Io.Writer.Allocating = .init(allocator);
    defer captured.deinit();

    // Match `kira run`: relative file and asset paths are rooted at the leaf
    // package, not at whichever corpus parent launched `kira test`.
    var original_cwd = try std.Io.Dir.cwd().openDir(std.Options.debug_io, ".", .{});
    defer {
        std.process.setCurrentDir(std.Options.debug_io, original_cwd) catch {};
        original_cwd.close(std.Options.debug_io);
    }
    var project_dir = if (std.fs.path.isAbsolute(project_root))
        try std.Io.Dir.openDirAbsolute(std.Options.debug_io, project_root, .{})
    else
        try std.Io.Dir.cwd().openDir(std.Options.debug_io, project_root, .{});
    defer project_dir.close(std.Options.debug_io);
    try std.process.setCurrentDir(std.Options.debug_io, project_dir);

    runtime.runFunctionWithWriter(driver_id, &captured.writer) catch |err| {
        try writer.print("FAIL <test-driver> ({s})\n", .{@errorName(err)});
        return .{ .failed = 1, .total = 1 };
    };
    var report = try tallyDriverOutput(allocator, captured.written(), writer, HybridTrapChecker{ .runtime = &runtime });
    // Leak gate (KIRA_TEST_CHECK_LEAKS=1): the hybrid runtime's VM must be
    // heap/native-clean once every bridged Test has run and dropped.
    try gateVmLeaks(allocator, &runtime.vm, &report, writer);
    return report;
}

fn executeOneTest(
    report: *TestReport,
    vm: *vm_runtime.Vm,
    module: *const bytecode.Module,
    test_function: bytecode.Function,
    expectation: TestExpectation,
    ffi_dispatcher: *vm_runtime.FfiDispatcher,
    writer: anytype,
    type_name: []const u8,
) !void {
    switch (expectation) {
        .ok => |expected_value| {
            const actual = vm.runFunctionById(module, test_function.id, &.{}, writer, .{
                .context = ffi_dispatcher,
                .call_native = vm_runtime.FfiDispatcher.hook,
            }) catch |err| {
                report.failed += 1;
                try writer.print("FAIL {s} ({s})\n", .{ type_name, @errorName(err) });
                return;
            };
            if (decode.valuesEqual(module, expected_value, actual, test_function.return_type)) {
                report.passed += 1;
                try writer.print("PASS {s}\n", .{type_name});
            } else {
                report.failed += 1;
                try writer.print("FAIL {s} (value mismatch)\n", .{type_name});
            }
        },
        .expected_error => |expected_error| {
            _ = vm.runFunctionById(module, test_function.id, &.{}, writer, .{
                .context = ffi_dispatcher,
                .call_native = vm_runtime.FfiDispatcher.hook,
            }) catch |err| {
                if (err == error.RuntimeFailure) {
                    const actual_message = vm.lastError() orelse "";
                    if (expected_error.message.len == 0 or std.mem.indexOf(u8, actual_message, expected_error.message) != null) {
                        report.passed += 1;
                        try writer.print("PASS {s}\n", .{type_name});
                    } else {
                        report.failed += 1;
                        try writer.print("FAIL {s} (runtime error mismatch)\n", .{type_name});
                    }
                    return;
                }
                report.failed += 1;
                try writer.print("FAIL {s} ({s})\n", .{ type_name, @errorName(err) });
                return;
            };
            report.failed += 1;
            try writer.print("FAIL {s} (expected {s} error)\n", .{ type_name, expected_error.kind });
        },
    }
}

pub fn discoverTestLeaves(allocator: std.mem.Allocator, input_path: []const u8) ![]const []const u8 {
    if (!directoryExists(input_path) or isKiraAppPackage(input_path)) return allocator.dupe([]const u8, &.{input_path});
    var leaves = std.array_list.Managed([]const u8).init(allocator);
    try collectTestLeaves(allocator, input_path, &leaves);
    if (leaves.items.len == 0) return allocator.dupe([]const u8, &.{input_path});
    return leaves.toOwnedSlice();
}

fn collectTestLeaves(allocator: std.mem.Allocator, dir_path: []const u8, leaves: *std.array_list.Managed([]const u8)) !void {
    if (isKiraAppPackage(dir_path)) {
        try leaves.append(try allocator.dupe(u8, dir_path));
        return;
    }
    var dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);
    var iterator = dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .directory) continue;
        try collectTestLeaves(allocator, try std.fs.path.join(allocator, &.{ dir_path, entry.name }), leaves);
    }
}

fn isKiraAppPackage(path: []const u8) bool {
    if (!hasManifest(path)) return false;
    const app_path = std.fs.path.join(std.heap.page_allocator, &.{ path, "app" }) catch return false;
    defer std.heap.page_allocator.free(app_path);
    return directoryExists(app_path);
}

fn hasManifest(path: []const u8) bool {
    for ([_][]const u8{ "package.kira", "kira.toml", "project.toml", "Kira.toml" }) |name| {
        const manifest_path = std.fs.path.join(std.heap.page_allocator, &.{ path, name }) catch return false;
        defer std.heap.page_allocator.free(manifest_path);
        if (fileExists(manifest_path)) return true;
    }
    return false;
}

pub fn discoverExpectedDiagnostic(allocator: std.mem.Allocator, root_path: []const u8) !?[]const u8 {
    const app_path = try std.fs.path.join(allocator, &.{ root_path, "app" });
    if (!directoryExists(app_path)) return null;
    var dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, app_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);
    var iterator = dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".kira")) continue;
        const file_path = try std.fs.path.join(allocator, &.{ app_path, entry.name });
        const text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, allocator, .limited(2 * 1024 * 1024));
        if (extractKiraErrorCode(allocator, text)) |code| return code;
    }
    return null;
}

fn extractKiraErrorCode(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const start_marker = std.mem.indexOf(u8, text, "KiraError.") orelse return null;
    var end = start_marker + "KiraError.".len;
    const start = end;
    while (end < text.len and ((text[end] >= 'A' and text[end] <= 'Z') or (text[end] >= '0' and text[end] <= '9'))) : (end += 1) {}
    if (end == start) return null;
    return allocator.dupe(u8, text[start..end]) catch null;
}

pub fn firstErrorCode(items: []const diagnostics.Diagnostic) ?[]const u8 {
    for (items) |item| if (item.severity == .@"error") return item.code;
    return null;
}

/// True when the build failed because a package needs a native-capable backend
/// (its @Native/FFI packages cannot run on the VM) — diagnostic code KBE001.
pub fn isNativeBackendRequiredError(items: []const diagnostics.Diagnostic) bool {
    const code = firstErrorCode(items) orelse return false;
    return std.mem.eql(u8, code, "KBE001");
}

/// `--backend llvm` parity gate: prove the program codegens for native LLVM
/// using test-mode lowering (require_main = false + the synthesized driver), so
/// suites whose entrypoint is only `Test` declarations are validated through the
/// driver rather than the executable path. Returns a failing report (after
/// writing the diagnostic) when codegen fails, or null on success.
pub fn llvmTestParityFailure(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    pure_test: bool,
    display_path: []const u8,
    writer: anytype,
) !?TestReport {
    const llvm_result = try build.compileFileForBackendWithOptions(allocator, source_path, .llvm_native, null, &.{}, .{
        .allow_runtime_direct_ffi = true,
        .require_main = false,
        .test_mode = true,
        .synthesize_test_driver = pure_test,
    });
    if (llvm_result.failed()) {
        try writer.print("FAIL {s} (llvm backend parity: program does not codegen for llvm)\n", .{display_path});
        try writeDiagnostics(writer, &llvm_result.source, llvm_result.diagnostics);
        return TestReport{ .failed = 1, .total = 1 };
    }
    return null;
}

// Render `kira check`/`build`/`test` diagnostics. With the compiled source available, route through
// the shared diagnostics renderer so every error reports its `--> path:line:column` location and
// source snippet; without a source (no entrypoint resolved) fall back to a code/title/help summary.
pub fn writeDiagnostics(writer: anytype, source: ?*const source_pkg.SourceFile, items: []const diagnostics.Diagnostic) !void {
    if (source) |compiled_source| {
        try diagnostics.renderer.renderAll(writer, compiled_source, items);
        return;
    }
    for (items) |item| {
        const severity = switch (item.severity) {
            .@"error" => "error",
            .warning => "warning",
            .note => "note",
        };
        if (item.code) |code| try writer.print("{s}[{s}]: {s}\n", .{ severity, code, item.title }) else try writer.print("{s}: {s}\n", .{ severity, item.title });
        try writer.print("  {s}\n", .{item.message});
        if (item.help) |help| try writer.print("  help: {s}\n", .{help});
    }
}

fn fileExists(path: []const u8) bool {
    var file = if (std.fs.path.isAbsolute(path)) std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return false else std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}

fn directoryExists(path: []const u8) bool {
    var dir = if (std.fs.path.isAbsolute(path)) std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch return false else std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}

test "discoverTestLeaves accepts a manifest-free directory of packages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "corpus/one/app");
    try tmp.dir.createDirPath(std.testing.io, "corpus/two/app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "corpus/one/package.kira", .data = "Package One {}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "corpus/two/package.kira", .data = "Package Two {}\n" });
    const corpus = try tmp.dir.realPathFileAlloc(std.testing.io, "corpus", allocator);

    const leaves = try discoverTestLeaves(allocator, corpus);
    try std.testing.expectEqual(@as(usize, 2), leaves.len);
}
