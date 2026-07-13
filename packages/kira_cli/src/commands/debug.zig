//! `kira debug` — build a runnable target and drive it under Kira's source-level
//! debugger (`kira_debug`). This command owns only the CLI-facing concerns:
//! argument shape, the real build → artifact-load → runtime-init path (identical
//! to `run.zig`, so layers 1-3 — build success, module load, runtime startup —
//! are genuine and shared), and then handing the live runtime to `kira_debug`'s
//! backend-agnostic debug session. All actual debugger behavior (breakpoints,
//! stepping, frame/local inspection, expression evaluation, DAP framing) lives in
//! `kira_debug`, keeping the CLI a leaf (AGENTS.md layering).
//!
//! Two front-ends over the same `DebugSession`:
//!   - default: an interactive terminal REPL (`kira_debug.Repl`).
//!   - `--dap`: the Debug Adapter Protocol server (`kira_debug.dap.Server`) an
//!     editor speaks; stdio transport by default, TCP with `--port`.
//!
//! Backend parity: the VM path debugs bytecode in-process; `--backend llvm` and
//! `--backend hybrid` build the native/hybrid artifact and drive it under the
//! hardware-assisted / hybrid debug targets. No backend fakes a stop — an
//! unsupported request surfaces a `kira_debug` limitation, never a smoke marker.
const std = @import("std");
const bytecode = @import("kira_bytecode");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const diag_messages = @import("kira_diagnostic_messages");
const diagnostics = @import("kira_diagnostics");
const package_manager = @import("kira_package_manager");
const vm_runtime = @import("kira_vm_runtime");
const kira_debug = @import("kira_debug");
const support = @import("../support.zig");

const ParsedArgs = struct {
    backend: ?build_def.ExecutionTarget = null,
    dap: bool = false,
    port: ?u16 = null,
    input_path: []const u8,
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);

    // Artifacts-only native prep mirrors `run`: we build the same artifacts the
    // runtime consumes, but skip full packaging the debugger does not need.
    build.setNativePreparationMode(.artifacts_only);
    defer build.setNativePreparationMode(.full);

    const input = support.resolveCliInput(allocator, parsed.input_path) catch |err| switch (err) {
        error.InvalidProjectPath => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.invalidProjectPath(allocator, parsed.input_path));
            return error.CommandFailed;
        },
        error.ProjectManifestNotFound => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.PackageMessages.missingProjectManifest(allocator, parsed.input_path));
            return error.CommandFailed;
        },
        else => return err,
    };
    // Debugging requires a runnable target, so reuse the `run` selection rules
    // (libraries and non-runnable roots are rejected with the same diagnostics).
    try support.validateTargetSelection(allocator, stderr, .run, input);
    const backend = parsed.backend orelse input.default_backend orelse .vm;
    const source_path = input.target.source_path.?;

    if (input.target.root_path) |project_root| {
        var package_diagnostics = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
        _ = package_manager.syncProject(allocator, project_root, support.versionString(), .{
            .offline = false,
            .locked = false,
        }, &package_diagnostics) catch |err| {
            if (err == error.DiagnosticsEmitted) {
                try support.renderStandaloneDiagnostics(stderr, package_diagnostics.items);
                return error.CommandFailed;
            }
            return err;
        };
    }
    try support.warnNativePreparationState(allocator, stderr, "debug", input, backend);

    try support.logFrontendStarted(stderr, "debug", source_path);
    var system = build.BuildSystem.init(allocator);
    const output_root = try support.outputRoot(allocator, input.target.root_path);
    defer allocator.free(output_root);
    try support.ensurePath(output_root);
    const stem = input.target.project_name orelse std.fs.path.stem(source_path);
    const output_path = try debugOutputPath(allocator, output_root, stem, backend);
    const result = try system.build(.{
        .source_path = source_path,
        .output_path = output_path,
        .target = .{ .execution = backend },
    });
    if (result.failed()) {
        try support.logBuildAborted(stderr, "debug", result.failure_kind.?, source_path);
        if (result.source) |source| {
            try support.renderDiagnostics(stderr, &source, result.diagnostics);
        }
        return error.CommandFailed;
    }

    switch (backend) {
        .vm => try debugVm(result, input.target.root_path, parsed, stdout, stderr),
        .llvm_native => try debugNative(allocator, result, input.target.root_path, parsed, stdout, stderr),
        .hybrid => try debugHybrid(allocator, result, input.target.root_path, parsed, stdout, stderr),
        .wasm32_emscripten => {
            // The wasm32-emscripten runtime runs inside a browser/node sandbox
            // with no in-process debug target here; reject clearly rather than
            // pretend to attach.
            try stderr.writeAll("kira debug: the wasm32-emscripten backend is not debuggable in-process; debug with vm, llvm, or hybrid.\n");
            return error.CommandFailed;
        },
    }
}

/// VM backend: load the bytecode module the build produced, initialize the VM in
/// the project's working directory (identical to `run`), then wrap it in a
/// `kira_debug.VmTarget` and drive a REPL or DAP session over that target.
fn debugVm(
    result: build.BuildArtifactOutcome,
    project_root: ?[]const u8,
    parsed: ParsedArgs,
    stdout: anytype,
    stderr: anytype,
) !void {
    const bytecode_artifact = findBytecode(result.artifacts) orelse return error.MissingBytecodeArtifact;
    const runtime_allocator = std.heap.smp_allocator;
    var module = try bytecode.Module.readFromFile(runtime_allocator, bytecode_artifact.path);
    var vm = vm_runtime.Vm.init(runtime_allocator);
    defer vm.deinit();

    var original_cwd = try std.Io.Dir.cwd().openDir(std.Options.debug_io, ".", .{});
    defer {
        if (project_root) |_| std.process.setCurrentDir(std.Options.debug_io, original_cwd) catch {};
        original_cwd.close(std.Options.debug_io);
    }
    if (project_root) |root| {
        var dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, root, .{});
        defer dir.close(std.Options.debug_io);
        try std.process.setCurrentDir(std.Options.debug_io, dir);
    }

    // Native FFI must work under the debugger exactly as it does under `run`
    // (backend parity), so wire the same dispatcher + hook the VM uses live.
    var ffi_dispatcher = vm_runtime.FfiDispatcher.init(runtime_allocator, &module);
    defer ffi_dispatcher.deinit();
    for (result.native_libraries) |library| {
        try ffi_dispatcher.registerLibrary(library.name, library.artifact_path);
    }

    // The VM debug target owns stepping/breakpoint control over the loaded module
    // and VM. It exposes the shared `DebugTarget` vtable the session drives. The
    // DAP stdout is a framed protocol transport, so raw debuggee bytes must not
    // share it. Until DAP output events are supported, route program output to
    // stderr; the interactive REPL continues to render it on stdout.
    const program_output = if (parsed.dap) stderr else stdout;
    var vm_target = kira_debug.VmTarget.init(runtime_allocator, &vm, &module, program_output, .{
        .context = &ffi_dispatcher,
        .call_native = vm_runtime.FfiDispatcher.hook,
    });
    defer vm_target.deinit();

    var session = kira_debug.DebugSession.init(runtime_allocator, vm_target.target());
    defer session.deinit();

    try driveSession(runtime_allocator, &session, parsed, stdout, stderr);
}

/// Native (LLVM) backend: the debug target attaches to the freshly built
/// executable under the hardware-assisted controller. We do not fake a stop — the
/// target reports real stops (or a clear hardware-unavailable limitation).
fn debugNative(
    allocator: std.mem.Allocator,
    result: build.BuildArtifactOutcome,
    project_root: ?[]const u8,
    parsed: ParsedArgs,
    stdout: anytype,
    stderr: anytype,
) !void {
    const executable = findExecutable(result.artifacts) orelse return error.MissingExecutableArtifact;
    try stderr.print("native debug: launching {s} under the hardware debugger\n", .{executable.path});

    // The native target duplicates argv internally; argv[0] is the executable it
    // launches and reads DWARF/symbols from. The debuggee inherits this process's
    // cwd. Keep the project root active for the full session so programs that
    // open relative assets behave exactly as they do under `kira run`.
    var original_cwd = try std.Io.Dir.cwd().openDir(std.Options.debug_io, ".", .{});
    defer {
        if (project_root) |_| std.process.setCurrentDir(std.Options.debug_io, original_cwd) catch {};
        original_cwd.close(std.Options.debug_io);
    }
    if (project_root) |root| {
        var dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, root, .{});
        defer dir.close(std.Options.debug_io);
        try std.process.setCurrentDir(std.Options.debug_io, dir);
    }
    const argv = [_][]const u8{executable.path};
    // The debugger shells out to `llvm-dwarfdump`/`llvm-nm` to resolve source
    // lines and symbols. The managed LLVM toolchain (what the build just used)
    // is not on `PATH`, so hand the native target the same bin dir the build
    // resolved; without it every `break FILE:LINE` fails with NotFound.
    const tool_dir = build.llvmToolDir(allocator);
    defer if (tool_dir) |dir| allocator.free(dir);
    var native_target = try kira_debug.NativeTarget.initWithToolDir(allocator, &argv, tool_dir);
    defer native_target.deinit();

    var session = kira_debug.DebugSession.init(allocator, native_target.target());
    defer session.deinit();

    try driveSession(allocator, &session, parsed, stdout, stderr);
}

/// Hybrid backend: `kira_debug.HybridTarget` composes a VM sub-target (runtime-bodied
/// functions) with a native sub-target (native-bodied functions) over one inferior,
/// so a single session steps across the boundary. Constructing the VM sub-target for
/// hybrid requires the hybrid runtime's in-process native-dispatch hooks
/// (`RuntimeContext`/`nativeCallHook`), which `kira_hybrid_runtime` does not yet
/// expose. Until those are surfaced, we reject clearly rather than attach a
/// half-composed target that would fail on the first VM<->native crossing — an honest
/// limitation, never a smoke stop.
fn debugHybrid(
    allocator: std.mem.Allocator,
    result: build.BuildArtifactOutcome,
    project_root: ?[]const u8,
    parsed: ParsedArgs,
    stdout: anytype,
    stderr: anytype,
) !void {
    _ = allocator;
    _ = project_root;
    _ = parsed;
    _ = stdout;
    // Ground the diagnostic in the real artifact: a missing manifest is a distinct,
    // more precise failure than the unsupported-composition case below.
    const manifest_artifact = findHybridManifest(result.artifacts) orelse return error.MissingHybridManifestArtifact;
    try stderr.print(
        "kira debug: hybrid debugging is not yet available from the CLI (manifest {s} built successfully). " ++
            "The hybrid debug target exists but composing its VM sub-target needs the hybrid runtime's " ++
            "in-process native-dispatch hooks, which are not yet exported; debug with --backend vm or llvm.\n",
        .{manifest_artifact.path},
    );
    return error.CommandFailed;
}

/// Pick the front-end for a constructed session: DAP server for editor clients, or
/// the interactive terminal REPL. Both drive the same backend-agnostic session.
fn driveSession(
    allocator: std.mem.Allocator,
    session: *kira_debug.DebugSession,
    parsed: ParsedArgs,
    stdout: anytype,
    stderr: anytype,
) !void {
    if (parsed.dap) {
        if (parsed.port != null) {
            // TCP DAP transport requires a listener/accept loop that is not yet
            // wired; reject clearly rather than silently ignore `--port`.
            try stderr.writeAll("kira debug --dap --port: TCP DAP transport is not yet available; omit --port to serve DAP over stdio.\n");
            return error.CommandFailed;
        }
        try serveDapStdio(allocator, session, stdout);
        return;
    }
    try runRepl(allocator, session, stdout, stderr);
}

/// Serve the Debug Adapter Protocol over stdio: editors launch `kira debug --dap`
/// as a child process and speak DAP on its stdin/stdout.
fn serveDapStdio(allocator: std.mem.Allocator, session: *kira_debug.DebugSession, stdout: anytype) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(std.Options.debug_io, &stdin_buffer);
    var server = kira_debug.dap.Server.init(allocator, &stdin_reader.interface, stdout, session.handler());
    try server.run();
}

/// Run the interactive terminal REPL against a session, reading commands from
/// stdin and rendering stops/frames/values to stdout/stderr.
fn runRepl(allocator: std.mem.Allocator, session: *kira_debug.DebugSession, stdout: anytype, stderr: anytype) !void {
    _ = stderr; // The REPL renders errors inline to its single output writer.
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(std.Options.debug_io, &stdin_buffer);
    try kira_debug.Repl.run(allocator, session.replSession(), &stdin_reader.interface, stdout);
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var backend: ?build_def.ExecutionTarget = null;
    var dap = false;
    var port: ?u16 = null;
    var input_path: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--backend")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            backend = parseBackend(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dap")) {
            dap = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            port = std.fmt.parseInt(u16, args[index], 10) catch return error.InvalidArguments;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
        if (input_path != null) return error.InvalidArguments;
        input_path = arg;
    }

    return .{
        .backend = backend,
        .dap = dap,
        .port = port,
        .input_path = input_path orelse support.defaultCommandInputPath(),
    };
}

fn parseBackend(arg: []const u8) ?build_def.ExecutionTarget {
    if (std.mem.eql(u8, arg, "vm")) return .vm;
    if (std.mem.eql(u8, arg, "llvm")) return .llvm_native;
    if (std.mem.eql(u8, arg, "hybrid")) return .hybrid;
    if (std.mem.eql(u8, arg, "wasm") or std.mem.eql(u8, arg, "wasm32-emscripten")) return .wasm32_emscripten;
    return null;
}

fn findExecutable(artifacts: []const build_def.Artifact) ?build_def.Artifact {
    for (artifacts) |artifact| {
        if (artifact.kind == .executable) return artifact;
    }
    return null;
}

fn findBytecode(artifacts: []const build_def.Artifact) ?build_def.Artifact {
    for (artifacts) |artifact| {
        if (artifact.kind == .bytecode) return artifact;
    }
    return null;
}

fn findHybridManifest(artifacts: []const build_def.Artifact) ?build_def.Artifact {
    for (artifacts) |artifact| {
        if (artifact.kind == .hybrid_manifest) return artifact;
    }
    return null;
}

fn debugOutputPath(allocator: std.mem.Allocator, output_root: []const u8, stem: []const u8, backend: build_def.ExecutionTarget) ![]const u8 {
    return switch (backend) {
        .vm => std.fmt.allocPrint(allocator, "{s}/{s}.debug.kbc", .{ output_root, stem }),
        .llvm_native => std.fmt.allocPrint(allocator, "{s}/{s}.debug{s}", .{ output_root, stem, build.executableExtension() }),
        .wasm32_emscripten => std.fmt.allocPrint(allocator, "{s}/{s}.debug.js", .{ output_root, stem }),
        .hybrid => std.fmt.allocPrint(allocator, "{s}/{s}.debug.khm", .{ output_root, stem }),
    };
}

test "parseArgs recognizes dap and backend" {
    const parsed = try parseArgs(&.{ "--backend", "hybrid", "--dap", "examples/hello.kira" });
    try std.testing.expect(parsed.dap);
    try std.testing.expectEqual(build_def.ExecutionTarget.hybrid, parsed.backend.?);
    try std.testing.expectEqualStrings("examples/hello.kira", parsed.input_path);
    try std.testing.expectEqual(@as(?u16, null), parsed.port);
}

test "parseArgs parses port and defaults input path" {
    const parsed = try parseArgs(&.{ "--dap", "--port", "4711" });
    try std.testing.expect(parsed.dap);
    try std.testing.expectEqual(@as(u16, 4711), parsed.port.?);
    try std.testing.expectEqualStrings(".", parsed.input_path);
}
