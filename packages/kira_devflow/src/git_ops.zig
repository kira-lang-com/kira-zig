//! Git-level operations for devflow. Every guard that keeps the fork/upstream
//! flow honest lives here: content-diff instead of ahead/behind counts, always
//! push via the SSH remote, and a post-land resync that refuses to run on a
//! dirty tree so it can never destroy uncommitted work.

const std = @import("std");
const proc = @import("proc.zig");
const Context = @import("context.zig").Context;

pub fn currentBranch(ctx: Context) ![]u8 {
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });
}

pub fn fetchRemote(ctx: Context, remote: []const u8) !void {
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "fetch", "--quiet", remote });
}

/// True when the working tree has no uncommitted changes (tracked or staged).
/// Untracked files are ignored so scratch under .codex/tmp does not block flow.
pub fn workingTreeClean(ctx: Context) !bool {
    const out = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "status", "--porcelain", "--untracked-files=no" });
    defer ctx.allocator.free(out);
    return out.len == 0;
}

pub fn stageAll(ctx: Context) !void {
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "add", "-A" });
}

/// True when there is anything staged to commit.
pub fn hasStagedChanges(ctx: Context) !bool {
    const out = try proc.tryRun(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "diff", "--cached", "--quiet" });
    defer out.deinit(ctx.allocator);
    // `--quiet` exits 0 when clean and exactly 1 when there ARE staged changes.
    // Any other exit code is a real git error (corrupt index, lock, ...) and
    // must not be silently reported as "has staged changes".
    return switch (out.term) {
        .exited => |code| switch (code) {
            0 => false,
            1 => true,
            else => error.GitDiffFailed,
        },
        else => error.GitDiffFailed,
    };
}

/// `git diff --cached --name-status` output, used to infer a commit message.
pub fn stagedNameStatus(ctx: Context) ![]u8 {
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "diff", "--cached", "--name-status" });
}

/// Commit staged changes. Signing is left to the repo/user git config and is
/// never bypassed here (no --no-gpg-sign). Fails loudly if the commit fails.
pub fn commit(ctx: Context, message: []const u8) !void {
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "commit", "-m", message });
}

/// Push `branch` to the fork over SSH. Using the SSH URL (not the https origin)
/// means a token lacking the `workflow` scope cannot reject pushes that touch
/// `.github/workflows/*` — the recurring "refusing to allow an OAuth App" error.
pub fn pushForkBranch(ctx: Context, branch: []const u8) !void {
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "push", "-u", ctx.fork_ssh_url, branch });
}

/// The content difference between two refs, as `git diff --stat`. This is the
/// ONLY honest divergence signal: ahead/behind commit counts lie after a
/// merge (a squash rewrites SHAs; a merge commit adds new ones) whereas an empty diff proves identical
/// trees. Caller owns the returned slice.
pub fn contentDiffStat(ctx: Context, a: []const u8, b: []const u8) ![]u8 {
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "diff", "--stat", a, b });
}

/// Every path changed by the complete branch, relative to its merge base with
/// `base`. This is PR scope; the working tree and the current agent session are
/// deliberately irrelevant.
pub fn branchChangedFiles(ctx: Context, base: []const u8) ![]u8 {
    const range = try std.fmt.allocPrint(ctx.allocator, "{s}...HEAD", .{base});
    defer ctx.allocator.free(range);
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "diff", "--name-only", "--diff-filter=ACDMRTUXB", range });
}

/// Subjects of every commit in the complete branch, oldest first.
pub fn branchCommitSubjects(ctx: Context, base: []const u8) ![]u8 {
    const range = try std.fmt.allocPrint(ctx.allocator, "{s}..HEAD", .{base});
    defer ctx.allocator.free(range);
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "log", "--reverse", "--format=%s", range });
}

/// True when refs `a` and `b` point at identical trees (empty content diff).
pub fn treesIdentical(ctx: Context, a: []const u8, b: []const u8) !bool {
    const stat = try contentDiffStat(ctx, a, b);
    defer ctx.allocator.free(stat);
    return stat.len == 0;
}

/// Move a branch pointer (create or force-update) without checking it out.
pub fn setBranch(ctx: Context, name: []const u8, target: []const u8) !void {
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "branch", "-f", name, target });
}

/// Single-stage flow: after a change lands on upstream, force the fork's default
/// branch to `upstream/<default>` so the fork stays a pure 0-ahead/0-behind
/// mirror. Fork `main` is unprotected and its content is already on upstream, so
/// this loses nothing. Pushed over SSH (workflow-scope proof).
pub fn mirrorForkToUpstream(ctx: Context) !void {
    try fetchRemote(ctx, "upstream");
    const refspec = try std.fmt.allocPrint(ctx.allocator, "upstream/{s}:{s}", .{ ctx.default_branch, ctx.default_branch });
    defer ctx.allocator.free(refspec);
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "push", ctx.fork_ssh_url, refspec, "--force" });
}

pub const ResyncResult = enum {
    /// Already identical — nothing to do.
    already_synced,
    /// Fast-forwarded cleanly.
    fast_forwarded,
    /// Diverged (post-merge); reset local branch to the remote after backing
    /// up the previous tip on `backup_ref`.
    reset_with_backup,
    /// Skipped because the working tree was dirty — never destroy WIP.
    skipped_dirty,
};

/// Bring the local default branch in line with `remote/<default>` after a land.
/// This is the step whose absence leaves local main stranded on pre-merge
/// commits. It refuses to touch a dirty tree, and always backs up the prior tip
/// on `backup_ref` before any reset so no committed work can be lost.
pub fn resyncLocalDefaultBranch(ctx: Context, remote: []const u8, backup_ref: []const u8) !ResyncResult {
    try fetchRemote(ctx, remote);

    const remote_ref = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ remote, ctx.default_branch });
    defer ctx.allocator.free(remote_ref);

    if (try treesIdentical(ctx, ctx.default_branch, remote_ref)) return .already_synced;

    if (!try workingTreeClean(ctx)) return .skipped_dirty;

    // Preserve the current local tip before moving it.
    try setBranch(ctx, backup_ref, ctx.default_branch);

    // Try a fast-forward first; fall back to a hard reset onto the remote.
    const branch = try currentBranch(ctx);
    defer ctx.allocator.free(branch);
    const on_default = std.mem.eql(u8, branch, ctx.default_branch);
    if (!on_default) {
        try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "switch", ctx.default_branch });
    }

    const ff = try proc.tryRun(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "merge", "--ff-only", remote_ref });
    defer ff.deinit(ctx.allocator);
    if (ff.ok()) return .fast_forwarded;

    // Diverged (post-merge). Reset to the remote; the prior tip is on backup_ref.
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "reset", "--hard", remote_ref });
    return .reset_with_backup;
}
