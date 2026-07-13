//! GitHub operations for devflow, via the `gh` CLI. Every query uses `--jq` so
//! the extraction happens in gh and this module stays free of JSON parsing.
//! Guards baked in here: PRs open against an explicit base with complete-branch
//! metadata, and merges are squash-with-merge-subject: one flat entry per PR
//! reading "Merge pull request #N from owner/branch".

const std = @import("std");
const proc = @import("proc.zig");
const Context = @import("context.zig").Context;

pub const CheckStatus = struct {
    lines: []u8,
    total: u32,
    pending: u32,
    failing: u32,

    pub fn deinit(self: CheckStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
    }

    pub fn green(self: CheckStatus) bool {
        return self.total != 0 and self.pending == 0 and self.failing == 0;
    }
};

/// Number of an open PR for `head` against the fork, or null if none.
pub fn prNumberForBranch(ctx: Context, head: []const u8) !?u32 {
    return prNumberOn(ctx, ctx.fork_slug, head);
}

/// Number of an open PR whose head branch is `head` on repo `slug` (works for a
/// cross-fork PR too — `--head` filters by head branch name), or null if none.
/// Used to keep PR opens idempotent across retry/resume.
pub fn prNumberOn(ctx: Context, slug: []const u8, head: []const u8) !?u32 {
    const out = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",     "pr",     "list", "-R",                   slug, "--head", head,
        "--json", "number", "--jq", ".[0].number // empty",
    });
    defer ctx.allocator.free(out);
    if (out.len == 0) return null;
    return std.fmt.parseInt(u32, out, 10) catch null;
}

/// Open a PR on the fork: base = `base`, head = `head`, empty body.
/// Returns the new PR number.
pub fn openForkPr(ctx: Context, base: []const u8, head: []const u8, title: []const u8, body: []const u8) !u32 {
    const url = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",     "pr",     "create", "-R", ctx.fork_slug,
        "--base", base,     "--head", head, "--title",
        title,    "--body", body,
    });
    defer ctx.allocator.free(url);
    return numberFromPrUrl(url) orelse error.PrUrlUnparseable;
}

/// Open a PR from the fork's default branch to upstream's default branch.
pub fn openUpstreamPr(ctx: Context, head_slug: []const u8, base: []const u8, head: []const u8, title: []const u8, body: []const u8) !u32 {
    const head_ref = try std.fmt.allocPrint(ctx.allocator, "{s}:{s}", .{ ownerOf(head_slug), head });
    defer ctx.allocator.free(head_ref);
    const url = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",     "pr",     "create", "-R",     ctx.upstream_slug,
        "--base", base,     "--head", head_ref, "--title",
        title,    "--body", body,
    });
    defer ctx.allocator.free(url);
    return numberFromPrUrl(url) orelse error.PrUrlUnparseable;
}

/// Refresh an existing PR from the same complete-branch metadata used to open
/// it. Retries therefore correct stale or session-scoped descriptions.
pub fn updatePr(ctx: Context, slug: []const u8, number: u32, title: []const u8, body: []const u8) !void {
    var num_buf: [16]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{number});
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh", "pr", "edit", num_str, "-R", slug, "--title", title, "--body", body,
    });
}

pub fn comment(ctx: Context, slug: []const u8, number: u32, body: []const u8) !void {
    var num_buf: [16]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{number});
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh", "pr", "comment", num_str, "-R", slug, "--body", body,
    });
}

/// Comma-joined logins that have SUBMITTED A REVIEW (not merely commented).
/// A walkthrough comment from a bot is NOT a review — gating on submitted
/// reviews is what stops a rate-limited/incomplete bot review from reading as
/// "done" (Core Law #2: a marker must not satisfy a deeper layer).
pub fn reviewerLogins(ctx: Context, slug: []const u8, number: u32) ![]u8 {
    var num_buf: [16]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{number});
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",   "pr",                                               "view", num_str, "-R", slug, "--json", "reviews",
        "--jq", "[.reviews[].author.login] | unique | join(\",\")",
    });
}

/// Comma-joined reviewers whose submitted review is attached to the PR's
/// current head commit. A review of an older pushed head cannot satisfy the
/// landing gate after new fixes have been added.
pub fn headReviewerLogins(ctx: Context, slug: []const u8, number: u32) ![]u8 {
    var num_buf: [16]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{number});
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",   "pr",                                                                                                        "view", num_str, "-R", slug, "--json", "headRefOid,reviews",
        "--jq", ".headRefOid as $head | [.reviews[] | select(.commit.oid == $head) | .author.login] | unique | join(\",\")",
    });
}

pub fn prHeadOid(ctx: Context, slug: []const u8, number: u32) ![]u8 {
    var num_buf: [16]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{number});
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh", "pr", "view", num_str, "-R", slug, "--json", "headRefOid", "--jq", ".headRefOid",
    });
}

/// Current-head check state. `gh pr checks` deliberately exits non-zero while
/// checks are pending or failing, so those documented states are parsed rather
/// than mistaken for an invocation failure.
pub fn prCheckStatus(ctx: Context, slug: []const u8, number: u32) !CheckStatus {
    var num_buf: [16]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{number});
    const result = try proc.tryRun(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",     "pr",                            "checks", num_str,                                                         "-R", slug,
        "--json", "bucket,name,state,description", "--jq",   ".[] | [.bucket, .name, .state, (.description // \"\")] | @tsv",
    });
    defer result.deinit(ctx.allocator);

    const accepted = switch (result.term) {
        .exited => |code| code == 0 or code == 1 or code == 8,
        else => false,
    };
    if (!accepted) return error.CheckQueryFailed;

    const lines = try ctx.allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    errdefer ctx.allocator.free(lines);
    const counts = countChecks(lines);
    return .{ .lines = lines, .total = counts.total, .pending = counts.pending, .failing = counts.failing };
}

const CheckCounts = struct { total: u32 = 0, pending: u32 = 0, failing: u32 = 0 };

fn countChecks(lines: []const u8) CheckCounts {
    var counts: CheckCounts = .{};
    var rows = std.mem.splitScalar(u8, lines, '\n');
    while (rows.next()) |row| {
        if (row.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, row, '\t') orelse continue;
        const bucket = row[0..tab];
        counts.total += 1;
        if (std.ascii.eqlIgnoreCase(bucket, "pending")) counts.pending += 1;
        if (std.ascii.eqlIgnoreCase(bucket, "fail") or
            std.ascii.eqlIgnoreCase(bucket, "cancel") or
            std.ascii.eqlIgnoreCase(bucket, "cancelled")) counts.failing += 1;
    }
    return counts;
}

/// Exact-head inline findings from bot reviews. Without `include_codex`, this
/// reports CodeRabbit; with it, both required bot reviewers are included.
pub fn headReviewFindings(ctx: Context, slug: []const u8, number: u32, include_codex: bool) ![]u8 {
    const head = try prHeadOid(ctx, slug, number);
    defer ctx.allocator.free(head);
    const filter = if (include_codex)
        "((.user.login | ascii_downcase | contains(\"coderabbit\")) or (.user.login | ascii_downcase | contains(\"codex\")))"
    else
        "(.user.login | ascii_downcase | contains(\"coderabbit\"))";
    const jq = try std.fmt.allocPrint(
        ctx.allocator,
        ".[] | select(.original_commit_id == \"{s}\") | select({s}) | \"[\\(.user.login)] \\(.path):\\(.line // .original_line // 0)\\n\\(.body)\\n\\(.html_url)\"",
        .{ head, filter },
    );
    defer ctx.allocator.free(jq);
    const endpoint = try std.fmt.allocPrint(ctx.allocator, "repos/{s}/pulls/{d}/comments", .{ slug, number });
    defer ctx.allocator.free(endpoint);
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{ "gh", "api", "--paginate", endpoint, "--jq", jq });
}

pub fn failedRunIdsForHead(ctx: Context, slug: []const u8, head: []const u8) ![]u8 {
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",      "run", "list",   "-R",                    slug,   "--commit",                                               head,
        "--limit", "20",  "--json", "databaseId,conclusion", "--jq", ".[] | select(.conclusion == \"failure\") | .databaseId",
    });
}

pub fn failedRunLog(ctx: Context, slug: []const u8, run_id: []const u8) ![]u8 {
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh", "run", "view", run_id, "-R", slug, "--log-failed",
    });
}

pub fn failedJobIdsForRun(ctx: Context, slug: []const u8, run_id: []const u8) ![]u8 {
    const endpoint = try std.fmt.allocPrint(ctx.allocator, "repos/{s}/actions/runs/{s}/jobs", .{ slug, run_id });
    defer ctx.allocator.free(endpoint);
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh", "api", "--paginate", endpoint, "--jq", ".jobs[] | select(.conclusion == \"failure\") | .id",
    });
}

pub fn failedJobLog(ctx: Context, slug: []const u8, run_id: []const u8, job_id: []const u8) ![]u8 {
    _ = run_id;
    const endpoint = try std.fmt.allocPrint(ctx.allocator, "repos/{s}/actions/jobs/{s}/logs", .{ slug, job_id });
    defer ctx.allocator.free(endpoint);
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh", "api", endpoint,
    });
}

pub fn completedRunIdsForHead(ctx: Context, slug: []const u8, head: []const u8) ![]u8 {
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",      "run", "list",   "-R",                          slug,   "--commit",                                                                                  head,
        "--limit", "20",  "--json", "databaseId,status,createdAt", "--jq", "[.[] | select(.status == \"completed\")] | sort_by(.createdAt) | reverse | .[].databaseId",
    });
}

pub fn runIdsForHead(ctx: Context, slug: []const u8, head: []const u8) ![]u8 {
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",      "run", "list",   "-R",                   slug,   "--commit",                                       head,
        "--limit", "20",  "--json", "databaseId,createdAt", "--jq", "sort_by(.createdAt) | reverse | .[].databaseId",
    });
}

pub fn workflowRunnerDetails(ctx: Context, slug: []const u8, run_id: []const u8) ![]u8 {
    const endpoint = try std.fmt.allocPrint(ctx.allocator, "repos/{s}/actions/runs/{s}/jobs", .{ slug, run_id });
    defer ctx.allocator.free(endpoint);
    return proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",                                                                                                                                 "api", "--paginate", endpoint, "--jq",
        ".jobs[] | [.name, (.status // \"\"), (.runner_name // \"\"), (.runner_group_name // \"\"), ((.labels // []) | join(\",\"))] | @tsv",
    });
}

pub fn rerunWorkflow(ctx: Context, slug: []const u8, run_id: []const u8) !void {
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{ "gh", "run", "rerun", run_id, "-R", slug });
}

/// CodeRabbit may decline oversized PRs through a successful head check rather
/// than a submitted review. That is still a completed response (with an honest
/// skipped reason), so it must not leave `wait-reviews` hanging forever.
pub fn codeRabbitCheckResponded(ctx: Context, slug: []const u8, number: u32) !bool {
    var num_buf: [16]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{number});
    const response = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",     "pr",         "checks", num_str,                                                                                                  "-R", slug,
        "--json", "name,state", "--jq",   "[.[] | select((.name | ascii_downcase | contains(\"coderabbit\")) and .state == \"SUCCESS\")] | length",
    });
    defer ctx.allocator.free(response);
    return (std.fmt.parseInt(u32, std.mem.trim(u8, response, " \r\n"), 10) catch 0) > 0;
}

/// Count of unresolved review threads across ALL pages (0 = all findings
/// resolved). Pages through `reviewThreads` so a PR with >100 threads cannot
/// hide unresolved findings on a later page and falsely read as resolved.
pub fn unresolvedThreadCount(ctx: Context, slug: []const u8, number: u32) !u32 {
    const owner = ownerOf(slug);
    const repo = repoOf(slug);

    var total: u32 = 0;
    var cursor: ?[]u8 = null;
    defer if (cursor) |c| ctx.allocator.free(c);

    while (true) {
        const after = if (cursor) |c|
            try std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{c})
        else
            try ctx.allocator.dupe(u8, "null");
        defer ctx.allocator.free(after);

        const query = try std.fmt.allocPrint(ctx.allocator,
            \\query {{ repository(owner:"{s}", name:"{s}") {{ pullRequest(number:{d}) {{ reviewThreads(first:100, after:{s}) {{ nodes {{ isResolved }} pageInfo {{ hasNextPage endCursor }} }} }} }} }}
        , .{ owner, repo, number, after });
        defer ctx.allocator.free(query);

        const query_arg = try std.fmt.allocPrint(ctx.allocator, "query={s}", .{query});
        defer ctx.allocator.free(query_arg);

        // Emit: "<unresolved-on-page>\t<hasNextPage>\t<endCursor>".
        const out = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
            "gh",   "api", "graphql", "-f", query_arg,
            "--jq",
            ".data.repository.pullRequest.reviewThreads | " ++
                "\"\\([.nodes[]|select(.isResolved==false)]|length)\\t\\(.pageInfo.hasNextPage)\\t\\(.pageInfo.endCursor // \"\")\"",
        });
        defer ctx.allocator.free(out);

        var fields = std.mem.splitScalar(u8, out, '\t');
        const count_str = fields.next() orelse "0";
        const has_next = fields.next() orelse "false";
        const end_cursor = fields.next() orelse "";

        total += std.fmt.parseInt(u32, std.mem.trim(u8, count_str, " \r\n"), 10) catch 0;

        if (!std.mem.eql(u8, std.mem.trim(u8, has_next, " \r\n"), "true") or end_cursor.len == 0) break;

        // Null the pointer between free and dupe: if the dupe errors, the
        // `defer` above must not free the already-freed cursor (double-free).
        if (cursor) |c| {
            ctx.allocator.free(c);
            cursor = null;
        }
        cursor = try ctx.allocator.dupe(u8, std.mem.trim(u8, end_cursor, " \r\n"));
    }
    return total;
}

pub fn isMerged(ctx: Context, slug: []const u8, number: u32) !bool {
    var num_buf: [16]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{number});
    const out = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh", "pr", "view", num_str, "-R", slug, "--json", "state", "--jq", ".state",
    });
    defer ctx.allocator.free(out);
    return std.mem.eql(u8, out, "MERGED");
}

/// Land the PR as ONE commit whose subject reads like GitHub's merge line:
/// `Merge pull request #N from <owner>/<branch>`, PR title as body. This is a
/// SQUASH merge with a custom subject — the only way to get a single flat-list
/// entry per PR (squash collapses the children; a real `--merge` commit
/// re-exposes every child commit in GitHub's commit list) while still reading
/// like `apple/swift`'s history.
pub fn landAsPullRequest(ctx: Context, slug: []const u8, number: u32) !void {
    var num_buf: [16]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{number});

    // head owner + branch + PR title, tab-separated.
    const info = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",     "pr",
        "view",   num_str,
        "-R",     slug,
        "--json", "headRefName,headRepositoryOwner,title",
        "--jq",   "(.headRepositoryOwner.login // \"\") + \"\\t\" + .headRefName + \"\\t\" + .title",
    });
    defer ctx.allocator.free(info);

    var it = std.mem.splitScalar(u8, info, '\t');
    const owner = it.next() orelse return error.PrInfoUnparseable;
    const branch = it.next() orelse return error.PrInfoUnparseable;
    const title = it.next() orelse "";

    const subject = try std.fmt.allocPrint(ctx.allocator, "Merge pull request #{d} from {s}/{s}", .{ number, owner, branch });
    defer ctx.allocator.free(subject);

    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{
        "gh",    "pr",     "merge",    num_str,
        "-R",    slug,     "--squash", "--subject",
        subject, "--body", title,
    });
}

fn numberFromPrUrl(url: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return null;
    return std.fmt.parseInt(u32, trimmed[slash + 1 ..], 10) catch null;
}

fn ownerOf(slug: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, slug, '/') orelse return slug;
    return slug[0..slash];
}

fn repoOf(slug: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, slug, '/') orelse return slug;
    return slug[slash + 1 ..];
}

test "numberFromPrUrl" {
    try std.testing.expectEqual(@as(?u32, 11), numberFromPrUrl("https://github.com/iPriam/kira/pull/11\n"));
}

test "owner/repo split" {
    try std.testing.expectEqualStrings("iPriam", ownerOf("iPriam/kira"));
    try std.testing.expectEqualStrings("kira", repoOf("iPriam/kira"));
}

test "countChecks classifies current check buckets" {
    const counts = countChecks(
        "pass\tlinux\tSUCCESS\t\n" ++
            "pending\tmacos\tIN_PROGRESS\t\n" ++
            "fail\twindows\tFAILURE\tbroken\n" ++
            "skipping\tCodeRabbit\tSUCCESS\toversized",
    );
    try std.testing.expectEqual(@as(u32, 4), counts.total);
    try std.testing.expectEqual(@as(u32, 1), counts.pending);
    try std.testing.expectEqual(@as(u32, 1), counts.failing);
}
