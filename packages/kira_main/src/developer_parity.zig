//! Cross-backend `@Main` stdout parity for `kira test` (env `KIRA_TEST_PARITY=1`).
//!
//! Replaces the legacy `tests/` corpus guarantee that a runnable case's stdout is
//! byte-identical across vm/llvm/hybrid. When a package declares a `Tests { backends }`
//! matrix AND carries an `@Main`, this executes that `@Main` once per matrix
//! backend, captures each stdout, and byte-diffs them; any divergence fails the
//! suite with a clear line naming the two backends and the first differing offset.
//!
//! When leak gating is also on (`KIRA_TEST_CHECK_LEAKS=1`), the native LLVM `@Main`
//! binary produced here is additionally run under macOS `leaks --atExit`, so the
//! native backend's drop elaboration proves itself (the VM live-count check in
//! developer_leak.zig cannot cover native lowering). This is the home of the
//! "parity + leak run" the harness/hybrid-bridge/string-primitives READMEs document.

const std = @import("std");
const builtin = @import("builtin");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const bytecode = @import("kira_bytecode");
const diagnostics = @import("kira_diagnostics");
const hybrid_runtime = @import("kira_hybrid_runtime");
const vm_runtime = @import("kira_vm_runtime");
const leak = @import("developer_leak.zig");

pub const Report = struct {
    passed: usize = 0,
    failed: usize = 0,
    total: usize = 0,
};

/// Whether `kira test` should run cross-backend `@Main` stdout parity. Opt-in via
/// `KIRA_TEST_PARITY` (any non-empty value other than "0"/"false").
pub fn enabled() bool {
    if (@import("builtin").link_libc == false) return false;
    const raw = std.c.getenv("KIRA_TEST_PARITY") orelse return false;
    const value = std.mem.span(raw);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

/// True when the package rooted at `root_path` declares an `@Main` (scans its
/// `app/*.kira`, or the single source file for a bare target). Textual, matching
/// how the runner already discovers a case's expected diagnostic.
pub fn hasMain(allocator: std.mem.Allocator, root_path: []const u8, source_path: ?[]const u8) bool {
    const app_path = std.fs.path.join(allocator, &.{ root_path, "app" }) catch return false;
    if (directoryExists(app_path)) {
        return dirHasMain(allocator, app_path);
    }
    const sp = source_path orelse return false;
    const text = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, sp, allocator, .limited(4 * 1024 * 1024)) catch return false;
    return std.mem.indexOf(u8, text, "@Main") != null;
}

/// True when the package's `@Main` is also `@Native` (annotations clustered on a
/// single function). A pure-native main prints through the native runtime's own
/// stdout, which the in-process hybrid run cannot capture, so its cross-backend
/// stdout byte-diff is skipped (the pass-differential is proven by the Tests
/// matrix + the captured llvm leg instead).
pub fn mainIsNative(allocator: std.mem.Allocator, root_path: []const u8, source_path: ?[]const u8) bool {
    const app_path = std.fs.path.join(allocator, &.{ root_path, "app" }) catch return false;
    if (directoryExists(app_path)) return dirMainIsNative(allocator, app_path);
    const sp = source_path orelse return false;
    const text = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, sp, allocator, .limited(4 * 1024 * 1024)) catch return false;
    return textMainIsNative(text);
}

fn dirMainIsNative(allocator: std.mem.Allocator, dir_path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(std.Options.debug_io);
    var iterator = dir.iterate();
    while (iterator.next(std.Options.debug_io) catch return false) |entry| {
        if (entry.kind == .directory) {
            const child = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
            if (dirMainIsNative(allocator, child)) return true;
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".kira")) continue;
        const file_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
        const text = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, allocator, .limited(4 * 1024 * 1024)) catch continue;
        if (textMainIsNative(text)) return true;
    }
    return false;
}

/// `@Main` and `@Native` annotate the same function when they sit in one
/// contiguous annotation run immediately before a `function`.
fn textMainIsNative(text: []const u8) bool {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, "@Main")) |idx| {
        search = idx + "@Main".len;
        // Walk forward to the next `function`; the intervening text must contain
        // only annotations/whitespace, and must include `@Native`.
        const fn_pos = std.mem.indexOfPos(u8, text, search, "function") orelse continue;
        const between = text[idx..fn_pos];
        if (std.mem.indexOf(u8, between, "@Native") != null) return true;
    }
    return false;
}

fn dirHasMain(allocator: std.mem.Allocator, dir_path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(std.Options.debug_io);
    var iterator = dir.iterate();
    while (iterator.next(std.Options.debug_io) catch return false) |entry| {
        if (entry.kind == .directory) {
            const child = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
            if (dirHasMain(allocator, child)) return true;
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".kira")) continue;
        const file_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
        const text = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, allocator, .limited(4 * 1024 * 1024)) catch continue;
        if (std.mem.indexOf(u8, text, "@Main") != null) return true;
    }
    return false;
}

const Capture = struct {
    label: []const u8,
    stdout: []const u8,
};

/// Run `@Main` across `backends`, byte-diff stdouts, and (when `check_leaks`)
/// run the native LLVM binary under `leaks --atExit`. Writes PASS/FAIL lines and
/// returns a tally to fold into the overall `kira test` result. `backends` comes
/// from the manifest `Tests { backends }` matrix.
pub fn run(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    root_path: ?[]const u8,
    output_root: []const u8,
    backends: []const build_def.ExecutionTarget,
    check_leaks: bool,
    skip_stdout_diff: bool,
    writer: anytype,
) !Report {
    var report = Report{};
    if (backends.len < 2 and !check_leaks) return report; // nothing to compare, nothing to leak-check
    // A native @Main's stdout is not capturable in-process, so its cross-backend
    // diff is skipped; the pass-differential is proven by the Tests matrix. Only
    // the (child-process, capturable) llvm leg still runs, for the native leak
    // check. With no leak check there is nothing left to do here.
    if (skip_stdout_diff) {
        if (!check_leaks) return report;
        try writer.print("NOTE <parity> (@Native @Main: stdout not capturable in-process; running llvm leg for the native leak check only)\n", .{});
    }

    var captures = std.array_list.Managed(Capture).init(allocator);
    for (backends) |backend| {
        if (backend == .wasm32_emscripten) continue; // wasm parity is the corpus wasm matrix's job
        if (skip_stdout_diff and backend != .llvm_native) continue;
        report.total += 1;
        const outcome = runOneBackend(allocator, source_path, root_path, output_root, backend, check_leaks, writer) catch |err| {
            report.failed += 1;
            try writer.print("FAIL <parity {s}> ({s})\n", .{ backendLabel(backend), @errorName(err) });
            continue;
        };
        switch (outcome) {
            .failed => report.failed += 1,
            .captured => |capture| {
                report.passed += 1;
                try captures.append(capture);
            },
        }
    }

    // Byte-diff every captured stdout against the first (unless the @Main is
    // @Native, whose native-side stdout the in-process hybrid run cannot see).
    if (!skip_stdout_diff and captures.items.len >= 2) {
        const baseline = captures.items[0];
        for (captures.items[1..]) |other| {
            if (firstDifference(baseline.stdout, other.stdout)) |offset| {
                report.failed += 1;
                report.total += 1;
                try writer.print(
                    "FAIL <parity {s} vs {s}> (stdout diverges at byte {d}: {s} has {d} bytes, {s} has {d} bytes)\n",
                    .{ baseline.label, other.label, offset, baseline.label, baseline.stdout.len, other.label, other.stdout.len },
                );
            } else {
                report.passed += 1;
                report.total += 1;
                try writer.print("PASS <parity {s} vs {s}> ({d} bytes identical)\n", .{ baseline.label, other.label, baseline.stdout.len });
            }
        }
    }
    return report;
}

const BackendOutcome = union(enum) {
    failed,
    captured: Capture,
};

fn runOneBackend(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    root_path: ?[]const u8,
    output_root: []const u8,
    backend: build_def.ExecutionTarget,
    check_leaks: bool,
    writer: anytype,
) !BackendOutcome {
    var system = build.BuildSystem.init(allocator);
    const output_path = try backendOutputPath(allocator, output_root, backend);
    const result = try system.build(.{
        .source_path = source_path,
        .output_path = output_path,
        .target = .{ .execution = backend },
    });
    if (result.failed()) {
        try writer.print("FAIL <parity {s}> (build failed)\n", .{backendLabel(backend)});
        if (result.source) |source| try renderDiagnostics(writer, &source, result.diagnostics);
        return .failed;
    }

    switch (backend) {
        .vm => return try runVm(allocator, &system, output_path, result, root_path, backendLabel(backend)),
        .hybrid => return try runHybrid(allocator, output_path, root_path, backendLabel(backend)),
        .llvm_native => return try runLlvm(allocator, result, root_path, check_leaks, backendLabel(backend), writer),
        .wasm32_emscripten => return .failed,
    }
}

fn runVm(
    allocator: std.mem.Allocator,
    system: *build.BuildSystem,
    output_path: []const u8,
    result: build.BuildArtifactOutcome,
    root_path: ?[]const u8,
    label: []const u8,
) !BackendOutcome {
    const module = try system.readBytecode(output_path);
    var vm = vm_runtime.Vm.init(std.heap.smp_allocator);
    defer vm.deinit();
    var ffi_dispatcher = vm_runtime.FfiDispatcher.init(std.heap.smp_allocator, &module);
    defer ffi_dispatcher.deinit();
    for (result.native_libraries) |library| try ffi_dispatcher.registerLibrary(library.name, library.artifact_path);

    var restore = try ScopedCwd.enter(root_path);
    defer restore.exit();

    var captured: std.Io.Writer.Allocating = .init(allocator);
    try vm.runMainWithHooks(&module, &captured.writer, .{
        .context = &ffi_dispatcher,
        .call_native = vm_runtime.FfiDispatcher.hook,
    });
    return .{ .captured = .{ .label = label, .stdout = try captured.toOwnedSlice() } };
}

fn runHybrid(
    allocator: std.mem.Allocator,
    output_path: []const u8,
    root_path: ?[]const u8,
    label: []const u8,
) !BackendOutcome {
    const manifest = try hybrid_runtime.loadHybridModule(allocator, output_path);
    var runtime = try hybrid_runtime.HybridRuntime.init(allocator, manifest);
    defer runtime.deinit();

    var restore = try ScopedCwd.enter(root_path);
    defer restore.exit();

    var captured: std.Io.Writer.Allocating = .init(allocator);
    try runtime.runWithWriter(&captured.writer);
    return .{ .captured = .{ .label = label, .stdout = try captured.toOwnedSlice() } };
}

fn runLlvm(
    allocator: std.mem.Allocator,
    result: build.BuildArtifactOutcome,
    root_path: ?[]const u8,
    check_leaks: bool,
    label: []const u8,
    writer: anytype,
) !BackendOutcome {
    const executable = findExecutable(result.artifacts) orelse return error.MissingExecutableArtifact;
    const run_cwd = root_path orelse ".";
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = inheritedProcessEnviron() });
    defer io_impl.deinit();
    const child = try std.process.run(allocator, io_impl.io(), .{
        .argv = &.{executable.path},
        .cwd = .{ .path = run_cwd },
    });
    defer allocator.free(child.stderr);
    if (!exitedZero(child.term)) {
        defer allocator.free(child.stdout);
        try writer.print("FAIL <parity {s}> (native binary {s})\n", .{ label, termDescription(child.term) });
        if (child.stdout.len != 0) try writer.print("native stdout:\n{s}\n", .{child.stdout});
        if (child.stderr.len != 0) try writer.print("native stderr:\n{s}\n", .{child.stderr});
        return .failed;
    }

    // Native leaks --atExit: the LLVM binary's drop elaboration must leave zero
    // leaked allocations. macOS-only; skipped elsewhere (not faked).
    if (check_leaks and leak.nativeLeaksSupported()) {
        const leak_report = try leak.runNativeLeaks(allocator, io_impl.io(), executable.path, run_cwd);
        if (leak_report.leaked) {
            try writer.print("FAIL <leak {s}> (native leaks detected)\n{s}\n", .{ label, leak_report.summary });
            return .failed;
        }
        try writer.print("PASS <leak {s}> ({s})\n", .{ label, leak_report.summary });
    }
    return .{ .captured = .{ .label = label, .stdout = child.stdout } };
}

/// Restores the process cwd on exit; sets it to `root` while alive. `kira test`
/// is single-threaded per invocation, so a scoped chdir is safe here.
const ScopedCwd = struct {
    original: ?std.Io.Dir = null,

    fn enter(root: ?[]const u8) !ScopedCwd {
        const dir = root orelse return .{};
        var original = try std.Io.Dir.cwd().openDir(std.Options.debug_io, ".", .{});
        var target = std.Io.Dir.openDirAbsolute(std.Options.debug_io, dir, .{}) catch {
            original.close(std.Options.debug_io);
            return .{};
        };
        defer target.close(std.Options.debug_io);
        try std.process.setCurrentDir(std.Options.debug_io, target);
        return .{ .original = original };
    }

    fn exit(self: *ScopedCwd) void {
        if (self.original) |*original| {
            std.process.setCurrentDir(std.Options.debug_io, original.*) catch {};
            original.close(std.Options.debug_io);
        }
    }
};

fn firstDifference(a: []const u8, b: []const u8) ?usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return i;
    }
    if (a.len != b.len) return n;
    return null;
}

fn backendOutputPath(allocator: std.mem.Allocator, output_root: []const u8, backend: build_def.ExecutionTarget) ![]const u8 {
    return switch (backend) {
        .vm => std.fmt.allocPrint(allocator, "{s}/parity-main.kbc", .{output_root}),
        .llvm_native => std.fmt.allocPrint(allocator, "{s}/parity-main{s}", .{ output_root, build.executableExtension() }),
        .hybrid => std.fmt.allocPrint(allocator, "{s}/parity-main.khm", .{output_root}),
        .wasm32_emscripten => std.fmt.allocPrint(allocator, "{s}/parity-main.js", .{output_root}),
    };
}

fn backendLabel(backend: build_def.ExecutionTarget) []const u8 {
    return switch (backend) {
        .vm => "vm",
        .llvm_native => "llvm",
        .hybrid => "hybrid",
        .wasm32_emscripten => "wasm",
    };
}

fn findExecutable(artifacts: []const build_def.Artifact) ?build_def.Artifact {
    for (artifacts) |artifact| if (artifact.kind == .executable) return artifact;
    return null;
}

fn exitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn termDescription(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => |code| if (code == 0) "exited successfully" else switch (code) {
            1 => "exited with code 1",
            2 => "exited with code 2",
            3 => "exited with code 3",
            else => "exited with a non-zero code",
        },
        .signal => "terminated by a signal",
        .stopped => "stopped by a signal",
        .unknown => "terminated for an unknown reason",
    };
}

fn directoryExists(path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
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

fn renderDiagnostics(writer: anytype, source: anytype, items: []const diagnostics.Diagnostic) !void {
    diagnostics.renderer.renderAll(writer, source, items) catch {};
}

test "firstDifference finds the first divergent byte and length mismatch" {
    try std.testing.expectEqual(@as(?usize, null), firstDifference("abc", "abc"));
    try std.testing.expectEqual(@as(?usize, 1), firstDifference("abc", "aXc"));
    try std.testing.expectEqual(@as(?usize, 3), firstDifference("abc", "abcd"));
}

test "native parity termination descriptions preserve common exit codes" {
    try std.testing.expectEqualStrings("exited successfully", termDescription(.{ .exited = 0 }));
    try std.testing.expectEqualStrings("exited with code 1", termDescription(.{ .exited = 1 }));
    try std.testing.expectEqualStrings("terminated for an unknown reason", termDescription(.{ .unknown = 9 }));
}
