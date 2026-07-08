//! Subprocess runner for devflow: run git/gh commands from the repo root and
//! capture their output. Thin wrapper over `std.process.run` so every command
//! module shares one consistent execution + error-reporting path.

const std = @import("std");

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: Output, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn ok(self: Output) bool {
        return self.term == .exited and self.term.exited == 0;
    }
};

/// Run `argv` with `cwd` as working directory and capture stdout/stderr.
/// Caller owns `Output` and must call `deinit`.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
) !Output {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(1 * 1024 * 1024),
    });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
}

/// Run a command that must succeed; return trimmed stdout on success.
/// On failure, print the command + stderr and return error.CommandFailed.
pub fn capture(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
) ![]u8 {
    const out = try run(allocator, io, cwd, argv);
    defer out.deinit(allocator);
    if (!out.ok()) {
        reportFailure(argv, out.stderr, out.term);
        return error.CommandFailed;
    }
    const trimmed = std.mem.trim(u8, out.stdout, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

/// Run a command that must succeed; discard stdout, surface stderr on failure.
pub fn check(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
) !void {
    const out = try run(allocator, io, cwd, argv);
    defer out.deinit(allocator);
    if (!out.ok()) {
        reportFailure(argv, out.stderr, out.term);
        return error.CommandFailed;
    }
}

/// Run a command and report whether it exited 0, without treating a non-zero
/// exit as an error (for probes like `gh pr view` that legitimately fail).
pub fn tryRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
) !Output {
    return run(allocator, io, cwd, argv);
}

fn reportFailure(argv: []const []const u8, stderr: []const u8, term: std.process.Child.Term) void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(std.Options.debug_io, &buf);
    const out = &w.interface;
    out.writeAll("devflow: command failed: ") catch {};
    for (argv, 0..) |arg, i| {
        if (i != 0) out.writeAll(" ") catch {};
        out.writeAll(arg) catch {};
    }
    switch (term) {
        .exited => |code| out.print(" (exit {d})\n", .{code}) catch {},
        else => out.writeAll(" (abnormal termination)\n") catch {},
    }
    if (stderr.len != 0) {
        out.writeAll(stderr) catch {};
        if (stderr[stderr.len - 1] != '\n') out.writeAll("\n") catch {};
    }
    out.flush() catch {};
}
