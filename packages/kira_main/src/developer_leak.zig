//! Leak gating for `kira test` (env `KIRA_TEST_CHECK_LEAKS=1`).
//!
//! Preserves the two guarantees the legacy `tests/` corpus driver enforced under
//! `KIRA_CORPUS_CHECK_LEAKS=1`:
//!
//!   1. VM memory report — after a suite's Test driver runs on the build-time VM
//!      (or through the hybrid bridge), the VM heap and native-layout tallies must
//!      be back to zero. The legacy driver proved this as `vm.heap.count() == 0`
//!      in unit tests; here it becomes a per-suite gate so any Test that leaks a
//!      managed/native object fails the suite with a clear line.
//!   2. Native `leaks --atExit` — a package with an `@Main` additionally builds a
//!      real LLVM-native binary whose drop elaboration must leave zero leaked
//!      allocations under macOS `leaks --atExit`. This is where the *native*
//!      backend's ownership lowering proves itself (the VM check cannot). Driven
//!      by developer_parity.zig, which owns the per-backend `@Main` run.
//!
//! A manifest-level `leakCheck` field is a deliberate follow-up (the manifest
//! `Tests { ... }` schema is owned by another workstream); the env toggle is the
//! least-collision integration point today.

const std = @import("std");
const builtin = @import("builtin");
const vm_runtime = @import("kira_vm_runtime");

/// Whether `kira test` should gate on leaks. Opt-in via `KIRA_TEST_CHECK_LEAKS`
/// (any non-empty value other than "0"/"false").
pub fn enabled() bool {
    if (!builtin.link_libc) return false;
    const raw = std.c.getenv("KIRA_TEST_CHECK_LEAKS") orelse return false;
    const value = std.mem.span(raw);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

/// Total live objects a VM still holds after a run: managed heap objects
/// (arrays/structs/closures/strings) plus native-layout materializations
/// (native arrays/structs). Zero for a leak-clean suite.
pub fn vmLiveCount(vm: *const vm_runtime.Vm) usize {
    return vm.managedObjectCount() +
        vm.native_layout_stats.arrays_current +
        vm.native_layout_stats.structs_current;
}

/// A one-line human-readable breakdown of what a leaking VM still holds, for the
/// failure line (`arrays=.. structs=.. closures=.. strings=.. nativeArrays=..
/// nativeStructs=..`). Allocator-owned.
pub fn vmLeakSummary(allocator: std.mem.Allocator, vm: *const vm_runtime.Vm) []const u8 {
    const heap = vm.heap.stats;
    const native = vm.native_layout_stats;
    return std.fmt.allocPrint(
        allocator,
        "arrays={d} structs={d} closures={d} strings={d} nativeArrays={d} nativeStructs={d}",
        .{
            heap.arrays_current,
            heap.structs_current,
            heap.closures_current,
            heap.strings_current,
            native.arrays_current,
            native.structs_current,
        },
    ) catch "live objects present";
}

pub const LeakReport = struct {
    leaked: bool,
    /// The `leaks` summary line, or the full listing / tool output on failure.
    /// Allocator-owned.
    summary: []const u8,
};

/// Whether the native `leaks --atExit` pass can run on this host. `leaks` is a
/// macOS tool; on other hosts native leak coverage belongs to that host's own
/// validation and the pass is skipped rather than faked.
pub fn nativeLeaksSupported() bool {
    return builtin.os.tag == .macos;
}

/// Run `leaks --atExit -- <executable>` in `run_cwd` and parse the verdict. A
/// found leak is a NORMAL result (`leaked = true`), not an error; errors mean the
/// tool itself could not run and are surfaced loudly (leaked = true with the
/// tool output) rather than silently passing.
pub fn runNativeLeaks(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable_path: []const u8,
    run_cwd: []const u8,
) !LeakReport {
    const child = try std.process.run(allocator, io, .{
        .argv = &.{ "leaks", "--atExit", "--", executable_path },
        .cwd = .{ .path = run_cwd },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(child.stderr);
    const leaked = leakedFromOutput(child.stdout) orelse {
        const detail = try std.fmt.allocPrint(
            allocator,
            "leaks produced no verdict\nstdout:\n{s}\nstderr:\n{s}",
            .{ child.stdout, child.stderr },
        );
        allocator.free(child.stdout);
        return .{ .leaked = true, .summary = detail };
    };
    if (!leaked) {
        const summary = try allocator.dupe(u8, summaryLine(child.stdout) orelse "0 leaks");
        allocator.free(child.stdout);
        return .{ .leaked = false, .summary = summary };
    }
    return .{ .leaked = true, .summary = child.stdout };
}

fn summaryLine(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "leaks for") != null and
            std.mem.indexOf(u8, line, "total leaked bytes") != null)
        {
            return line;
        }
    }
    return null;
}

/// null = no verdict line; otherwise whether the leak count is non-zero.
fn leakedFromOutput(output: []const u8) ?bool {
    const line = summaryLine(output) orelse return null;
    // "Process 123: 4 leaks for 128 total leaked bytes."
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const rest = std.mem.trim(u8, line[colon + 1 ..], " \t");
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const count = std.fmt.parseInt(u64, rest[0..space], 10) catch return null;
    return count != 0;
}

test "leak summary parsing" {
    try std.testing.expectEqual(@as(?bool, false), leakedFromOutput("Process 7: 0 leaks for 0 total leaked bytes.\n"));
    try std.testing.expectEqual(@as(?bool, true), leakedFromOutput("Process 7: 12 leaks for 448 total leaked bytes.\n"));
    try std.testing.expectEqual(@as(?bool, null), leakedFromOutput("no verdict here\n"));
}
