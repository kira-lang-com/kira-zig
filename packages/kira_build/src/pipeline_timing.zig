const std = @import("std");
const builtin = @import("builtin");
const program_graph = @import("kira_program_graph");
const llvm_backend = @import("kira_llvm_backend");

var timings_enabled: bool = false;
var progress_context: ?*anyopaque = null;
var progress_callback: ?*const fn (?*anyopaque, []const u8) void = null;

/// Installs the leaf-CLI progress sink. Compiler packages only publish phase
/// events; terminal detection and rendering remain the CLI's responsibility.
pub fn setProgressCallback(context: ?*anyopaque, callback: ?*const fn (?*anyopaque, []const u8) void) void {
    progress_context = context;
    progress_callback = callback;
    program_graph.setProgressCallback(context, callback);
    llvm_backend.setProgressCallback(context, callback);
}

pub fn progressActive() bool {
    return progress_callback != null;
}

pub fn emitProgress(message: []const u8) void {
    if (progress_callback) |callback| callback(progress_context, message);
}

pub fn progressPrint(comptime fmt: []const u8, args: anytype) void {
    const callback = progress_callback orelse return;
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    callback(progress_context, message);
}

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

test "live progress is published independently of timing diagnostics" {
    const Capture = struct {
        var text: []const u8 = "";

        fn receive(_: ?*anyopaque, event: []const u8) void {
            text = event;
        }
    };

    const previous_timings = timings_enabled;
    defer timings_enabled = previous_timings;
    timings_enabled = false;
    setProgressCallback(null, Capture.receive);
    defer setProgressCallback(null, null);

    progressPrint("Parsing {s}", .{"app/main.kira"});
    try std.testing.expectEqualStrings("Parsing app/main.kira", Capture.text);
}
