const std = @import("std");
const diag_messages = @import("kira_diagnostic_messages");
const live = @import("root.zig");
const live_build_options = @import("kira_live_build_options");
const manifest_config = @import("kira_manifest");
const web_bundle = @import("web_bundle.zig");
const live_args = @import("live_args.zig");
const shared = @import("supervisor_shared.zig");

pub fn run(
    allocator: std.mem.Allocator,
    parsed: live_args.ParsedArgs,
    target: live.ResolvedLiveTarget,
    stdout: anytype,
    stderr: anytype,
) !void {
    if (parsed.surface == .hybrid) {
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(allocator, parsed.surface.label(), "The hybrid web live surface is modeled, but it still needs a browser VM/native boundary runner."));
        return error.CommandFailed;
    }
    const requirements = manifest_config.webSurfaceRequirements(parsed.surface);
    const web_root = try std.fs.path.join(allocator, &.{ target.output_root, "runners", "web-kira-wasm" });
    const build_dir = try std.fs.path.join(allocator, &.{ target.output_root, "runners", "web-kira-wasm-build" });

    try shared.emitEvent(stdout, "live.web.build.started", "target={s} surface={s} entrypoint={s}", .{ target.target_root, parsed.surface.label(), target.validation_entrypoint_path });
    const bundle = web_bundle.buildWebApp(allocator, .{
        .source_path = target.validation_entrypoint_path,
        .project_root = target.target_root,
        .project_name = target.target_package_name,
        .surface = parsed.surface,
        .web_root = web_root,
        .build_dir = build_dir,
    }, stderr) catch |err| switch (err) {
        error.WebAppBuildFailed => return error.CommandFailed,
        else => return err,
    };

    const wasm_bytes = try std.Io.Dir.cwd().statFile(std.Options.debug_io, bundle.wasm_path, .{});
    try shared.emitEvent(stdout, "live.web.surface.modeled", "surface={s} rendering={s} canvas={}", .{ parsed.surface.label(), requirements.rendering_model.label(), requirements.requires_canvas });
    try shared.emitEvent(stdout, "live.web.wasm.compiled", "js={s} wasm={s} bytes={d}", .{ bundle.js_path, bundle.wasm_path, wasm_bytes.size });
    try shared.emitEvent(stdout, "live.bundle.built", "artifact=main.wasm target={s}", .{target.target_root});

    if (parsed.headless) {
        return runHeadlessNode(allocator, target, bundle, stdout, stderr);
    }
    return serveBrowser(allocator, parsed, target, web_root, bundle, stdout, stderr);
}

/// Headless (`kira run web`) proof: a browser page cannot be hosted in this mode,
/// so node executes the very artifact a browser would load. The app's real stdout
/// is streamed through, and the node exit status decides success — no server, no
/// simulated markers.
fn runHeadlessNode(
    allocator: std.mem.Allocator,
    target: live.ResolvedLiveTarget,
    bundle: web_bundle.BundleResult,
    stdout: anytype,
    stderr: anytype,
) !void {
    try shared.emitEvent(stdout, "live.runner.headless", "target={s}", .{target.target_root});
    const result = try web_bundle.runNodeApp(allocator, bundle.js_path, target.target_root);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len > 0) try stdout.writeAll(result.stdout);
    if (!result.exit_ok) {
        if (result.stderr.len > 0) try stderr.writeAll(result.stderr);
        try shared.emitEvent(stderr, "web.run.node_failed", "js={s}", .{bundle.js_path});
        return error.CommandFailed;
    }
    if (result.stderr.len > 0) try stderr.writeAll(result.stderr);
    try shared.emitEvent(stdout, "web.run.node_executed", "js={s} stdout_bytes={d} exit_ok=true", .{ bundle.js_path, result.stdout.len });
    try shared.emitEvent(stdout, "live.session.ready", "target={s}", .{target.target_root});
    try shared.emitEvent(stdout, "live.shutdown.finished", "runner=web", .{});
}

/// Interactive (`kira live web`) path: serve the compiled bundle over HTTP so a
/// real browser can load `main.js`/`main.wasm` and run the Kira entrypoint. The
/// page reports genuine emscripten lifecycle events; the host only serves files.
fn serveBrowser(
    allocator: std.mem.Allocator,
    parsed: live_args.ParsedArgs,
    target: live.ResolvedLiveTarget,
    web_root: []const u8,
    bundle: web_bundle.BundleResult,
    stdout: anytype,
    stderr: anytype,
) !void {
    const port = parsed.port orelse 42111;
    const port_text = try std.fmt.allocPrint(allocator, "{d}", .{port});
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();
    var http_child = try std.process.spawn(io, .{
        .argv = &.{ live_build_options.static_file_server_path, web_root, port_text },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer shared.killAndWait(&http_child, io);
    if (try shared.waitChildExitBefore(&http_child, 200 * std.time.ns_per_ms)) {
        try shared.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.liveServerFailedToStart(allocator, "127.0.0.1", port));
        return error.CommandFailed;
    }

    const served_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    try shared.emitEvent(stdout, "live.server.started", "runner=web surface={s} root={s} url={s}", .{ parsed.surface.label(), web_root, served_url });
    try shared.emitEvent(stdout, "live.bundle.served", "url={s} index={s}", .{ served_url, bundle.index_path });
    try shared.emitEvent(stdout, "live.session.ready", "target={s}", .{target.target_root});
    if (parsed.run_for_ns) |duration_ns| try std.Options.debug_io.sleep(.fromNanoseconds(@intCast(@min(duration_ns, std.time.ns_per_s))), .awake);
    try shared.emitEvent(stdout, "live.shutdown.finished", "runner=web", .{});
}
