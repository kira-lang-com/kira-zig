// Native leak checking for corpus run phases: re-runs the case's LLVM binary
// under macOS `leaks --atExit` and reports any leaked allocations as a phase
// failure. Opt-in per case with top-level `check_leaks = true` in expect.toml,
// or for every runnable llvm case with KIRA_CORPUS_CHECK_LEAKS=1.
//
// Scope: the LLVM run phase only. The VM asserts its own heap cleanup in unit
// tests (vm.heap.count() == 0) and a VM/hybrid process's allocator behavior is
// not the program-under-test's ownership model; the native binary is where the
// backend's drop elaboration must prove itself.
//
// Platform: `leaks` is a macOS tool. On other hosts the check is skipped —
// dedicated leak coverage for those hosts belongs in their platform validation
// matrix, and the ownership model under test is host-independent.
const std = @import("std");
const builtin = @import("builtin");

pub const LeakReport = struct {
    leaked: bool,
    // The `leaks` summary line ("Process N: X leaks for Y total leaked bytes.")
    // plus the leak listing when leaks were found. Allocator-owned.
    summary: []const u8,
};

// Whether the llvm run phase should be followed by a leak pass for this case.
pub fn enabledFor(case_check_leaks: bool) bool {
    if (builtin.os.tag != .macos) return false;
    if (case_check_leaks) return true;
    const raw = std.c.getenv("KIRA_CORPUS_CHECK_LEAKS") orelse return false;
    const value = std.mem.span(raw);
    return value.len != 0 and value[0] != '0';
}

// Run `leaks --atExit -- <executable>` in `run_cwd` and parse the verdict.
// A found leak is a NORMAL result (leaked = true), not an error; errors mean
// the tool itself could not run (missing binary, spawn failure) and should
// fail the case loudly rather than silently skipping the check.
pub fn run(
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
        // No summary line: `leaks` itself failed (e.g. the target crashed before
        // atExit or the tool errored). Surface its output as the failure.
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

// null = no verdict line found; otherwise whether the leak count is non-zero.
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
