//! Background hot-reload listener for the desktop live runner.
//!
//! After the initial bundle set is received, this thread becomes the SOLE
//! reader of the live socket while the sokol event loop owns the main thread.
//! It receives rebuilt bundles mid-run and stages an in-place module swap on
//! the running HybridRuntime (kira_hybrid_runtime/src/hot_swap.zig); the main
//! thread applies the swap at the next frame-callback boundary.
//!
//! Staging never overwrites the canonical bundle directory: the loaded native
//! dylib is mapped from there, and rewriting a mapped, signed dylib on macOS
//! kills the process. Each reload generation lands in its own
//! `<bundle>.klbundle.gen<N>` directory.
//!
//! Native-code changes cannot be hot-swapped (sokol holds pointers into the
//! loaded dylib), so a differing native library rejects the hot patch with a
//! `restart_required` frame and the supervisor falls back to the process
//! relaunch flow.
const std = @import("std");
const hybrid = @import("kira_hybrid_definition");
const hybrid_runtime = @import("kira_hybrid_runtime");
const bytecode = @import("kira_bytecode");
const model = @import("model.zig");
const protocol = @import("protocol.zig");
const RunnerClient = @import("runner_client.zig").RunnerClient;

const RequestQuitFn = *const fn () callconv(.c) void;

pub const Listener = struct {
    client: *RunnerClient,
    runtime: *hybrid_runtime.HybridRuntime,
    local_cache_root: []const u8,
    main_bundle_id: []const u8,
    /// Canonical bundle dir the running program was loaded from (native lib
    /// comparison baseline).
    bundle_root: []const u8,
    generation: u32 = 0,

    pub fn spawn(self: *Listener) !void {
        var thread = try std.Thread.spawn(.{}, listenerMain, .{self});
        thread.detach();
    }
};

fn listenerMain(listener: *Listener) void {
    listenLoop(listener) catch |err| {
        // Socket EOF/reset means the supervisor went away (session teardown or
        // relaunch kill); anything else is reported before the thread exits.
        if (err != error.EndOfStream and err != error.ConnectionResetByPeer and err != error.ReadFailed) {
            listener.client.sendText(.log_line, "live.reload.listener.error") catch {};
        }
    };
}

fn listenLoop(listener: *Listener) !void {
    // Frame payloads accumulate per generation and die with it.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    while (true) {
        const frame = try listener.client.readFrame(arena.allocator());
        switch (frame.kind) {
            .bundle_graph => {},
            .replace_bundle => {
                const payload = try protocol.decodeReplaceBundlePayload(arena.allocator(), frame.payload);
                try listener.client.sendText(.log_line, "live.bundle.received");
                const staged_dir = try stagedBundleDir(arena.allocator(), listener, payload.bundle_id);
                try storeBundlePayload(staged_dir, payload);
                if (std.mem.eql(u8, payload.bundle_id, listener.main_bundle_id)) {
                    stageMainBundle(listener, arena.allocator(), staged_dir) catch |err| {
                        var buffer: [160]u8 = undefined;
                        const text = std.fmt.bufPrint(&buffer, "stage-failed: {s}", .{@errorName(err)}) catch "stage-failed";
                        listener.client.sendText(.reload_failed, text) catch {};
                    };
                    listener.generation += 1;
                    _ = arena.reset(.free_all);
                }
            },
            .shutdown => {
                try listener.client.sendText(.log_line, "live.shutdown.received");
                try listener.client.sendText(.shutdown_ack, "ok");
                requestNativeQuit(listener.runtime);
                return;
            },
            else => {},
        }
    }
}

fn stagedBundleDir(allocator: std.mem.Allocator, listener: *Listener, bundle_id: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{
        listener.local_cache_root,
        "bundles",
        try std.fmt.allocPrint(allocator, "{s}.klbundle.gen{d}", .{ bundle_id, listener.generation + 1 }),
    });
}

/// The rebuilt main bundle is fully on disk in `staged_dir`; load it and stage
/// the module swap, or reject with `restart_required` when the native library
/// changed. Loads use the runtime's long-lived allocator: the module/manifest
/// must outlive this arena-scoped call (they become the runtime's program, or
/// leak bounded on rejection-after-load, which cannot happen — the native
/// check runs before loading).
fn stageMainBundle(listener: *Listener, scratch: std.mem.Allocator, staged_dir: []const u8) !void {
    const bundle_manifest_path = try std.fs.path.join(scratch, &.{ staged_dir, "KiraBundle.toml" });
    const bundle_manifest_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, bundle_manifest_path, scratch, .limited(1024 * 1024));
    const bundle_manifest = try model.BundleManifest.parse(scratch, bundle_manifest_text);

    const runtime_allocator = std.heap.smp_allocator;
    const hybrid_path = try std.fs.path.join(scratch, &.{ staged_dir, bundle_manifest.hybrid_rel_path });
    var staged_manifest = try hybrid.HybridModuleManifest.readFromFile(runtime_allocator, hybrid_path);

    if (!try nativeLibraryUnchanged(listener, scratch, staged_dir, staged_manifest.native_library_path)) {
        try listener.client.sendText(.restart_required, "native library changed");
        try listener.client.sendText(.log_line, "live.reload.restart_required reason=native-library-changed");
        return;
    }

    staged_manifest.bytecode_path = try std.fs.path.join(runtime_allocator, &.{ staged_dir, bundle_manifest.bytecode_rel_path });
    const staged_module = try bytecode.Module.readFromFile(runtime_allocator, staged_manifest.bytecode_path);
    hybrid_runtime.hot_swap.stage(listener.runtime, .{
        .module = staged_module,
        .manifest = staged_manifest,
    });
    try listener.client.sendText(.log_line, "live.reload.staged");
}

/// True when the rebuilt bundle's native library is byte-identical to the one
/// the running process loaded (or when the runner is self-bound and has no
/// dylib file to compare — native code then lives in the runner binary and
/// cannot change through a bundle at all).
fn nativeLibraryUnchanged(listener: *Listener, scratch: std.mem.Allocator, staged_dir: []const u8, native_library_path: []const u8) !bool {
    if (std.mem.eql(u8, native_library_path, "__kira_live_self__")) return true;
    // A bundle-external (absolute) native library cannot be compared between
    // generations — the staged copy would alias the loaded file. Be
    // conservative: relaunch.
    if (std.fs.path.isAbsolute(native_library_path)) return false;
    const loaded_path = try std.fs.path.join(scratch, &.{ listener.bundle_root, native_library_path });
    const staged_path = try std.fs.path.join(scratch, &.{ staged_dir, native_library_path });
    const limit: std.Io.Limit = .limited(512 * 1024 * 1024);
    const loaded_bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, loaded_path, scratch, limit) catch return false;
    const staged_bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, staged_path, scratch, limit) catch return false;
    return std.mem.eql(u8, loaded_bytes, staged_bytes);
}

/// Write a replace_bundle payload's files under `bundle_dir` (shared with the
/// initial-bundle path in runner_support.zig).
pub fn storeBundlePayload(bundle_dir: []const u8, payload: protocol.ReplaceBundlePayload) !void {
    for (payload.files) |file| {
        const path = try std.fs.path.join(std.heap.page_allocator, &.{ bundle_dir, file.relative_path });
        defer std.heap.page_allocator.free(path);
        try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, std.fs.path.dirname(path) orelse ".");
        const out = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        defer out.close(std.Options.debug_io);
        try out.writeStreamingAll(std.Options.debug_io, file.bytes);
    }
}

fn requestNativeQuit(runtime: *hybrid_runtime.HybridRuntime) void {
    if (runtime.bridge.library) |*library| {
        if (library.lookup(RequestQuitFn, "sapp_request_quit")) |request_quit| {
            request_quit();
        }
    }
}
