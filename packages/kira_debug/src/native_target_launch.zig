//! native_target_launch — launch a native inferior *stopped*, ready for a
//! `HwBreakpointController` to attach.
//!
//! Two platform strategies (per the task), both leaving the process stopped
//! before it runs meaningful user code so breakpoints can be armed deterministically:
//!
//!   * **Linux** — `fork()`; the child `raise(SIGSTOP)`s and then `execvpe`s the
//!     target. The parent reaps the group-stop with `waitpid(WUNTRACED)`. The
//!     process is now stopped *before* exec, so `HwBreakpointController.attach`
//!     (which uses `PTRACE_ATTACH`) can adopt it cleanly; a single subsequent
//!     continue runs it through `exec` to its real entry with `.text` mapped
//!     (`needs_run_to_entry = true`). Using SIGSTOP-before-exec — rather than
//!     `PTRACE_TRACEME` in the child — is deliberate: `TRACEME` would make the
//!     child already-traced and the controller's `PTRACE_ATTACH` would then fail
//!     `EPERM`. The two must agree, and the controllers are `ATTACH`-based.
//!
//!   * **macOS** — `posix_spawn` with `POSIX_SPAWN_START_SUSPENDED`. The task is
//!     created and the Mach-O image mapped, but the main thread is suspended, so
//!     `task_for_pid` (in the Darwin controller's `attach`) sees a stable,
//!     inspectable address space (`needs_run_to_entry = false`). Cross-process
//!     run-control on macOS additionally requires the `com.apple.security.cs.debugger`
//!     entitlement (or root); `attach` reports `PermissionDenied` honestly when
//!     the kernel refuses, and this module never fabricates a running inferior.
//!
//! Every other target (wasm, windows, unknown) has no repo-native launch path
//! and returns `error.Unsupported` — the session degrades with a diagnostic
//! instead of pretending to debug.

const std = @import("std");
const builtin = @import("builtin");

pub const LaunchError = error{
    /// This platform has no native launch mechanism (wasm/windows/unknown).
    Unsupported,
    /// fork/posix_spawn or the subsequent wait failed.
    SpawnFailed,
    /// argv was empty — nothing to launch.
    NoProgram,
} || std.mem.Allocator.Error;

/// A launched-but-stopped inferior.
pub const Launched = struct {
    pid: i32,
    /// True when the inferior is stopped *before* running its own entry and must
    /// be continued once (post-attach) to reach it. Linux sets this; macOS's
    /// suspended spawn leaves the image already mapped so it is false.
    needs_run_to_entry: bool,
};

/// Launch `argv[0]` with `argv` as its arguments, stopped, per the platform
/// strategy documented above. `gpa` backs the transient C-string arrays.
pub fn launchStopped(gpa: std.mem.Allocator, argv: []const []const u8) LaunchError!Launched {
    if (argv.len == 0) return LaunchError.NoProgram;
    return switch (builtin.os.tag) {
        .linux => linuxLaunch(gpa, argv),
        .macos => darwinLaunch(gpa, argv),
        else => LaunchError.Unsupported,
    };
}

// ---------------------------------------------------------------------------
// C-string array helpers (null-terminated argv/envp for exec/spawn).
// ---------------------------------------------------------------------------

/// Build a `[:null]?[*:0]const u8` from `items`, dup'ing each into `arena`.
fn dupeArgv(arena: std.mem.Allocator, items: []const []const u8) ![:null]?[*:0]const u8 {
    const out = try arena.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, 0..) |s, i| out[i] = try arena.dupeZ(u8, s);
    return out;
}

/// Snapshot the current environment as a null-terminated array for exec/spawn.
/// Zig 0.16's std dropped `std.os.environ`; kira_debug links libc, so we read the
/// libc `environ` global directly.
fn currentEnvp(arena: std.mem.Allocator) ![:null]?[*:0]const u8 {
    const env = std.mem.span(std.c.environ);
    const out = try arena.allocSentinel(?[*:0]const u8, env.len, null);
    for (env, 0..) |e, i| out[i] = e;
    return out;
}

// ---------------------------------------------------------------------------
// Linux: fork + SIGSTOP-before-exec.
// ---------------------------------------------------------------------------

fn linuxLaunch(gpa: std.mem.Allocator, argv: []const []const u8) LaunchError!Launched {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path0 = try arena.dupeZ(u8, argv[0]);
    const child_argv = try dupeArgv(arena, argv);
    const envp = try currentEnvp(arena);

    const pid = std.posix.fork() catch return LaunchError.SpawnFailed;
    if (pid == 0) {
        // Child: stop before exec so the tracer can PTRACE_ATTACH, then exec.
        std.posix.raise(std.posix.SIG.STOP) catch {};
        const err = std.posix.execvpeZ(path0, child_argv.ptr, envp.ptr);
        // Only reached if exec failed.
        _ = err;
        std.posix.exit(127);
    }

    // Parent: reap the SIGSTOP group-stop so the inferior is known-stopped.
    _ = std.posix.waitpid(pid, W_UNTRACED);
    return .{ .pid = @intCast(pid), .needs_run_to_entry = true };
}

// `WUNTRACED`: also report children stopped (not only terminated).
const W_UNTRACED: u32 = 2;

// ---------------------------------------------------------------------------
// macOS: posix_spawn(START_SUSPENDED).
// ---------------------------------------------------------------------------

const POSIX_SPAWN_START_SUSPENDED: c_short = 0x0080;

const posix_spawnattr_t = ?*anyopaque;

extern "c" fn posix_spawnattr_init(attr: *posix_spawnattr_t) c_int;
extern "c" fn posix_spawnattr_destroy(attr: *posix_spawnattr_t) c_int;
extern "c" fn posix_spawnattr_setflags(attr: *posix_spawnattr_t, flags: c_short) c_int;
extern "c" fn posix_spawn(
    pid: *c_int,
    path: [*:0]const u8,
    file_actions: ?*anyopaque,
    attrp: ?*posix_spawnattr_t,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;

fn darwinLaunch(gpa: std.mem.Allocator, argv: []const []const u8) LaunchError!Launched {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path0 = try arena.dupeZ(u8, argv[0]);
    const child_argv = try dupeArgv(arena, argv);
    const envp = try currentEnvp(arena);

    var attr: posix_spawnattr_t = null;
    if (posix_spawnattr_init(&attr) != 0) return LaunchError.SpawnFailed;
    defer _ = posix_spawnattr_destroy(&attr);
    if (posix_spawnattr_setflags(&attr, POSIX_SPAWN_START_SUSPENDED) != 0)
        return LaunchError.SpawnFailed;

    var pid: c_int = 0;
    const rc = posix_spawn(&pid, path0, null, &attr, child_argv.ptr, envp.ptr);
    if (rc != 0 or pid <= 0) return LaunchError.SpawnFailed;

    // The image is mapped but the main thread is suspended: no run-to-entry step.
    return .{ .pid = @intCast(pid), .needs_run_to_entry = false };
}

// ---------------------------------------------------------------------------
// Tests — behavior that is host-independent (argument validation) plus the
// C-string array helpers. Real spawning is exercised by the integration stage's
// native-debug corpus, not here (this file must ast-check and unit-test on any
// host without launching processes).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "launchStopped rejects an empty argv" {
    try testing.expectError(LaunchError.NoProgram, launchStopped(testing.allocator, &.{}));
}

test "dupeArgv produces a null-terminated, order-preserving array" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = [_][]const u8{ "a.out", "--flag", "value" };
    const argv = try dupeArgv(arena, &items);

    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqual(@as(?[*:0]const u8, null), argv[argv.len]); // sentinel
    for (items, 0..) |want, i| {
        try testing.expectEqualStrings(want, std.mem.span(argv[i].?));
    }
}

test "currentEnvp mirrors the process environment length and is null-terminated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const envp = try currentEnvp(arena);
    try testing.expectEqual(std.os.environ.len, envp.len);
    try testing.expectEqual(@as(?[*:0]const u8, null), envp[envp.len]);
}
