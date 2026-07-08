//! devflow verb implementations. Each function is a thin orchestration of
//! git_ops/gh_ops with the flow guards made structural: push is always SSH,
//! land is always squash-as-PR (one flat entry, merge-style subject) + resync, status never trusts ahead/behind counts,
//! and upstream PRs are refused until the fork PR has actually merged.

const std = @import("std");
const Context = @import("context.zig").Context;
const git = @import("git_ops.zig");
const gh = @import("gh_ops.zig");
const commit_msg = @import("commit_msg.zig");
const out = @import("out.zig");

const poll_interval_ns: u64 = 30 * std.time.ns_per_s;
/// Default wait cap: 8 minutes. Override (seconds) with KIRA_DEVFLOW_WAIT_SECS.
/// A short cap is deliberate — reviews that need longer should be re-checked,
/// not blocked on for the better part of an hour.
const default_wait_secs: u64 = 8 * 60;

fn waitTimeoutNs() u64 {
    const raw = std.c.getenv("KIRA_DEVFLOW_WAIT_SECS") orelse return default_wait_secs * std.time.ns_per_s;
    const secs = std.fmt.parseInt(u64, std.mem.span(raw), 10) catch return default_wait_secs * std.time.ns_per_s;
    return secs * std.time.ns_per_s;
}

/// `status`: honest divergence via content diff, never commit counts.
pub fn status(ctx: Context) !void {
    try git.fetchRemote(ctx, "origin");
    if (ctx.hasUpstream()) try git.fetchRemote(ctx, "upstream");

    const fork_ref = try std.fmt.allocPrint(ctx.allocator, "origin/{s}", .{ctx.default_branch});
    defer ctx.allocator.free(fork_ref);

    out.line("devflow status (content diff — commit counts are ignored on purpose)");

    if (ctx.hasUpstream()) {
        const up_ref = try std.fmt.allocPrint(ctx.allocator, "upstream/{s}", .{ctx.default_branch});
        defer ctx.allocator.free(up_ref);
        try reportPair(ctx, "fork vs upstream", fork_ref, up_ref);
    }
    try reportPair(ctx, "local vs fork", ctx.default_branch, fork_ref);
}

/// Single-stage: the PR lives on upstream when there is an upstream remote
/// (the owner is a maintainer, so there is one landing — on upstream). Falls
/// back to the fork only when no upstream remote is configured.
fn prSlug(ctx: Context) []const u8 {
    return if (ctx.hasUpstream()) ctx.upstream_slug else ctx.fork_slug;
}

fn reportPair(ctx: Context, label: []const u8, a: []const u8, b: []const u8) !void {
    const stat = try git.contentDiffStat(ctx, a, b);
    defer ctx.allocator.free(stat);
    if (stat.len == 0) {
        out.print("  {s}: IDENTICAL ({s} == {s})\n", .{ label, a, b });
    } else {
        out.print("  {s}: DIFFERS ({s} vs {s})\n{s}\n", .{ label, a, b, stat });
    }
}

/// `commit [-m subject]`: stage everything, commit signed. Auto-infers a
/// Conventional Commit subject when `-m` is not supplied.
pub fn commit(ctx: Context, explicit_message: ?[]const u8) !void {
    try git.stageAll(ctx);
    if (!try git.hasStagedChanges(ctx)) {
        out.line("devflow: nothing to commit");
        return;
    }

    var owned_message: ?[]u8 = null;
    defer if (owned_message) |m| ctx.allocator.free(m);

    const message = explicit_message orelse blk: {
        const name_status = try git.stagedNameStatus(ctx);
        defer ctx.allocator.free(name_status);
        owned_message = try commit_msg.infer(ctx.allocator, name_status);
        break :blk owned_message.?;
    };

    try git.commit(ctx, message);
    out.print("devflow: committed \"{s}\"\n", .{message});
}

/// `push`: push the current branch to the fork over SSH (workflow-scope proof).
pub fn push(ctx: Context) !void {
    const branch = try git.currentBranch(ctx);
    defer ctx.allocator.free(branch);
    if (std.mem.eql(u8, branch, "HEAD")) return error.DetachedHead;
    try git.pushForkBranch(ctx, branch);
    out.print("devflow: pushed {s} to {s}\n", .{ branch, ctx.fork_ssh_url });
}

/// `open-pr [title]`: open ONE PR against upstream (single-stage) from the
/// current branch. With no upstream remote, opens a fork-internal PR instead.
pub fn openForkPr(ctx: Context, title_opt: ?[]const u8) !void {
    const branch = try git.currentBranch(ctx);
    defer ctx.allocator.free(branch);

    const title = title_opt orelse branch;
    if (ctx.hasUpstream()) {
        // Idempotent: if the upstream PR for this branch already exists (retry/
        // resume), report it instead of erroring on `gh pr create`.
        if (try gh.prNumberOn(ctx, ctx.upstream_slug, branch)) |existing| {
            out.print("devflow: PR #{d} already open on {s} for {s}\n", .{ existing, ctx.upstream_slug, branch });
            return;
        }
        const number = try gh.openUpstreamPr(ctx, ctx.fork_slug, ctx.default_branch, branch, title);
        out.print("devflow: opened PR #{d} on {s} ({s}:{s} -> {s})\n", .{ number, ctx.upstream_slug, ownerLogin(ctx.fork_slug), branch, ctx.default_branch });
        return;
    }
    if (try gh.prNumberForBranch(ctx, branch)) |existing| {
        out.print("devflow: PR #{d} already open for {s}\n", .{ existing, branch });
        return;
    }
    const number = try gh.openForkPr(ctx, ctx.default_branch, branch, title);
    out.print("devflow: opened fork PR #{d} ({s} -> {s})\n", .{ number, branch, ctx.default_branch });
}

fn ownerLogin(slug: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, slug, '/') orelse return slug;
    return slug[0..slash];
}

/// `request-reviews <pr> [--codex]`: always ping CodeRabbit; Codex only on demand.
pub fn requestReviews(ctx: Context, number: u32, ping_codex: bool) !void {
    const slug = prSlug(ctx);
    try gh.comment(ctx, slug, number, "@coderabbitai review");
    out.print("devflow: requested CodeRabbit review on #{d}\n", .{number});
    if (ping_codex) {
        try gh.comment(ctx, slug, number, "@codex review");
        out.print("devflow: requested Codex review on #{d}\n", .{number});
    }
}

/// `wait-reviews <pr> [--codex]`: block until required reviewers have posted and
/// no unresolved review threads remain. This is the gate that stops the flow
/// advancing while findings are still open.
pub fn waitReviews(ctx: Context, number: u32, require_codex: bool) !void {
    var waited: u64 = 0;
    const timeout_ns = waitTimeoutNs();
    const slug = prSlug(ctx);
    while (true) {
        // Gate on SUBMITTED reviews, not comments: a bot walkthrough comment or
        // a rate-limited/incomplete review must not read as "reviewed".
        const logins = try gh.reviewerLogins(ctx, slug, number);
        defer ctx.allocator.free(logins);
        const has_rabbit = std.mem.indexOf(u8, logins, "coderabbit") != null;
        const has_codex = std.mem.indexOf(u8, logins, "codex") != null;
        const reviewers_seen = has_rabbit and (!require_codex or has_codex);

        if (reviewers_seen) {
            const unresolved = try gh.unresolvedThreadCount(ctx, slug, number);
            if (unresolved == 0) {
                out.print("devflow: reviews complete on #{d}, no unresolved threads\n", .{number});
                return;
            }
            out.print("devflow: #{d} has {d} unresolved review thread(s); waiting...\n", .{ number, unresolved });
        } else {
            out.print("devflow: waiting for reviews on #{d} (seen: {s})\n", .{ number, logins });
        }

        if (waited >= timeout_ns) return error.ReviewWaitTimeout;
        try ctx.io.sleep(.fromNanoseconds(poll_interval_ns), .awake);
        waited += poll_interval_ns;
    }
}

/// `land <pr> [--codex]`: refuse unless the required reviewers have SUBMITTED a
/// review and no threads are unresolved, then land as one squash commit with a "Merge pull request #N from ..." subject and resync the local
/// default branch. Checking only unresolved-thread-count is unsafe: it is 0
/// before reviews post, so land must apply the same participant gate as
/// wait-reviews (Codex P2: "Require reviewer completion before merging").
pub fn land(ctx: Context, number: u32, require_codex: bool) !void {
    const slug = prSlug(ctx);
    const logins = try gh.reviewerLogins(ctx, slug, number);
    defer ctx.allocator.free(logins);
    const has_rabbit = std.mem.indexOf(u8, logins, "coderabbit") != null;
    const has_codex = std.mem.indexOf(u8, logins, "codex") != null;
    if (!(has_rabbit and (!require_codex or has_codex))) {
        out.print("devflow: refusing to land #{d}: required review not submitted yet (submitted: {s})\n", .{ number, logins });
        return error.ReviewsPending;
    }

    const unresolved = try gh.unresolvedThreadCount(ctx, slug, number);
    if (unresolved != 0) {
        out.print("devflow: refusing to land #{d}: {d} unresolved review thread(s)\n", .{ number, unresolved });
        return error.UnresolvedReviews;
    }

    try gh.landAsPullRequest(ctx, slug, number);
    out.print("devflow: landed PR #{d} on {s} (squash, 'Merge pull request' subject)\n", .{ number, slug });

    // Single-stage: keep the fork a pure mirror of upstream so it never diverges.
    if (ctx.hasUpstream()) {
        try git.mirrorForkToUpstream(ctx);
        out.print("devflow: mirrored fork {s} to upstream/{s}\n", .{ ctx.default_branch, ctx.default_branch });
    }

    const backup = try std.fmt.allocPrint(ctx.allocator, "devflow/prelanded-{s}", .{ctx.default_branch});
    defer ctx.allocator.free(backup);

    const result = try git.resyncLocalDefaultBranch(ctx, "origin", backup);
    switch (result) {
        .already_synced => out.line("devflow: local branch already in sync with fork"),
        .fast_forwarded => out.print("devflow: local {s} fast-forwarded to origin\n", .{ctx.default_branch}),
        .reset_with_backup => out.print(
            "devflow: local {s} reset to origin (post-merge); prior tip backed up on {s}\n",
            .{ ctx.default_branch, backup },
        ),
        .skipped_dirty => out.line(
            "devflow: WARNING working tree dirty — local branch NOT resynced (commit/stash then re-run `devflow sync`)",
        ),
    }
}

/// `sync`: resync the local default branch to the fork remote (standalone,
/// for when a land happened elsewhere and local main drifted).
pub fn sync(ctx: Context) !void {
    const backup = try std.fmt.allocPrint(ctx.allocator, "devflow/presync-{s}", .{ctx.default_branch});
    defer ctx.allocator.free(backup);
    const result = try git.resyncLocalDefaultBranch(ctx, "origin", backup);
    switch (result) {
        .already_synced => out.line("devflow: already in sync"),
        .fast_forwarded => out.print("devflow: fast-forwarded {s} to origin\n", .{ctx.default_branch}),
        .reset_with_backup => out.print("devflow: reset {s} to origin; prior tip on {s}\n", .{ ctx.default_branch, backup }),
        .skipped_dirty => out.line("devflow: working tree dirty — not touched"),
    }
}

/// `open-upstream-pr [title]`: only valid after the fork PR has merged and the
/// fork default branch matches upstream-ready content. Refuses without upstream.
pub fn openUpstreamPr(ctx: Context, title_opt: ?[]const u8) !void {
    if (!ctx.hasUpstream()) {
        out.line("devflow: no `upstream` remote configured");
        return error.NoUpstream;
    }
    try git.fetchRemote(ctx, "origin");

    const title = title_opt orelse ctx.default_branch;
    const number = try gh.openUpstreamPr(ctx, ctx.fork_slug, ctx.default_branch, ctx.default_branch, title);
    out.print("devflow: opened upstream PR #{d} ({s}:{s} -> {s}:{s})\n", .{
        number, ctx.fork_slug, ctx.default_branch, ctx.upstream_slug, ctx.default_branch,
    });
}
