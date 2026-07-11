const std = @import("std");
const hybrid = @import("kira_hybrid_definition");
const hybrid_runtime = @import("kira_hybrid_runtime");
const model = @import("model.zig");
const protocol = @import("protocol.zig");
const reload_listener = @import("reload_listener.zig");
pub const RunnerClient = @import("runner_client.zig").RunnerClient;

const RequestQuitFn = *const fn () callconv(.c) void;

var active_client: ?*RunnerClient = null;
var first_frame_sent = false;
var standalone_active = false;
var standalone_first_frame_emitted = false;

pub export fn kira_live_runner_entry(manifest_path: [*:0]const u8) callconv(.c) c_int {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    runFromManifestPath(arena.allocator(), std.mem.span(manifest_path)) catch |err| {
        std.debug.print("live.runner.error={s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

pub fn runFromManifestPath(allocator: std.mem.Allocator, manifest_path: []const u8) !void {
    const manifest_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, manifest_path, allocator, .limited(1024 * 1024));
    const runner_manifest = try model.RunnerManifest.parse(allocator, manifest_text);
    const manifest_dir = std.fs.path.dirname(manifest_path) orelse ".";
    switch (runner_manifest.runtime_mode) {
        .live => try runLiveFromManifest(allocator, manifest_dir, runner_manifest),
        .standalone => try runStandaloneFromManifest(allocator, manifest_dir, runner_manifest),
    }
}

fn runLiveFromManifest(
    allocator: std.mem.Allocator,
    manifest_dir: []const u8,
    runner_manifest: model.RunnerManifest,
) !void {
    const local_cache_root = try resolveLocalCacheRoot(allocator, manifest_dir, runner_manifest.local_cache_path);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, local_cache_root);

    const client = try RunnerClient.connect(allocator, runner_manifest.server_host, runner_manifest.server_port);
    defer client.close();
    active_client = client;
    defer active_client = null;
    first_frame_sent = false;

    try client.sendText(.hello, "kira-live-runner");
    try client.sendText(.runtime_info, runner_manifest.name);
    try client.sendText(.log_line, try std.fmt.allocPrint(allocator, "live.runner.pid={d}", .{processId()}));
    try client.sendText(.log_line, "live.client.connected");

    // One bundle set, then one run. While the app runs, the background reload
    // listener is the sole socket reader: a VM-only rebuild is hot-swapped in
    // place (same process, same window — see reload_listener.zig), and only a
    // native-code change falls back to the supervisor's process relaunch
    // (sokol's macOS/iOS backends never return from the app run loop, so the
    // dylo-reload path cannot restart in-process).
    switch (try receiveBundleSet(allocator, client, local_cache_root, runner_manifest.main_bundle_id)) {
        .bundle_ready => {},
        .shutdown => return,
    }
    const bundle_root = try std.fs.path.join(allocator, &.{ local_cache_root, "bundles", try std.fmt.allocPrint(allocator, "{s}.klbundle", .{runner_manifest.main_bundle_id}) });
    try runBundle(allocator, client, bundle_root, runner_manifest.target_path, .{
        .local_cache_root = local_cache_root,
        .main_bundle_id = runner_manifest.main_bundle_id,
    });
}

const LiveReloadConfig = struct {
    local_cache_root: []const u8,
    main_bundle_id: []const u8,
};

fn runStandaloneFromManifest(
    allocator: std.mem.Allocator,
    manifest_dir: []const u8,
    runner_manifest: model.RunnerManifest,
) !void {
    const embedded_rel = runner_manifest.embedded_bundles_path orelse return error.MissingEmbeddedBundlesPath;
    const embedded_bundles_root = if (std.fs.path.isAbsolute(embedded_rel))
        try allocator.dupe(u8, embedded_rel)
    else
        try std.fs.path.join(allocator, &.{ manifest_dir, embedded_rel });
    const bundle_root = try std.fs.path.join(allocator, &.{ embedded_bundles_root, try std.fmt.allocPrint(allocator, "{s}.klbundle", .{runner_manifest.main_bundle_id}) });
    standalone_first_frame_emitted = false;
    standaloneLog("live.runner.pid={d}", .{processId()});
    standaloneLog("live.runtime.mode=standalone", .{});
    standaloneLog("live.bundle.loaded", .{});
    try runBundleStandalone(allocator, bundle_root, manifest_dir);
}

fn resolveLocalCacheRoot(allocator: std.mem.Allocator, manifest_dir: []const u8, local_cache_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(local_cache_path)) return allocator.dupe(u8, local_cache_path);
    if (std.mem.startsWith(u8, local_cache_path, "app-support/")) {
        const base = try appContainerPath(allocator, .application_support);
        return std.fs.path.join(allocator, &.{ base, local_cache_path["app-support/".len..] });
    }
    if (std.mem.startsWith(u8, local_cache_path, "app-cache/")) {
        const base = try appContainerPath(allocator, .caches);
        return std.fs.path.join(allocator, &.{ base, local_cache_path["app-cache/".len..] });
    }
    if (std.mem.startsWith(u8, local_cache_path, "tmp/")) {
        const base = try appContainerPath(allocator, .temporary);
        return std.fs.path.join(allocator, &.{ base, local_cache_path["tmp/".len..] });
    }
    return std.fs.path.join(allocator, &.{ manifest_dir, local_cache_path });
}

const AppContainerPathKind = enum {
    application_support,
    caches,
    temporary,
};

fn appContainerPath(allocator: std.mem.Allocator, kind: AppContainerPathKind) ![]const u8 {
    if (std.c.getenv("KIRA_LIVE_APP_CONTAINER_ROOT")) |raw| {
        const root = std.mem.span(raw);
        if (root.len != 0) return appContainerPathFromRoot(allocator, root, kind);
    }
    if (std.c.getenv("HOME")) |raw| {
        const home = std.mem.span(raw);
        if (home.len != 0) return appContainerPathFromRoot(allocator, home, kind);
    }
    if (kind == .temporary) {
        if (std.c.getenv("TMPDIR")) |raw| {
            const tmp = std.mem.span(raw);
            if (tmp.len != 0) return allocator.dupe(u8, tmp);
        }
    }
    return appContainerPathFromRoot(allocator, ".", kind);
}

fn appContainerPathFromRoot(allocator: std.mem.Allocator, root: []const u8, kind: AppContainerPathKind) ![]const u8 {
    return switch (kind) {
        .application_support => std.fs.path.join(allocator, &.{ root, "Library", "Application Support" }),
        .caches => std.fs.path.join(allocator, &.{ root, "Library", "Caches" }),
        .temporary => std.fs.path.join(allocator, &.{ root, "tmp" }),
    };
}

fn runBundleStandalone(
    allocator: std.mem.Allocator,
    bundle_root: []const u8,
    manifest_dir: []const u8,
) !void {
    standalone_active = true;
    defer standalone_active = false;
    const bundle_manifest_path = try std.fs.path.join(allocator, &.{ bundle_root, "KiraBundle.toml" });
    const bundle_manifest_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, bundle_manifest_path, allocator, .limited(1024 * 1024));
    const bundle_manifest = try model.BundleManifest.parse(allocator, bundle_manifest_text);
    const hybrid_path = try std.fs.path.join(allocator, &.{ bundle_root, bundle_manifest.hybrid_rel_path });
    const runtime_allocator = std.heap.smp_allocator;
    var hybrid_manifest = try hybrid.HybridModuleManifest.readFromFile(runtime_allocator, hybrid_path);
    hybrid_manifest.bytecode_path = try std.fs.path.join(runtime_allocator, &.{ bundle_root, bundle_manifest.bytecode_rel_path });

    var original_cwd = try std.Io.Dir.cwd().openDir(std.Options.debug_io, ".", .{});
    defer {
        std.process.setCurrentDir(std.Options.debug_io, original_cwd) catch {};
        original_cwd.close(std.Options.debug_io);
    }
    var bundle_dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, bundle_root, .{});
    defer bundle_dir.close(std.Options.debug_io);
    try std.process.setCurrentDir(std.Options.debug_io, bundle_dir);
    var runtime = if (std.mem.eql(u8, hybrid_manifest.native_library_path, "__kira_live_self__"))
        try hybrid_runtime.HybridRuntime.initFromCurrentProcess(runtime_allocator, hybrid_manifest)
    else
        try hybrid_runtime.HybridRuntime.init(runtime_allocator, hybrid_manifest);
    defer runtime.deinit();
    try runtime.bridge.installFirstFrameHook(standaloneFirstFrameHook);
    try runtime.bridge.installLogHook(standaloneLogHook);
    startNativeQuitTimer(&runtime) catch {};
    standaloneLog("live.bundle.linked", .{});
    standaloneLog("live.entrypoint.started", .{});

    var resource_dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, manifest_dir, .{});
    defer resource_dir.close(std.Options.debug_io);
    try std.process.setCurrentDir(std.Options.debug_io, resource_dir);

    runtime.run() catch |err| {
        if (err == error.RuntimeFailure) {
            if (runtime.vm.lastError()) |message| {
                std.debug.print("hybrid runtime failure: {s}\n", .{message});
            }
        }
        return err;
    };
    standaloneLog("live.entrypoint.finished", .{});
}

fn runBundle(
    allocator: std.mem.Allocator,
    client: *RunnerClient,
    bundle_root: []const u8,
    target_root: []const u8,
    reload_config: LiveReloadConfig,
) !void {
    first_frame_sent = false;
    const bundle_manifest_path = try std.fs.path.join(allocator, &.{ bundle_root, "KiraBundle.toml" });
    const bundle_manifest_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, bundle_manifest_path, allocator, .limited(1024 * 1024));
    const bundle_manifest = try model.BundleManifest.parse(allocator, bundle_manifest_text);
    const hybrid_path = try std.fs.path.join(allocator, &.{ bundle_root, bundle_manifest.hybrid_rel_path });
    const runtime_allocator = std.heap.smp_allocator;
    var hybrid_manifest = try hybrid.HybridModuleManifest.readFromFile(runtime_allocator, hybrid_path);
    hybrid_manifest.bytecode_path = try std.fs.path.join(runtime_allocator, &.{ bundle_root, bundle_manifest.bytecode_rel_path });

    var original_cwd = try std.Io.Dir.cwd().openDir(std.Options.debug_io, ".", .{});
    defer {
        std.process.setCurrentDir(std.Options.debug_io, original_cwd) catch {};
        original_cwd.close(std.Options.debug_io);
    }
    var bundle_dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, bundle_root, .{});
    defer bundle_dir.close(std.Options.debug_io);
    try std.process.setCurrentDir(std.Options.debug_io, bundle_dir);
    var runtime = if (std.mem.eql(u8, hybrid_manifest.native_library_path, "__kira_live_self__"))
        try hybrid_runtime.HybridRuntime.initFromCurrentProcess(runtime_allocator, hybrid_manifest)
    else
        try hybrid_runtime.HybridRuntime.init(runtime_allocator, hybrid_manifest);
    defer runtime.deinit();
    try runtime.bridge.installFirstFrameHook(kiraLiveFirstFrameHook);
    try runtime.bridge.installLogHook(kiraLiveLogHook);
    startNativeQuitTimer(&runtime) catch {};

    // Hot reload: markers for swap events, then the background listener that
    // owns all socket reads for the rest of the session. KIRA_LIVE_NO_HOTPATCH
    // is the dev kill-switch back to relaunch-only reloads.
    if (std.c.getenv("KIRA_LIVE_NO_HOTPATCH") == null) {
        runtime.reload.notify_context = @ptrCast(client);
        runtime.reload.notify = kiraLiveReloadNotify;
        const listener = try allocator.create(reload_listener.Listener);
        listener.* = .{
            .client = client,
            .runtime = &runtime,
            .local_cache_root = reload_config.local_cache_root,
            .main_bundle_id = reload_config.main_bundle_id,
            .bundle_root = bundle_root,
        };
        try listener.spawn();
    }

    try client.sendText(.log_line, "live.bundle.linked");
    try client.sendText(.log_line, "live.entrypoint.started");
    var target_dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, target_root, .{});
    defer target_dir.close(std.Options.debug_io);
    try std.process.setCurrentDir(std.Options.debug_io, target_dir);
    runtime.run() catch |err| {
        if (err == error.RuntimeFailure) {
            if (runtime.vm.lastError()) |message| {
                std.debug.print("hybrid runtime failure: {s}\n", .{message});
            }
        }
        return err;
    };
    try client.sendText(.log_line, "live.entrypoint.finished");
}

fn startNativeQuitTimer(runtime: *hybrid_runtime.HybridRuntime) !void {
    const duration_raw = std.c.getenv("KIRA_LIVE_QUIT_AFTER_NS") orelse return;
    const duration_ns = std.fmt.parseInt(u64, std.mem.span(duration_raw), 10) catch return;
    if (duration_ns == 0) return;
    if (runtime.bridge.library) |*library| {
        const request_quit = library.lookup(RequestQuitFn, "sapp_request_quit") orelse return;
        var thread = try std.Thread.spawn(.{}, nativeQuitTimerMain, .{ duration_ns, request_quit });
        thread.detach();
    }
}

fn nativeQuitTimerMain(duration_ns: u64, request_quit: RequestQuitFn) void {
    std.Options.debug_io.sleep(.fromNanoseconds(@intCast(duration_ns)), .awake) catch {};
    request_quit();
}

const ReceiveResult = enum { bundle_ready, shutdown };

fn receiveBundleSet(
    allocator: std.mem.Allocator,
    client: *RunnerClient,
    local_cache_root: []const u8,
    main_bundle_id: []const u8,
) !ReceiveResult {
    while (true) {
        const frame = try client.readFrame(allocator);
        switch (frame.kind) {
            .bundle_graph => {
                try client.sendText(.log_line, "live.bundle.graph.received");
            },
            .replace_bundle => {
                const payload = try protocol.decodeReplaceBundlePayload(allocator, frame.payload);
                try client.sendText(.log_line, "live.client.bundle.received");
                try client.sendText(.log_line, "live.bundle.received");
                const bundle_dir = try std.fs.path.join(allocator, &.{ local_cache_root, "bundles", try std.fmt.allocPrint(allocator, "{s}.klbundle", .{payload.bundle_id}) });
                try storeBundlePayload(bundle_dir, payload);
                if (std.mem.eql(u8, payload.bundle_id, main_bundle_id)) {
                    try client.sendText(.log_line, "live.bundle.loaded");
                    return .bundle_ready;
                }
            },
            .shutdown => {
                try client.sendText(.log_line, "live.shutdown.started");
                try client.sendText(.log_line, "live.shutdown.received");
                try client.sendText(.shutdown_ack, "ok");
                try client.sendText(.log_line, "live.shutdown.finished");
                return .shutdown;
            },
            else => {},
        }
    }
}

const storeBundlePayload = reload_listener.storeBundlePayload;

/// Hot-swap event markers (runs on the sokol main thread at the callback
/// boundary that applied — or rejected — the swap). `rejected` additionally
/// sends a `reload_failed` frame so the supervisor falls back to a relaunch.
fn kiraLiveReloadNotify(context: ?*anyopaque, event: hybrid_runtime.hot_swap.ReloadEvent, detail: []const u8) void {
    const client: *RunnerClient = @ptrCast(@alignCast(context orelse return));
    var buffer: [320]u8 = undefined;
    switch (event) {
        .applied => {
            const text = std.fmt.bufPrint(&buffer, "live.reload.applied {s}", .{detail}) catch "live.reload.applied";
            client.sendText(.log_line, text) catch {};
        },
        .completed => {
            const text = std.fmt.bufPrint(&buffer, "live.reload.completed mode=hotpatch {s}", .{detail}) catch "live.reload.completed mode=hotpatch";
            client.sendText(.log_line, text) catch {};
        },
        .rejected => {
            client.sendText(.reload_failed, detail) catch {};
            const text = std.fmt.bufPrint(&buffer, "live.reload.rejected reason={s}", .{detail}) catch "live.reload.rejected";
            client.sendText(.log_line, text) catch {};
        },
        .deferred => {
            const text = std.fmt.bufPrint(&buffer, "live.reload.deferred reason={s}", .{detail}) catch "live.reload.deferred";
            client.sendText(.log_line, text) catch {};
        },
    }
}

fn kiraLiveFirstFrameHook() callconv(.c) void {
    if (first_frame_sent) return;
    first_frame_sent = true;
    if (active_client) |client| {
        client.sendText(.log_line, "live.frame.presented") catch {};
    }
}

fn kiraLiveLogHook(line: [*:0]const u8) callconv(.c) void {
    if (active_client) |client| {
        client.sendText(.log_line, std.mem.span(line)) catch {};
    }
}

fn standaloneFirstFrameHook() callconv(.c) void {
    if (standalone_first_frame_emitted) return;
    standalone_first_frame_emitted = true;
    standaloneLog("live.frame.presented", .{});
}

fn standaloneLogHook(line: [*:0]const u8) callconv(.c) void {
    const text = std.mem.span(line);
    standaloneWriteLine(text);
}

fn standaloneLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, fmt, args) catch {
        standaloneWriteLine(fmt);
        return;
    };
    standaloneWriteLine(formatted);
}

const builtin = @import("builtin");

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

fn processId() u32 {
    return switch (builtin.os.tag) {
        .windows => GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

const SYSLOG_LEVEL_NOTICE: c_int = 5;
extern "c" fn syslog(priority: c_int, format: [*:0]const u8, ...) callconv(.c) void;

fn standaloneWriteLine(text: []const u8) void {
    var buf: [2048]u8 = undefined;
    const copy_len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..copy_len], text[0..copy_len]);
    buf[copy_len] = 0;
    const z: [*:0]const u8 = @ptrCast(&buf);
    if (builtin.os.tag == .macos or builtin.os.tag == .ios) {
        syslog(SYSLOG_LEVEL_NOTICE, "%s", z);
    }
    var stderr_buf: [2048]u8 = undefined;
    var writer = std.Io.File.stderr().writer(std.Options.debug_io, &stderr_buf);
    defer writer.interface.flush() catch {};
    writer.interface.writeAll(text) catch return;
    writer.interface.writeByte('\n') catch return;
}

test "live runner cache paths can target app-container writable roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const app_support = try appContainerPathFromRoot(arena.allocator(), "/tmp/KiraContainer", .application_support);
    try std.testing.expectEqualStrings("/tmp/KiraContainer/Library/Application Support", app_support);
    const caches = try appContainerPathFromRoot(arena.allocator(), "/tmp/KiraContainer", .caches);
    try std.testing.expectEqualStrings("/tmp/KiraContainer/Library/Caches", caches);
    const temporary = try appContainerPathFromRoot(arena.allocator(), "/tmp/KiraContainer", .temporary);
    try std.testing.expectEqualStrings("/tmp/KiraContainer/tmp", temporary);

    const relative = try resolveLocalCacheRoot(arena.allocator(), "/App.app/Contents/Resources", "cache");
    try std.testing.expectEqualStrings("/App.app/Contents/Resources/cache", relative);
}
