//! Shared live-session loop for Apple runners (macOS app, iOS simulator,
//! physical iOS device): initial bundle handshake, then the SAME
//! watch-rebuild-hotpatch loop the desktop supervisor runs.
//!
//! Apple runners embed the Kira runtime and native code in one signed app
//! (`__kira_live_self__`), so the runner's native-library comparison always
//! passes and every source rebuild is applied as an IN-PLACE VM hot patch over
//! the live connection — the app on the phone keeps its window and state. A
//! hot-patch REJECTION (e.g. struct layout change) cannot fall back to a
//! silent process respawn like desktop: a signed app needs rebuild + reinstall,
//! so the session reports `live.reload.reinstall_required` and keeps the old
//! code running rather than pretending.
const std = @import("std");
const native = @import("kira_native_lib_definition");
const live = @import("root.zig");
const protocol = @import("protocol.zig");
const shared = @import("supervisor_shared.zig");
const supervisor_reload = @import("supervisor_reload.zig");
const live_args = @import("live_args.zig");

pub const SessionOptions = struct {
    /// Tag in emitted events: "macos", "ios-simulator", "ios-device".
    runner_label: []const u8,
    /// Selector the session's bundles were built with; rebuilds reuse it.
    selector: ?native.TargetSelector,
    /// Whether bundles bind native code from the runner process itself
    /// (Apple runners: true).
    embed_native_in_runner: bool,
    /// Local child process to poll for exit (macOS app child); device and
    /// simulator sessions have none.
    child: ?*std.process.Child = null,
};

/// Drive an accepted Apple live connection: handshake, health markers, then
/// watch sources and hot patch until quit-after elapses, the runner exits
/// (when `options.child` is provided), or the connection drops.
pub fn driveLiveSession(
    allocator: std.mem.Allocator,
    parsed: live_args.ParsedArgs,
    target: live.ResolvedLiveTarget,
    bundles: live.BundleBuildArtifacts,
    connection: *shared.LiveConnection,
    options: SessionOptions,
    stdout: anytype,
    stderr: anytype,
) !void {
    try shared.emitEvent(stdout, "live.client.connected", "target={s}", .{target.target_root});
    try shared.emitEvent(stdout, "live.bundle.requested", "client={s}", .{options.runner_label});
    try connection.sendGraphAndBundles();
    try shared.emitEvent(stdout, "live.bundle.graph.sent", "bundles={d}", .{bundles.graph.bundles.len});
    try shared.emitEvent(stdout, "live.bundle.sent", "mode=initial", .{});
    try shared.emitEvent(stdout, "live.bundle.served", "mode=initial", .{});
    const require_frame = !parsed.headless;
    const health_ok = try connection.waitForHealthMarkers(stdout, 60 * std.time.ns_per_s, require_frame);
    if (!health_ok) return error.CommandFailed;
    try shared.emitEvent(stdout, "live.session.ready", "target={s}", .{target.target_root});

    var source_watcher = try @import("watch_inputs.zig").createSourceWatcher(allocator, target, bundles);
    defer source_watcher.deinit();

    const session_start = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
    var hotpatch_count: u32 = 0;
    while (true) {
        try std.Options.debug_io.sleep(.fromNanoseconds(250 * std.time.ns_per_ms), .awake);
        if (parsed.run_for_ns) |duration_ns| {
            if (shared.elapsedSince(session_start) >= duration_ns) {
                try shutdownSession(connection, stdout);
                return;
            }
        }
        if (options.child) |the_child| {
            if (try shared.pollChildExited(the_child)) {
                try shared.emitEvent(stdout, "live.session.ended", "reason=runner-exited", .{});
                return;
            }
        }
        if (try source_watcher.changed()) {
            const rebuilt = rebuildBundles(allocator, target, options, stdout, stderr);
            try source_watcher.refresh();
            if (rebuilt) |graph| {
                connection.graph = graph;
                try shared.emitEvent(stdout, "live.reload.notified", "mode=hotpatch runner={s}", .{options.runner_label});
                const outcome = try supervisor_reload.attemptHotReload(connection, stdout, 20 * std.time.ns_per_s);
                switch (outcome) {
                    .completed => {
                        hotpatch_count += 1;
                        try shared.emitEvent(stdout, "live.reload.completed", "mode=hotpatch count={d} runner={s}", .{ hotpatch_count, options.runner_label });
                    },
                    .disconnected => {
                        try shared.emitEvent(stdout, "live.session.ended", "reason=disconnected", .{});
                        return;
                    },
                    else => {
                        // No silent respawn on Apple runners: a swap-incompatible
                        // edit needs an app rebuild + reinstall.
                        try shared.emitEvent(stdout, "live.reload.reinstall_required", "reason={s} runner={s}", .{ outcome.text(), options.runner_label });
                        try stderr.print("live reload needs an app reinstall ({s}); rerun `kira live` to pick up this change.\n", .{outcome.text()});
                    },
                }
            } else |err| switch (err) {
                // A broken edit must not end the live session: keep the running
                // app alive and wait for the next save.
                error.CommandFailed => try shared.emitEvent(stdout, "live.rebuild.failed", "target={s}", .{target.target_root}),
                else => return err,
            }
        }
    }
}

fn rebuildBundles(
    allocator: std.mem.Allocator,
    target: live.ResolvedLiveTarget,
    options: SessionOptions,
    stdout: anytype,
    stderr: anytype,
) !live.BundleGraph {
    try shared.emitEvent(stdout, "live.source.changed", "path={s}", .{target.validation_entrypoint_path});
    try shared.emitEvent(stdout, "live.rebuild.started", "target={s}", .{target.target_root});
    const rebuilt = live.buildBundles(allocator, target, options.selector, options.embed_native_in_runner) catch {
        try shared.renderStandaloneDiagnostic(stderr, try @import("kira_diagnostic_messages").CliMessages.liveBundleBuildFailed(allocator, target.target_root));
        return error.CommandFailed;
    };
    try shared.emitEvent(stdout, "live.rebuild.finished", "target={s}", .{target.target_root});
    try shared.emitEvent(stdout, "live.bundle.rebuilt", "mode=full-bundle", .{});
    return rebuilt.graph;
}

fn shutdownSession(connection: *shared.LiveConnection, stdout: anytype) !void {
    try shared.emitEvent(stdout, "live.shutdown.started", "reason=quit-after", .{});
    try protocol.writeFrame(&connection.writer.interface, .shutdown, "quit-after");
    try connection.writer.interface.flush();
    _ = try connection.waitForShutdownAck(stdout, 2 * std.time.ns_per_s);
    try shared.emitEvent(stdout, "live.shutdown.finished", "reason=quit-after", .{});
}
