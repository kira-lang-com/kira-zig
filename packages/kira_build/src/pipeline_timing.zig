const std = @import("std");
const builtin = @import("builtin");
const program_graph = @import("kira_program_graph");

var timings_enabled: bool = false;

pub fn setTimingsEnabled(enabled: bool) void {
    timings_enabled = enabled;
    program_graph.setTimingsEnabled(enabled);
}

pub fn timingsEnabled() bool {
    return timings_enabled;
}

// Monotonic clock. Previously this returned 0 on non-Windows, so every `elapsedNs`
// on macOS/Linux measured as zero and all pipeline phase timings were silently fake —
// making frontend/codegen attribution impossible. Now uses the same std.Io.Clock the
// build system uses, on every platform.
pub fn nowNs() i128 {
    return std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.toNanoseconds();
}

pub fn elapsedNs(start: i128) u64 {
    return @intCast(@max(nowNs() - start, 0));
}

pub fn timingPrint(comptime fmt: []const u8, args: anytype) void {
    if (timings_enabled) std.debug.print(fmt, args);
}
