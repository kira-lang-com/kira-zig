//! devflow: repo-native automation for the fork -> PR -> review -> land ->
//! upstream -> sync flow. Each verb bakes in a guard that the previous
//! skill-only approach left to agent discretion (and therefore to drift):
//!
//!   status            content diff, never ahead/behind counts
//!   commit [-m ...]    stage all + signed commit (auto Conventional message)
//!   push               always via the fork SSH remote (workflow-scope proof)
//!   pr-scope           title/body from the complete base...HEAD branch
//!   open-fork-pr       open or refresh PR with complete-branch metadata
//!   request-reviews N  always CodeRabbit; --codex to also ping Codex
//!   wait-ci N           block until exact-head checks are green
//!   ci-failures N       print exact-head failed workflow logs
//!   blacksmith ACTION   enable, disable, or inspect Blacksmith runners
//!   review-findings N   print exact-head bot review comments
//!   wait-reviews N     block until reviewers posted + threads resolved
//!   land N             squash-as-PR (one flat entry) + resync local default branch
//!   sync               resync local default branch to the fork
//!   open-upstream-pr   fork default -> upstream default (needs upstream remote)

const std = @import("std");
const builtin = @import("builtin");
const proc = @import("proc.zig");
const context = @import("context.zig");
const commands = @import("commands.zig");
const out = @import("out.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Inherit the parent environment so spawned `git`/`gh` see the full PATH
    // (gh often lives in /opt/homebrew/bin, absent from the build's reduced PATH).
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = inheritedProcessEnviron() });
    defer io_impl.deinit();
    const io = io_impl.io();

    const args = try init.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 2) {
        usage();
        return error.MissingVerb;
    }
    const verb = args[1];
    const rest = args[2..];

    const repo_root = try proc.capture(allocator, io, ".", &.{ "git", "rev-parse", "--show-toplevel" });
    defer allocator.free(repo_root);

    const default_branch = try detectDefaultBranch(allocator, io, repo_root);
    defer allocator.free(default_branch);

    var ctx = try context.init(allocator, io, repo_root, default_branch);
    defer freeContext(allocator, &ctx);

    try dispatch(ctx, verb, rest);
}

fn dispatch(ctx: context.Context, verb: []const u8, rest: []const []const u8) !void {
    if (eq(verb, "status")) return commands.status(ctx);
    if (eq(verb, "commit")) return commands.commit(ctx, flagValue(rest, "-m"));
    if (eq(verb, "push")) return commands.push(ctx);
    if (eq(verb, "pr-scope")) return commands.prScope(ctx);
    if (eq(verb, "open-fork-pr")) return commands.openForkPr(ctx);
    if (eq(verb, "request-reviews")) return commands.requestReviews(ctx, try requireNumber(rest), hasFlag(rest, "--codex"));
    if (eq(verb, "wait-ci")) return commands.waitCi(ctx, try requireNumber(rest));
    if (eq(verb, "ci-failures")) return commands.ciFailures(ctx, try requireNumber(rest));
    if (eq(verb, "blacksmith")) return commands.blacksmith(ctx, positional(rest) orelse "status");
    if (eq(verb, "review-findings")) return commands.reviewFindings(ctx, try requireNumber(rest), hasFlag(rest, "--codex"));
    if (eq(verb, "wait-reviews")) return commands.waitReviews(ctx, try requireNumber(rest), hasFlag(rest, "--codex"));
    if (eq(verb, "land")) return commands.land(ctx, try requireNumber(rest), hasFlag(rest, "--codex"));
    if (eq(verb, "sync")) return commands.sync(ctx);
    if (eq(verb, "open-upstream-pr")) return commands.openUpstreamPr(ctx);

    usage();
    return error.UnknownVerb;
}

fn detectDefaultBranch(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) ![]u8 {
    if (proc.capture(allocator, io, repo_root, &.{ "git", "rev-parse", "--abbrev-ref", "origin/HEAD" })) |ref| {
        defer allocator.free(ref);
        if (std.mem.lastIndexOfScalar(u8, ref, '/')) |slash| {
            return allocator.dupe(u8, ref[slash + 1 ..]);
        }
    } else |_| {}
    return allocator.dupe(u8, "main");
}

fn freeContext(allocator: std.mem.Allocator, ctx: *context.Context) void {
    allocator.free(ctx.fork_slug);
    allocator.free(ctx.fork_ssh_url);
    if (ctx.upstream_slug.len != 0) allocator.free(ctx.upstream_slug);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// First non-flag argument, if any.
fn positional(rest: []const []const u8) ?[]const u8 {
    for (rest) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) return arg;
    }
    return null;
}

fn requireNumber(rest: []const []const u8) !u32 {
    const p = positional(rest) orelse {
        out.line("devflow: this verb requires a PR number");
        return error.MissingPrNumber;
    };
    return std.fmt.parseInt(u32, p, 10) catch {
        out.print("devflow: invalid PR number \"{s}\"\n", .{p});
        return error.InvalidPrNumber;
    };
}

fn hasFlag(rest: []const []const u8, name: []const u8) bool {
    for (rest) |arg| if (eq(arg, name)) return true;
    return false;
}

/// Value following `name` (e.g. `-m "subject"`), or null.
fn flagValue(rest: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (eq(rest[i], name) and i + 1 < rest.len) return rest[i + 1];
    }
    return null;
}

fn inheritedProcessEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        .wasi, .emscripten, .freestanding, .other => .empty,
        else => .{ .block = .{ .slice = currentPosixEnvironBlock() } },
    };
}

fn currentPosixEnvironBlock() [:null]const ?[*:0]const u8 {
    if (!builtin.link_libc) return &.{};
    const environ = std.c.environ;
    var len: usize = 0;
    while (environ[len] != null) : (len += 1) {}
    return environ[0..len :null];
}

fn usage() void {
    out.line(
        \\devflow — fork/upstream PR flow automation
        \\
        \\usage: devflow <verb> [args]
        \\
        \\  status                     content diff (fork vs upstream, local vs fork)
        \\  commit [-m "subject"]      stage all + signed commit (auto message if no -m)
        \\  push                       push current branch to the fork over SSH
        \\  pr-scope                   print title/body derived from complete branch scope
        \\  open-fork-pr               open or refresh ONE PR with complete-branch metadata
        \\  request-reviews <pr> [--codex]
        \\  wait-ci <pr>                block until exact-head checks are green
        \\  ci-failures <pr>            print exact-head failed workflow logs
        \\  blacksmith [enable|disable|status]
        \\  review-findings <pr> [--codex]
        \\  wait-reviews <pr> [--codex]
        \\  land <pr> [--codex]        squash-merge upstream PR (merge subject) + mirror fork + resync
        \\  sync                       resync local default branch to the fork
        \\  open-upstream-pr           fork default -> upstream default with complete-branch metadata
    );
}
