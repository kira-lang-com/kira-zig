//! Release automation: dynamic version computation, version storage, and
//! tag-triggered releases, so cutting a release never involves hand-editing
//! version strings.
//!
//! Kira versions are `YEAR.MONTH.PATCH` with the year counted incrementally
//! from the project epoch (2026 = 1): the third July-2026 release is
//! `1.7.3`. Patch numbering continues the retired calendar scheme — legacy
//! tag `v2026.07.2` counts as `1.7.2` when computing the next July-2026
//! patch. The version is stored in two files that must agree with the tag
//! (`build.zig` bakes it into every binary and the toolchain snapshot name;
//! `release.yml` uses it for the released toolchain directory), and the
//! release notes come from the version's `.codex/CHANGELOG.md` section
//! (`writing-github-releases` skill).
//!
//!   next-version   compute and print the next version
//!   release-prep   rewrite stored versions + require the changelog section
//!   release        gate agreement, then signed tag on main pushed upstream

const std = @import("std");
const proc = @import("proc.zig");
const git = @import("git_ops.zig");
const out = @import("out.zig");
const Context = @import("context.zig").Context;

const version_epoch_year: i64 = 2025;
const build_zig_prefix = "const kirac_version = \"";
const release_yml_prefix = "  VERSION: \"";
const changelog_path = ".codex/CHANGELOG.md";

/// `next-version`: print the version `release-prep` would store.
pub fn nextVersion(ctx: Context) !void {
    const version = try computeNextVersion(ctx);
    defer ctx.allocator.free(version);
    out.print("{s}\n", .{version});
}

/// `release-prep`: compute the next version, require its non-empty changelog
/// section, and rewrite both stored version strings. The bump then lands
/// through the normal branch -> PR -> land flow like any other change.
pub fn releasePrep(ctx: Context) !void {
    const version = try computeNextVersion(ctx);
    defer ctx.allocator.free(version);

    try requireChangelogSection(ctx, version);
    try rewriteQuotedValue(ctx, "build.zig", build_zig_prefix, version);
    try rewriteQuotedValue(ctx, ".github/workflows/release.yml", release_yml_prefix, version);

    out.print("devflow: staged version {s} in build.zig and release.yml\n", .{version});
    out.line("devflow: land the bump through the normal PR flow, then run `devflow release`");
}

/// `release`: verify every stored version agrees on a tag-ready main, then
/// create the signed `v<version>` tag and push it to upstream, which
/// triggers the release workflow.
pub fn release(ctx: Context) !void {
    if (!ctx.hasUpstream()) {
        out.line("devflow: release requires an `upstream` remote");
        return error.NoUpstreamRemote;
    }
    try git.fetchRemote(ctx, "origin");
    try git.fetchRemote(ctx, "upstream");

    if (!try git.workingTreeClean(ctx)) {
        out.line("devflow: refusing to release: working tree is not clean");
        return error.WorkingTreeDirty;
    }
    const branch = try git.currentBranch(ctx);
    defer ctx.allocator.free(branch);
    if (!std.mem.eql(u8, branch, ctx.default_branch)) {
        out.print("devflow: refusing to release from \"{s}\"; check out {s} first\n", .{ branch, ctx.default_branch });
        return error.NotOnDefaultBranch;
    }
    try requireHeadsAligned(ctx);

    const version = try storedVersion(ctx, "build.zig", build_zig_prefix);
    defer ctx.allocator.free(version);
    const workflow_version = try storedVersion(ctx, ".github/workflows/release.yml", release_yml_prefix);
    defer ctx.allocator.free(workflow_version);
    if (!std.mem.eql(u8, version, workflow_version)) {
        out.print("devflow: version mismatch: build.zig has {s}, release.yml has {s}; run `devflow release-prep` and land it\n", .{ version, workflow_version });
        return error.VersionMismatch;
    }
    try requireChangelogSection(ctx, version);

    const tag = try std.fmt.allocPrint(ctx.allocator, "v{s}", .{version});
    defer ctx.allocator.free(tag);
    try requireTagAbsent(ctx, tag);

    const message = try std.fmt.allocPrint(ctx.allocator, "Kira {s}", .{version});
    defer ctx.allocator.free(message);
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "tag", "-s", tag, "-m", message });
    try proc.check(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "push", "upstream", tag });

    out.print("devflow: pushed signed tag {s}; release workflow is running\n", .{tag});
    out.print("devflow: watch it at https://github.com/{s}/actions/workflows/release.yml\n", .{ctx.upstream_slug});
}

/// Next version from the real clock and the union of new-scheme and legacy
/// calendar tags for the current year/month.
fn computeNextVersion(ctx: Context) ![]u8 {
    const now_ns = std.Io.Clock.Timestamp.now(ctx.io, .real).raw.toNanoseconds();
    const now = civilFromTimestamp(@intCast(@divFloor(now_ns, std.time.ns_per_s)));
    const major: u32 = @intCast(now.year - version_epoch_year);
    const tags = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "tag", "-l" });
    defer ctx.allocator.free(tags);
    const patch = nextPatch(tags, major, @intCast(now.year), now.month);
    return std.fmt.allocPrint(ctx.allocator, "{d}.{d}.{d}", .{ major, now.month, patch });
}

/// One past the highest existing patch for this year/month across both
/// version schemes (`v1.7.x` and legacy `v2026.07.x`); 1 when none exist.
fn nextPatch(tags: []const u8, major: u32, calendar_year: u32, month: u8) u32 {
    var max_patch: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, tags, '\n');
    while (lines.next()) |line| {
        const tag = std.mem.trim(u8, line, " \r");
        const parsed = parseVersionTag(tag) orelse continue;
        const same_period = (parsed.major == major or parsed.major == calendar_year) and parsed.month == month;
        if (same_period and parsed.patch > max_patch) max_patch = parsed.patch;
    }
    return max_patch + 1;
}

const ParsedTag = struct { major: u32, month: u8, patch: u32 };

/// Parse `v<major>.<month>.<patch>`; null for anything else (llvm tags,
/// backups, malformed names).
fn parseVersionTag(tag: []const u8) ?ParsedTag {
    if (!std.mem.startsWith(u8, tag, "v")) return null;
    var parts = std.mem.splitScalar(u8, tag[1..], '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const month = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    const patch = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null) return null;
    if (month == 0 or month > 12) return null;
    return .{ .major = major, .month = month, .patch = patch };
}

const CivilDate = struct { year: i64, month: u8 };

/// UTC civil year/month from a Unix timestamp (Howard Hinnant's algorithm).
fn civilFromTimestamp(timestamp: i64) CivilDate {
    const days = @divFloor(timestamp, std.time.s_per_day);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const year = yoe + era * 400 + @intFromBool(month <= 2);
    return .{ .year = year, .month = month };
}

/// The changelog must already carry a non-empty `## [<version>]` section —
/// the release body is generated from it, and the workflow's bare fallback
/// line is a bug, not a post (`writing-github-releases` skill).
fn requireChangelogSection(ctx: Context, version: []const u8) !void {
    const text = try readRepoFile(ctx, changelog_path);
    defer ctx.allocator.free(text);
    const heading = try std.fmt.allocPrint(ctx.allocator, "## [{s}]", .{version});
    defer ctx.allocator.free(heading);
    if (!changelogSectionNonEmpty(text, heading)) {
        out.print("devflow: {s} has no non-empty \"{s}\" section; write it first (writing-github-releases skill)\n", .{ changelog_path, heading });
        return error.MissingChangelogSection;
    }
}

/// True when `heading` starts a line and body text follows before the next
/// `## [` heading (or EOF).
fn changelogSectionNonEmpty(text: []const u8, heading: []const u8) bool {
    const start = blk: {
        if (std.mem.startsWith(u8, text, heading)) break :blk heading.len;
        const nl_heading_at = std.mem.indexOf(u8, text, heading) orelse return false;
        if (text[nl_heading_at - 1] != '\n') return false;
        break :blk nl_heading_at + heading.len;
    };
    const rest_of_line = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return false;
    const body_end = std.mem.indexOfPos(u8, text, rest_of_line, "\n## [") orelse text.len;
    const body = text[rest_of_line..body_end];
    return std.mem.indexOfNone(u8, body, " \t\r\n") != null;
}

fn requireHeadsAligned(ctx: Context) !void {
    const head = try git.headOid(ctx);
    defer ctx.allocator.free(head);
    const remotes = [_][]const u8{ "origin", "upstream" };
    for (remotes) |remote| {
        const ref = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ remote, ctx.default_branch });
        defer ctx.allocator.free(ref);
        const oid = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "rev-parse", ref });
        defer ctx.allocator.free(oid);
        if (!std.mem.eql(u8, head, oid)) {
            out.print("devflow: refusing to release: {s} is not at local {s} (land/sync first)\n", .{ ref, ctx.default_branch });
            return error.HeadsDiverged;
        }
    }
}

fn requireTagAbsent(ctx: Context, tag: []const u8) !void {
    const local = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "tag", "-l", tag });
    defer ctx.allocator.free(local);
    if (local.len != 0) {
        out.print("devflow: tag {s} already exists locally\n", .{tag});
        return error.TagExists;
    }
    const ref = try std.fmt.allocPrint(ctx.allocator, "refs/tags/{s}", .{tag});
    defer ctx.allocator.free(ref);
    const remote = try proc.capture(ctx.allocator, ctx.io, ctx.repo_root, &.{ "git", "ls-remote", "upstream", ref });
    defer ctx.allocator.free(remote);
    if (std.mem.trim(u8, remote, " \t\r\n").len != 0) {
        out.print("devflow: tag {s} already exists on upstream\n", .{tag});
        return error.TagExists;
    }
}

fn storedVersion(ctx: Context, sub_path: []const u8, prefix: []const u8) ![]u8 {
    const text = try readRepoFile(ctx, sub_path);
    defer ctx.allocator.free(text);
    const value = extractQuotedValue(text, prefix) orelse {
        out.print("devflow: could not find `{s}...\"` in {s}\n", .{ prefix, sub_path });
        return error.VersionNotFound;
    };
    return ctx.allocator.dupe(u8, value);
}

fn rewriteQuotedValue(ctx: Context, sub_path: []const u8, prefix: []const u8, value: []const u8) !void {
    const text = try readRepoFile(ctx, sub_path);
    defer ctx.allocator.free(text);
    const replaced = replaceQuotedValue(ctx.allocator, text, prefix, value) catch |err| {
        out.print("devflow: could not rewrite `{s}...\"` in {s}\n", .{ prefix, sub_path });
        return err;
    };
    defer ctx.allocator.free(replaced);
    try writeRepoFile(ctx, sub_path, replaced);
}

/// The single quoted value following `prefix`, or null when the prefix is
/// missing or its line is malformed.
fn extractQuotedValue(text: []const u8, prefix: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, prefix) orelse return null;
    const start = at + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
    return text[start..end];
}

/// Replace the quoted value after `prefix`. Errors when the prefix is
/// missing or appears more than once — a release must never guess which
/// version string it is editing.
fn replaceQuotedValue(allocator: std.mem.Allocator, text: []const u8, prefix: []const u8, value: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, prefix) orelse return error.PrefixNotFound;
    const start = at + prefix.len;
    if (std.mem.indexOfPos(u8, text, start, prefix) != null) return error.PrefixAmbiguous;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return error.PrefixNotFound;
    return std.mem.concat(allocator, u8, &.{ text[0..start], value, text[end..] });
}

fn readRepoFile(ctx: Context, sub_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(ctx.allocator, &.{ ctx.repo_root, sub_path });
    defer ctx.allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(4 * 1024 * 1024));
}

fn writeRepoFile(ctx: Context, sub_path: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(ctx.allocator, &.{ ctx.repo_root, sub_path });
    defer ctx.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data });
}

test "civilFromTimestamp maps UTC boundaries" {
    // 2026-01-01T00:00:00Z
    try std.testing.expectEqual(CivilDate{ .year = 2026, .month = 1 }, civilFromTimestamp(1767225600));
    // One second earlier is 2025-12-31.
    try std.testing.expectEqual(CivilDate{ .year = 2025, .month = 12 }, civilFromTimestamp(1767225599));
}

test "nextPatch continues legacy calendar tags and ignores foreign tags" {
    const tags = "backup-author-rewrite\nllvm-v22.1.4-kira.1\nv0.1.0\nv2026.07.2\n";
    try std.testing.expectEqual(@as(u32, 3), nextPatch(tags, 1, 2026, 7));
    try std.testing.expectEqual(@as(u32, 1), nextPatch(tags, 1, 2026, 8));
    const mixed = "v0.1.0\nv2026.07.2\nv1.7.3\n";
    try std.testing.expectEqual(@as(u32, 4), nextPatch(mixed, 1, 2026, 7));
}

test "parseVersionTag rejects malformed and out-of-range tags" {
    try std.testing.expectEqual(ParsedTag{ .major = 1, .month = 7, .patch = 3 }, parseVersionTag("v1.7.3").?);
    try std.testing.expect(parseVersionTag("v1.13.1") == null);
    try std.testing.expect(parseVersionTag("v1.7") == null);
    try std.testing.expect(parseVersionTag("v1.7.3.4") == null);
    try std.testing.expect(parseVersionTag("llvm-v22.1.2-kira.1") == null);
}

test "replaceQuotedValue rewrites exactly one site" {
    const allocator = std.testing.allocator;
    const text = "const kirac_version = \"2026.07.2\";\n";
    const replaced = try replaceQuotedValue(allocator, text, build_zig_prefix, "1.7.3");
    defer allocator.free(replaced);
    try std.testing.expectEqualStrings("const kirac_version = \"1.7.3\";\n", replaced);
    try std.testing.expectError(error.PrefixNotFound, replaceQuotedValue(allocator, "nothing here", build_zig_prefix, "1.7.3"));
    const twice = "const kirac_version = \"a\";\nconst kirac_version = \"b\";\n";
    try std.testing.expectError(error.PrefixAmbiguous, replaceQuotedValue(allocator, twice, build_zig_prefix, "1.7.3"));
}

test "changelogSectionNonEmpty requires body text before the next heading" {
    const filled = "# Changelog\n\n## [1.7.3] - 2026-07-14\n\n- Something shipped.\n\n## [2026.07.2] - 2026-07-07\n";
    try std.testing.expect(changelogSectionNonEmpty(filled, "## [1.7.3]"));
    const empty = "# Changelog\n\n## [1.7.3] - 2026-07-14\n\n## [2026.07.2] - 2026-07-07\n";
    try std.testing.expect(!changelogSectionNonEmpty(empty, "## [1.7.3]"));
    try std.testing.expect(!changelogSectionNonEmpty(filled, "## [1.7.4]"));
}
