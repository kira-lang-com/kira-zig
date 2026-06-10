const std = @import("std");
const diag_messages = @import("kira_diagnostic_messages");
const live = @import("root.zig");
const protocol = @import("protocol.zig");
const live_args = @import("live_args.zig");
const apple_runner = @import("apple_runner.zig");
const shared = @import("supervisor_shared.zig");
const web_live = @import("web_live.zig");
const ios_live = @import("ios_live.zig");
const apple_live = @import("apple_live.zig");
const android_live = @import("android_live.zig");
const SourceWatcher = @import("source_watcher.zig").SourceWatcher;

const ParsedArgs = live_args.ParsedArgs;
const PreparedRunner = apple_runner.PreparedRunner;
const LiveServer = shared.LiveServer;
const parseArgs = live_args.parseArgs;
const renderStandaloneDiagnostic = shared.renderStandaloneDiagnostic;
const emitEvent = shared.emitEvent;
const writeFile = shared.writeFile;
const runToolCapture = shared.runToolCapture;
const toolAvailable = shared.toolAvailable;
const inheritedProcessEnviron = shared.inheritedProcessEnviron;
const killAndWait = shared.killAndWait;
const pollChildExited = shared.pollChildExited;
const waitChildExitBefore = shared.waitChildExitBefore;
const acceptClientOrDiagnose = shared.acceptClientOrDiagnose;
const rewriteRunnerManifestPort = shared.rewriteRunnerManifestPort;
const elapsedSince = shared.elapsedSince;
const runnerSelector = apple_runner.runnerSelector;
const generateRunnerArtifacts = apple_runner.generateRunnerArtifacts;
const validateAppleRunnerProject = apple_runner.validateAppleRunnerProject;
const auditAndroidDeviceState = android_live.auditAndroidDeviceState;
const runAndroidLiveAttempt = android_live.runAndroidLiveAttempt;

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = parseArgs(args) catch |err| switch (err) {
        error.InvalidLivePlatform => {
            const platform = if (args.len == 0) "" else args[0];
            try renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.invalidLivePlatform(allocator, platform));
            return error.CommandFailed;
        },
        else => return err,
    };
    if (parsed.mode == .runners_list) {
        const target = try resolveTargetOrDiagnose(allocator, parsed.input_path, stderr);
        try stdout.writeAll("desktop-dynamic-host\nxcode-macos\nxcode-ios\n");
        try stdout.print("target {s}\nvalidation {s}\n", .{ target.target_root, target.validation_app_root });
        return;
    }
    if (parsed.mode == .runners_clean) {
        const target = try resolveTargetOrDiagnose(allocator, parsed.input_path, stderr);
        const runners_root = try std.fs.path.join(allocator, &.{ target.output_root, "runners" });
        _ = std.Io.Dir.cwd().deleteTree(std.Options.debug_io, runners_root) catch {};
        const server_root = try std.fs.path.join(allocator, &.{ target.output_root, "server" });
        _ = std.Io.Dir.cwd().deleteTree(std.Options.debug_io, server_root) catch {};
        try stdout.print("cleaned {s}\n", .{target.output_root});
        return;
    }

    const target = try resolveTargetOrDiagnose(allocator, parsed.input_path, stderr);
    if (parsed.platform == .ios) {
        if (std.mem.eql(u8, parsed.requested_runner, "ios-simulator") or std.mem.eql(u8, parsed.device, "simulator")) {
            return apple_live.run(allocator, parsed, target, .ios_simulator, stdout, stderr);
        }
        return ios_live.runDeviceAttempt(allocator, parsed, target, stdout, stderr);
    }

    if (parsed.platform == .web) {
        return web_live.run(allocator, parsed, target, stdout, stderr);
    }

    if (parsed.platform == .macos) {
        return apple_live.run(allocator, parsed, target, .macos, stdout, stderr);
    }

    if (parsed.platform == .android) {
        return runAndroidLiveAttempt(allocator, target, stdout, stderr);
    }

    if (parsed.platform != .desktop) {
        return auditScaffoldedRunnerOrDiagnose(allocator, parsed.platform, target, stdout, stderr);
    }

    const runner_kind = live.runnerKind(parsed.platform) orelse return error.CommandFailed;
    const selector = try runnerSelector(allocator, runner_kind);
    const bundles = live.buildBundles(allocator, target, selector, false) catch |err| switch (err) {
        error.LiveBundleBuildFailed => {
            try renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.liveSmokeUnsupportedTarget(allocator, parsed.input_path));
            return error.CommandFailed;
        },
        else => return err,
    };
    try emitEvent(stdout, "live.bundle.compiled", "target={s} output_root={s}", .{ target.target_root, target.output_root });
    try emitEvent(stdout, "live.bundle.built", "artifact=.klbundle target={s}", .{target.target_root});
    const runner = generateRunnerArtifacts(allocator, runner_kind, target, bundles, parsed, stderr) catch |err| switch (err) {
        error.ExternalCommandFailed => {
            const cwd = try std.process.currentPathAlloc(std.Options.debug_io, allocator);
            try renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.liveRunnerBuildRootMissing(allocator, cwd));
            return error.CommandFailed;
        },
        else => return err,
    };
    if (parsed.mode == .runners_build) {
        try stdout.print("built {s}\n", .{runner.runner_dir});
        return;
    }

    try runDesktop(allocator, parsed, target, bundles, runner, stdout, stderr);
}

fn resolveTargetOrDiagnose(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    stderr: anytype,
) !live.ResolvedLiveTarget {
    return live.resolveLiveTarget(allocator, input_path) catch |err| switch (err) {
        error.InvalidProjectPath => {
            try renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.invalidProjectPath(allocator, input_path));
            return error.CommandFailed;
        },
        error.ProjectManifestNotFound => {
            try renderStandaloneDiagnostic(stderr, try diag_messages.PackageMessages.missingProjectManifest(allocator, input_path));
            return error.CommandFailed;
        },
        error.LibraryTargetCannotBeStartedInLiveMode => {
            try renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.libraryTargetCannotBeStartedInLiveMode(allocator, input_path));
            return error.CommandFailed;
        },
        error.TargetNotLiveCapable => {
            try renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.commandRequiresLiveCapableTarget(allocator, "source_file"));
            return error.CommandFailed;
        },
        error.ProjectEntrypointNotFound => {
            try renderStandaloneDiagnostic(stderr, try diag_messages.PackageMessages.missingSourceFile(allocator, input_path));
            return error.CommandFailed;
        },
        else => return err,
    };
}

fn runDesktop(
    allocator: std.mem.Allocator,
    parsed: ParsedArgs,
    target: live.ResolvedLiveTarget,
    bundles: live.BundleBuildArtifacts,
    runner: PreparedRunner,
    stdout: anytype,
    stderr: anytype,
) !void {
    var server = LiveServer.listen(allocator, "127.0.0.1", 42111, bundles.graph) catch {
        try renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.liveServerFailedToStart(allocator, "127.0.0.1", 42111));
        return error.CommandFailed;
    };
    defer server.deinit();
    try rewriteRunnerManifestPort(allocator, runner.manifest_path, server.port);
    try emitEvent(stdout, "live.server.started", "host=127.0.0.1 port={d}", .{server.port});
    try emitEvent(stdout, "live.runner.resolved", "path={s} runtime_cwd={s}", .{
        runner.executable_path.?,
        target.target_root,
    });

    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer io_impl.deinit();
    const process_environ = inheritedProcessEnviron();
    var environ_map = try std.process.Environ.createMap(process_environ, allocator);
    defer environ_map.deinit();
    if (parsed.run_for_ns) |duration_ns| {
        const duration_text = try std.fmt.allocPrint(allocator, "{d}", .{duration_ns});
        try environ_map.put("KIRA_LIVE_QUIT_AFTER_NS", duration_text);
    }
    const io = io_impl.io();
    var runner_argv = std.array_list.Managed([]const u8).init(allocator);
    try runner_argv.append(runner.executable_path.?);
    if (runner.subcommand) |subcommand| try runner_argv.append(subcommand);
    try runner_argv.append(runner.manifest_path);

    var source_watcher = try createSourceWatcher(allocator, target, bundles);
    defer source_watcher.deinit();

    const require_frame = !parsed.headless;
    if (parsed.headless) {
        try emitEvent(stdout, "live.runner.headless", "target={s}", .{target.target_root});
    }
    const session_start = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);

    // Desktop hot reload relaunches the runner process per reload: sokol's macOS backend
    // enters `[NSApp run]`, which never returns — `sapp_request_quit` terminates the whole
    // process via `applicationWillTerminate` — so an in-process "quit and re-run the bundle"
    // restart loop is impossible on macOS. Each reload generation spawns a fresh runner,
    // re-accepts its connection, resends the rebuilt bundles, and re-verifies the full
    // health-marker handshake (including `live.frame.presented`, the real first-frame
    // evidence) before declaring the reload complete.
    var reload_generation: u32 = 0;
    session: while (true) : (reload_generation += 1) {
        var child = try std.process.spawn(io, .{
            .argv = runner_argv.items,
            .cwd = .{ .path = target.target_root },
            .environ_map = &environ_map,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        if (reload_generation == 0) {
            try emitEvent(stdout, "live.runner.launched", "pid={any}", .{child.id});
        } else {
            try emitEvent(stdout, "live.runner.relaunched", "pid={any} generation={d}", .{ child.id, reload_generation });
        }

        var connection = (try acceptClientOrDiagnose(allocator, &server, &child, io, target, stdout, stderr)) orelse return;
        defer connection.close();
        try emitEvent(stdout, "live.client.connected", "target={s}", .{target.target_root});
        try emitEvent(stdout, "live.bundle.requested", "client=desktop", .{});
        try connection.sendGraphAndBundles();
        try emitEvent(stdout, "live.bundle.graph.sent", "bundles={d}", .{server.graph.bundles.len});
        const bundle_mode: []const u8 = if (reload_generation == 0) "mode=initial" else "mode=full-bundle";
        try emitEvent(stdout, "live.bundle.sent", "{s}", .{bundle_mode});
        try emitEvent(stdout, "live.bundle.served", "{s}", .{bundle_mode});
        const health_ok = try connection.waitForHealthMarkers(stdout, 30 * std.time.ns_per_s, require_frame);
        if (!health_ok) {
            killAndWait(&child, io);
            const diagnostic = if (reload_generation != 0)
                try diag_messages.CliMessages.liveReloadTimedOut(allocator, target.target_root)
            else if (require_frame)
                try diag_messages.CliMessages.liveFrameNotPresented(allocator, target.target_root)
            else
                try diag_messages.CliMessages.liveEntrypointDidNotStart(allocator, target.target_root);
            try renderStandaloneDiagnostic(stderr, diagnostic);
            return error.CommandFailed;
        }
        if (reload_generation == 0) {
            try emitEvent(stdout, "live.session.ready", "target={s}", .{target.target_root});
        } else {
            try emitEvent(stdout, "live.reload.completed", "mode=relaunch generation={d}", .{reload_generation});
        }

        while (true) {
            try std.Options.debug_io.sleep(.fromNanoseconds(250 * std.time.ns_per_ms), .awake);
            if (parsed.run_for_ns) |duration_ns| {
                if (elapsedSince(session_start) >= duration_ns) {
                    try finishQuitAfterSession(&child, &connection, io, stdout);
                    try stderr.print("live runner quit-after elapsed: {s}\n", .{runner.manifest_path});
                    return;
                }
            }
            if (try pollChildExited(&child)) {
                if (parsed.run_for_ns != null) {
                    // The runner self-quit via its KIRA_LIVE_QUIT_AFTER_NS timer.
                    try emitEvent(stdout, "live.session.ended", "reason=quit-after", .{});
                    try emitEvent(stdout, "live.shutdown.finished", "reason=quit-after", .{});
                    try stderr.print("live runner quit-after elapsed: {s}\n", .{runner.manifest_path});
                    return;
                }
                break :session;
            }
            if (try source_watcher.changed()) {
                const rebuilt = rebuildBundles(allocator, target, stdout, stderr);
                try source_watcher.refresh();
                if (rebuilt) |graph| {
                    server.graph = graph;
                    try emitEvent(stdout, "live.reload.notified", "mode=relaunch", .{});
                    killAndWait(&child, io);
                    continue :session;
                } else |err| switch (err) {
                    // A broken edit must not end the live session: keep the running app
                    // alive and wait for the next save.
                    error.CommandFailed => try emitEvent(stdout, "live.rebuild.failed", "target={s}", .{target.target_root}),
                    else => {
                        killAndWait(&child, io);
                        return err;
                    },
                }
            }
        }
    }
    try stderr.print("live runner completed: {s}\n", .{runner.manifest_path});
}

fn finishQuitAfterSession(
    child: *std.process.Child,
    connection: *shared.LiveConnection,
    io: std.Io,
    stdout: anytype,
) !void {
    if (child.id != null) {
        try emitEvent(stdout, "live.shutdown.started", "reason=quit-after", .{});
        try protocol.writeFrame(&connection.writer.interface, .shutdown, "quit-after");
        try connection.writer.interface.flush();
        _ = try connection.waitForShutdownAck(stdout, 2 * std.time.ns_per_s);
    }
    if (child.id != null and !try waitChildExitBefore(child, 2 * std.time.ns_per_s)) {
        killAndWait(child, io);
        try emitEvent(stdout, "live.runner.force_killed", "reason=quit-after", .{});
    }
    try emitEvent(stdout, "live.session.ended", "reason=quit-after", .{});
    try emitEvent(stdout, "live.shutdown.finished", "reason=quit-after", .{});
}

fn createSourceWatcher(
    allocator: std.mem.Allocator,
    target: live.ResolvedLiveTarget,
    bundles: live.BundleBuildArtifacts,
) !SourceWatcher {
    var watcher = SourceWatcher.init(allocator);
    errdefer watcher.deinit();

    // Main app directory
    const main_app_dir = try std.fs.path.join(allocator, &.{ target.validation_app_root, "app" });
    defer allocator.free(main_app_dir);
    if (directoryExists(main_app_dir)) {
        try watcher.addDirectory(main_app_dir);
    }

    // Dependency app directories
    for (bundles.graph.bundles) |bundle| {
        const app_dir = try std.fs.path.join(allocator, &.{ bundle.package_root, "app" });
        defer allocator.free(app_dir);
        if (directoryExists(app_dir)) {
            try watcher.addDirectory(app_dir);
        }
    }

    return watcher;
}

fn rebuildBundles(
    allocator: std.mem.Allocator,
    target: live.ResolvedLiveTarget,
    stdout: anytype,
    stderr: anytype,
) !live.BundleGraph {
    try emitEvent(stdout, "live.source.changed", "path={s}", .{target.validation_entrypoint_path});
    try emitEvent(stdout, "live.rebuild.started", "target={s}", .{target.target_root});
    const rebuilt = live.buildBundles(allocator, target, try runnerSelector(allocator, .desktop_dynamic_host), false) catch {
        try renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.liveBundleBuildFailed(allocator, target.target_root));
        return error.CommandFailed;
    };
    try emitEvent(stdout, "live.rebuild.finished", "target={s}", .{target.target_root});
    try emitEvent(stdout, "live.bundle.rebuilt", "mode=full-bundle", .{});
    return rebuilt.graph;
}

fn directoryExists(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}

fn auditScaffoldedRunnerOrDiagnose(
    allocator: std.mem.Allocator,
    runner: live.RunnerId,
    target: live.ResolvedLiveTarget,
    stdout: anytype,
    stderr: anytype,
) !void {
    try emitEvent(stdout, "live.runner.modeled", "runner={s} target={s}", .{ runner.label(), target.target_root });
    switch (runner) {
        .macos, .tvos, .visionos => {
            const xcode = runToolCapture(allocator, &.{ "xcodebuild", "-version" }) catch {
                try renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingAppleTools(allocator, "`xcodebuild -version` failed."));
                return error.CommandFailed;
            };
            defer allocator.free(xcode);
            try emitEvent(stdout, "live.apple.tools.detected", "runner={s}", .{runner.label()});
            try renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(allocator, runner.label(), "The generated Apple export exists, but this runner does not yet have a complete app install/launch/client loop in this build."));
            return error.CommandFailed;
        },
        .windows => {
            try renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingVisualStudioTools(allocator, "Windows runners require Visual Studio tools on a Windows host; this host can still generate the export scaffold."));
            return error.CommandFailed;
        },
        .android => {
            const android_state = auditAndroidDeviceState(allocator, stdout) catch {
                try renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingAndroidSdk(allocator, "`adb devices` failed. Install Android SDK platform-tools or open the scaffold in Android Studio."));
                return error.CommandFailed;
            };
            if (!toolAvailable(allocator, "gradle")) {
                try emitEvent(stdout, "live.android.build.blocked", "reason=missing-gradle", .{});
                try renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingAndroidSdk(allocator, "Gradle was not found. Android Studio is not installed automatically; install command-line Android SDK tools or open the scaffold in Android Studio."));
                return error.CommandFailed;
            }
            try emitEvent(stdout, "live.android.tools.detected", "runner=android", .{});
            try renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(
                allocator,
                runner.label(),
                if (android_state.emulator_detected)
                    "Android Gradle/SDK scaffolding exists and an emulator is visible, but this runner does not yet have a complete install, launch, and live client protocol loop."
                else
                    "Android Gradle/SDK scaffolding exists, but no running emulator was visible for install, launch, and live client protocol validation.",
            ));
            return error.CommandFailed;
        },
        .linux => {
            if (!toolAvailable(allocator, "cmake") or !toolAvailable(allocator, "ninja")) {
                try renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingLinuxBuildTools(allocator, "`cmake` and `ninja` were not both found."));
                return error.CommandFailed;
            }
            try emitEvent(stdout, "live.linux.tools.detected", "runner=linux", .{});
            try renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(allocator, runner.label(), "Linux CMake/Ninja scaffolding exists, but cross-host live launch is not available on this macOS host."));
            return error.CommandFailed;
        },
        .desktop, .ios, .web => unreachable,
    }
}
