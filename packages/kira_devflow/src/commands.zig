//! devflow verb implementations. Each function is a thin orchestration of
//! git_ops/gh_ops with the flow guards made structural: push is always SSH,
//! land is always squash-as-PR (one flat entry, merge-style subject) + resync, status never trusts ahead/behind counts,
//! and upstream PRs are refused until the fork PR has actually merged.

const std = @import("std");
const Context = @import("context.zig").Context;
const git = @import("git_ops.zig");
const gh = @import("gh_ops.zig");
const commit_msg = @import("commit_msg.zig");
const pr_scope = @import("pr_scope.zig");
const out = @import("out.zig");

const poll_interval_ns: u64 = 30 * std.time.ns_per_s;

/// Wait verbs return after this long instead of polling forever: a bounded wait
/// surfaces stuck gates (review never re-requested, hung workflow) to the
/// caller, who restarts the same verb to keep waiting.
const wait_timeout_ns: u64 = 5 * std.time.ns_per_min;

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

    const branch = try git.currentBranch(ctx);
    defer ctx.allocator.free(branch);
    const head = try git.headOid(ctx);
    defer ctx.allocator.free(head);
    out.print("  active head: {s} {s}\n", .{ branch, head });
    const working_tree = try git.workingTreeSummary(ctx);
    defer ctx.allocator.free(working_tree);
    if (working_tree.len == 0) {
        out.line("  working tree: CLEAN");
    } else {
        out.print("  working tree: CHANGES\n{s}\n", .{working_tree});
    }
    if (!std.mem.eql(u8, branch, ctx.default_branch) and !std.mem.eql(u8, branch, "HEAD")) {
        const fork_branch_ref = try std.fmt.allocPrint(ctx.allocator, "origin/{s}", .{branch});
        defer ctx.allocator.free(fork_branch_ref);
        try reportPair(ctx, "active branch vs fork", "HEAD", fork_branch_ref);
    }
}

/// `wait-ci <pr>`: block on the checks attached to the PR's exact current head.
pub fn waitCi(ctx: Context, number: u32) !void {
    const slug = prSlug(ctx);
    const head = try gh.prHeadOid(ctx, slug, number);
    defer ctx.allocator.free(head);
    out.print("devflow: waiting for CI on #{d} exact head {s}\n", .{ number, head });

    var waited_ns: u64 = 0;
    while (true) {
        const current_head = try gh.prHeadOid(ctx, slug, number);
        defer ctx.allocator.free(current_head);
        if (!std.mem.eql(u8, head, current_head)) {
            out.print("devflow: PR #{d} head changed while waiting ({s} -> {s}); restart the exact-head gate\n", .{ number, head, current_head });
            return error.PrHeadChanged;
        }
        const checks = try gh.prCheckStatus(ctx, slug, number);
        defer checks.deinit(ctx.allocator);
        if (checks.failing != 0) {
            out.print("devflow: CI failed on #{d} ({d} failing check(s))\n{s}\n", .{ number, checks.failing, checks.lines });
            return error.CiFailed;
        }
        if (checks.green()) {
            out.print("devflow: CI green on #{d} exact head {s} ({d} checks)\n", .{ number, head, checks.total });
            return;
        }
        if (checks.total == 0) {
            out.print("devflow: #{d} has no checks on exact head yet; waiting...\n", .{number});
        } else {
            out.print("devflow: #{d} has {d} pending check(s)\n{s}\n", .{ number, checks.pending, checks.lines });
        }
        if (waited_ns >= wait_timeout_ns) {
            out.print("devflow: wait-ci timed out after 5m with the gate still pending; re-run `devflow wait-ci {d}` to keep polling\n", .{number});
            return error.WaitTimedOut;
        }
        try ctx.io.sleep(.fromNanoseconds(poll_interval_ns), .awake);
        waited_ns += poll_interval_ns;
    }
}

/// `review-findings <pr> [--codex]`: print exact-head inline findings without
/// bypassing devflow for ad-hoc GitHub reads.
pub fn reviewFindings(ctx: Context, number: u32, include_codex: bool) !void {
    const findings = try gh.headReviewFindings(ctx, prSlug(ctx), number, include_codex);
    defer ctx.allocator.free(findings);
    if (findings.len == 0) {
        out.print("devflow: no exact-head inline findings on #{d}\n", .{number});
        return;
    }
    out.print("devflow: exact-head inline findings on #{d}\n{s}\n", .{ number, findings });
}

/// `ci-failures <pr>`: print failed job logs for workflow runs attached to the
/// PR's exact current head.
pub fn ciFailures(ctx: Context, number: u32) !void {
    const slug = prSlug(ctx);
    const head = try gh.prHeadOid(ctx, slug, number);
    defer ctx.allocator.free(head);
    const run_ids = try gh.runIdsForHead(ctx, slug, head);
    defer ctx.allocator.free(run_ids);
    if (run_ids.len == 0) {
        out.print("devflow: no workflow runs on #{d} exact head {s}\n", .{ number, head });
        return;
    }

    var found = false;
    var ids = std.mem.splitScalar(u8, run_ids, '\n');
    while (ids.next()) |run_id| {
        if (run_id.len == 0) continue;
        const job_ids = try gh.failedJobIdsForRun(ctx, slug, run_id);
        defer ctx.allocator.free(job_ids);
        var jobs = std.mem.splitScalar(u8, job_ids, '\n');
        while (jobs.next()) |job_id| {
            if (job_id.len == 0) continue;
            found = true;
            const log = try gh.failedJobLog(ctx, slug, run_id, job_id);
            defer ctx.allocator.free(log);
            const excerpt = try failureExcerpt(ctx.allocator, log);
            defer ctx.allocator.free(excerpt);
            out.print("devflow: failed CI excerpt for #{d} exact head {s}, run {s}, job {s}\n{s}\n", .{ number, head, run_id, job_id, excerpt });
        }
    }
    if (!found) out.print("devflow: no failed jobs on #{d} exact head {s}\n", .{ number, head });
}

fn failureExcerpt(allocator: std.mem.Allocator, log: []const u8) ![]u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    errdefer result.deinit();
    var lines = std.mem.splitScalar(u8, log, '\n');
    var emitted: usize = 0;
    var parity_context: usize = 0;
    while (lines.next()) |line| {
        const relevant = failureRelevant(line);
        if (std.mem.indexOf(u8, line, "FAIL <parity") != null) parity_context = 40;
        if (!relevant and parity_context == 0) continue;
        try result.writer.print("{s}\n", .{line});
        if (!relevant and parity_context != 0) parity_context -= 1;
        emitted += 1;
        if (emitted == 400) {
            try result.writer.writeAll("... failure excerpt capped at 400 matching lines ...\n");
            break;
        }
    }
    if (emitted == 0) try result.writer.writeAll("(job failed without a matching error line; inspect the job URL from ci-runners)\n");
    return result.toOwnedSlice();
}

fn failureRelevant(line: []const u8) bool {
    const needles = [_][]const u8{
        "##[error]",                        " error:",                     "error[",   "failed", "FAIL ",             "ExternalCommandFailed",
        "undefined reference",              "linker",                      "clang:",   "lld:",   "kira llvm backend", "/usr/bin/x86_64-linux-gnu-ld:",
        "Process completed with exit code", "A connection attempt failed", "dial tcp", "LNK",
    };
    for (needles) |needle| if (std.mem.indexOf(u8, line, needle) != null) return true;
    return false;
}

/// `ci-runners <pr>`: report the actual runner assigned to every job attached
/// to the PR's exact current head, including the requested runner labels.
pub fn ciRunners(ctx: Context, number: u32) !void {
    const slug = prSlug(ctx);
    const head = try gh.prHeadOid(ctx, slug, number);
    defer ctx.allocator.free(head);
    const run_ids = try gh.runIdsForHead(ctx, slug, head);
    defer ctx.allocator.free(run_ids);
    if (run_ids.len == 0) {
        out.print("devflow: no workflow runs on #{d} exact head {s}\n", .{ number, head });
        return;
    }

    out.print("devflow: CI runners on #{d} exact head {s}\n", .{ number, head });
    var ids = std.mem.splitScalar(u8, run_ids, '\n');
    while (ids.next()) |run_id| {
        if (run_id.len == 0) continue;
        const details = try gh.workflowRunnerDetails(ctx, slug, run_id);
        defer ctx.allocator.free(details);
        if (details.len == 0) {
            out.print("  run {s}: jobs have not been created yet\n", .{run_id});
        } else {
            out.print("  run {s}\n{s}\n", .{ run_id, details });
        }
    }
}

/// `rerun-ci <pr>`: rerun every completed workflow attached to the PR's exact
/// head. Useful after changing repository runner-provider configuration.
pub fn rerunCi(ctx: Context, number: u32) !void {
    const slug = prSlug(ctx);
    const head = try gh.prHeadOid(ctx, slug, number);
    defer ctx.allocator.free(head);
    const run_ids = try gh.completedRunIdsForHead(ctx, slug, head);
    defer ctx.allocator.free(run_ids);
    if (run_ids.len == 0) {
        out.print("devflow: no completed workflow runs to rerun on #{d} exact head {s}\n", .{ number, head });
        return;
    }
    var ids = std.mem.splitScalar(u8, run_ids, '\n');
    while (ids.next()) |run_id| {
        if (run_id.len == 0) continue;
        try gh.rerunWorkflow(ctx, slug, run_id);
        out.print("devflow: reran workflow {s} on #{d} exact head {s}\n", .{ run_id, number, head });
    }
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

/// `pr-scope`: print metadata computed from the complete branch.
pub fn prScope(ctx: Context) !void {
    const metadata = try pr_scope.generate(ctx);
    defer metadata.deinit(ctx.allocator);
    out.print("{s}\n\n{s}", .{ metadata.title, metadata.body });
}

/// `open-pr`: open ONE PR against upstream (single-stage) from the current
/// branch, or refresh an existing PR. Title and body always come from the
/// complete base...HEAD branch inventory.
pub fn openForkPr(ctx: Context) !void {
    const branch = try git.currentBranch(ctx);
    defer ctx.allocator.free(branch);
    const metadata = try pr_scope.generate(ctx);
    defer metadata.deinit(ctx.allocator);

    if (ctx.hasUpstream()) {
        // Idempotent: if the upstream PR for this branch already exists (retry/
        // resume), report it instead of erroring on `gh pr create`.
        if (try gh.prNumberOn(ctx, ctx.upstream_slug, branch)) |existing| {
            try gh.updatePr(ctx, ctx.upstream_slug, existing, metadata.title, metadata.body);
            out.print("devflow: refreshed PR #{d} on {s} from complete branch scope\n", .{ existing, ctx.upstream_slug });
            return;
        }
        const number = try gh.openUpstreamPr(ctx, ctx.fork_slug, ctx.default_branch, branch, metadata.title, metadata.body);
        out.print("devflow: opened PR #{d} on {s} ({s}:{s} -> {s})\n", .{ number, ctx.upstream_slug, ownerLogin(ctx.fork_slug), branch, ctx.default_branch });
        return;
    }
    if (try gh.prNumberForBranch(ctx, branch)) |existing| {
        try gh.updatePr(ctx, ctx.fork_slug, existing, metadata.title, metadata.body);
        out.print("devflow: refreshed fork PR #{d} from complete branch scope\n", .{existing});
        return;
    }
    const number = try gh.openForkPr(ctx, ctx.default_branch, branch, metadata.title, metadata.body);
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
    const slug = prSlug(ctx);
    var waited_ns: u64 = 0;
    while (true) {
        // Gate on SUBMITTED reviews, not comments: a bot walkthrough comment or
        // a rate-limited/incomplete review must not read as "reviewed".
        const logins = try gh.headReviewerLogins(ctx, slug, number);
        defer ctx.allocator.free(logins);
        const has_rabbit = std.mem.indexOf(u8, logins, "coderabbit") != null or try gh.codeRabbitCheckResponded(ctx, slug, number);
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
            // A review submitted against an EARLIER head means the bot already
            // responded once and will not re-review on its own — waiting longer
            // cannot succeed until reviews are re-requested.
            const stale = try gh.staleReviewerLogins(ctx, slug, number);
            defer ctx.allocator.free(stale);
            if (stale.len != 0) {
                out.print("devflow: #{d} has reviews only on an EARLIER head (from: {s}); run `devflow request-reviews {d}` for the current head, then wait again\n", .{ number, stale, number });
            } else {
                out.print("devflow: waiting for reviews on #{d} (seen: {s})\n", .{ number, logins });
            }
        }

        if (waited_ns >= wait_timeout_ns) {
            out.print("devflow: wait-reviews timed out after 5m with the gate still pending; re-run `devflow wait-reviews {d}` to keep polling\n", .{number});
            return error.WaitTimedOut;
        }
        try ctx.io.sleep(.fromNanoseconds(poll_interval_ns), .awake);
        waited_ns += poll_interval_ns;
    }
}

/// `land <pr> [--codex]`: refuse unless the required reviewers have SUBMITTED a
/// review and no threads are unresolved, then land as one squash commit with a "Merge pull request #N from ..." subject and resync the local
/// default branch. Checking only unresolved-thread-count is unsafe: it is 0
/// before reviews post, so land must apply the same participant gate as
/// wait-reviews (Codex P2: "Require reviewer completion before merging").
pub fn land(ctx: Context, number: u32, require_codex: bool) !void {
    const slug = prSlug(ctx);
    const checks = try gh.prCheckStatus(ctx, slug, number);
    defer checks.deinit(ctx.allocator);
    if (!checks.green()) {
        out.print("devflow: refusing to land #{d}: CI is not green ({d} pending, {d} failing)\n{s}\n", .{ number, checks.pending, checks.failing, checks.lines });
        return error.CiNotGreen;
    }
    const logins = try gh.headReviewerLogins(ctx, slug, number);
    defer ctx.allocator.free(logins);
    const has_rabbit = std.mem.indexOf(u8, logins, "coderabbit") != null or try gh.codeRabbitCheckResponded(ctx, slug, number);
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

/// `open-upstream-pr`: only valid after the fork PR has merged and the
/// fork default branch matches upstream-ready content. Refuses without upstream.
pub fn openUpstreamPr(ctx: Context) !void {
    if (!ctx.hasUpstream()) {
        out.line("devflow: no `upstream` remote configured");
        return error.NoUpstream;
    }
    try git.fetchRemote(ctx, "origin");

    const metadata = try pr_scope.generate(ctx);
    defer metadata.deinit(ctx.allocator);
    const number = try gh.openUpstreamPr(ctx, ctx.fork_slug, ctx.default_branch, ctx.default_branch, metadata.title, metadata.body);
    out.print("devflow: opened upstream PR #{d} ({s}:{s} -> {s}:{s})\n", .{
        number, ctx.fork_slug, ctx.default_branch, ctx.upstream_slug, ctx.default_branch,
    });
}
