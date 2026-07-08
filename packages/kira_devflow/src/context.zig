//! Shared devflow context: repo root, IO, and the fork/upstream identity
//! derived from `git remote` URLs. Nothing here is hardcoded to a particular
//! GitHub account — the slugs and the SSH push URL are parsed from the actual
//! `origin` and `upstream` remotes so the tool works for any fork.

const std = @import("std");
const proc = @import("proc.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    /// e.g. "iPriam/kira" — the fork (origin).
    fork_slug: []const u8,
    /// e.g. "kira-lang-com/kira" — upstream. Empty if no upstream remote.
    upstream_slug: []const u8,
    /// SSH push URL for the fork, e.g. "git@github.com:iPriam/kira.git".
    /// Used for every push so an OAuth token missing the `workflow` scope
    /// cannot reject pushes that touch `.github/workflows/*`.
    fork_ssh_url: []const u8,
    /// Default branch name, e.g. "main".
    default_branch: []const u8,

    pub fn hasUpstream(self: Context) bool {
        return self.upstream_slug.len != 0;
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    default_branch: []const u8,
) !Context {
    const origin_url = proc.capture(allocator, io, repo_root, &.{ "git", "remote", "get-url", "origin" }) catch {
        std.debug.print("devflow: no `origin` remote found; run inside the fork clone\n", .{});
        return error.NoOriginRemote;
    };
    defer allocator.free(origin_url);

    const fork_slug = try slugFromUrl(allocator, origin_url);
    const fork_ssh_url = try sshUrlFromSlug(allocator, fork_slug);

    var upstream_slug: []const u8 = "";
    if (proc.capture(allocator, io, repo_root, &.{ "git", "remote", "get-url", "upstream" })) |upstream_url| {
        defer allocator.free(upstream_url);
        upstream_slug = try slugFromUrl(allocator, upstream_url);
    } else |_| {
        upstream_slug = "";
    }

    return .{
        .allocator = allocator,
        .io = io,
        .repo_root = repo_root,
        .fork_slug = fork_slug,
        .upstream_slug = upstream_slug,
        .fork_ssh_url = fork_ssh_url,
        .default_branch = default_branch,
    };
}

/// Extract "owner/repo" from an https or ssh GitHub remote URL.
/// Handles: https://github.com/owner/repo.git, git@github.com:owner/repo.git,
/// ssh://git@github.com/owner/repo.git (trailing ".git" optional).
pub fn slugFromUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var s = std.mem.trim(u8, url, " \t\r\n");

    // Strip scheme / host prefixes down to "owner/repo".
    if (std.mem.indexOf(u8, s, "github.com")) |idx| {
        s = s[idx + "github.com".len ..];
    }
    // After the host there is either ':' (scp-like) or '/' (url path).
    while (s.len != 0 and (s[0] == ':' or s[0] == '/')) : (s = s[1..]) {}

    // Drop a trailing ".git".
    if (std.mem.endsWith(u8, s, ".git")) s = s[0 .. s.len - ".git".len];
    s = std.mem.trim(u8, s, "/");

    if (std.mem.indexOfScalar(u8, s, '/') == null) return error.UnparseableRemoteUrl;
    return allocator.dupe(u8, s);
}

pub fn sshUrlFromSlug(allocator: std.mem.Allocator, slug: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "git@github.com:{s}.git", .{slug});
}

test "slugFromUrl parses https and ssh forms" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "https://github.com/iPriam/kira.git",
        "git@github.com:iPriam/kira.git",
        "ssh://git@github.com/iPriam/kira.git",
        "https://github.com/iPriam/kira",
    };
    for (cases) |c| {
        const slug = try slugFromUrl(a, c);
        defer a.free(slug);
        try std.testing.expectEqualStrings("iPriam/kira", slug);
    }
}

test "sshUrlFromSlug builds push url" {
    const a = std.testing.allocator;
    const url = try sshUrlFromSlug(a, "iPriam/kira");
    defer a.free(url);
    try std.testing.expectEqualStrings("git@github.com:iPriam/kira.git", url);
}
