//! Supervisor-side hot reload: after a successful rebuild, try an IN-PLACE
//! module swap over the live connection before falling back to the process
//! relaunch flow. The runner's reload listener stages the swap; the sokol main
//! thread applies it at the next frame boundary and reports the outcome:
//!
//!   - log_line `live.reload.completed mode=hotpatch ...` — new code runs in
//!     the same process and window; app state survived.
//!   - `restart_required` frame — the native library changed; only a relaunch
//!     can pick it up.
//!   - `reload_failed` frame — the edit is hot-swap-incompatible (type layout
//!     or live-callback signature changed) or staging failed.
//!   - timeout / read failure — runner unhealthy; relaunch.
const std = @import("std");
const protocol = @import("protocol.zig");
const shared = @import("supervisor_shared.zig");

pub const HotReloadOutcome = enum {
    completed,
    restart_required,
    reload_failed,
    timed_out,
    disconnected,

    pub fn text(self: HotReloadOutcome) []const u8 {
        return switch (self) {
            .completed => "completed",
            .restart_required => "restart-required",
            .reload_failed => "reload-failed",
            .timed_out => "timed-out",
            .disconnected => "disconnected",
        };
    }
};

/// Send the rebuilt bundles over the live connection and wait for the runner
/// to apply (or reject) the in-place swap. `connection.graph` must already
/// point at the rebuilt bundle graph.
pub fn attemptHotReload(
    connection: *shared.LiveConnection,
    stdout: anytype,
    timeout_ns: u64,
) !HotReloadOutcome {
    connection.sendGraphAndBundles() catch return .disconnected;
    const start = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
    while (shared.elapsedSince(start) < timeout_ns) {
        if (connection.reader.interface.bufferedLen() == 0 and !try shared.waitReadable(connection.stream.socket.handle, 250)) continue;
        const frame = protocol.readFrame(connection.allocator, &connection.reader.interface) catch return .disconnected;
        switch (frame.kind) {
            .log_line => {
                try stdout.print("{s}\n", .{frame.payload});
                if (std.mem.startsWith(u8, frame.payload, "live.reload.completed")) return .completed;
            },
            .restart_required => {
                try shared.emitEvent(stdout, "live.reload.restart_required", "reason={s}", .{frame.payload});
                return .restart_required;
            },
            .reload_failed => {
                try shared.emitEvent(stdout, "live.reload.failed", "reason={s}", .{frame.payload});
                return .reload_failed;
            },
            else => {},
        }
    }
    return .timed_out;
}
