const std = @import("std");
const archive = @import("archive.zig");
const paths = @import("paths.zig");

pub const Checkout = struct {
    commit: []const u8,
    source_root: []const u8,
};

pub fn resolveGitCheckout(
    allocator: std.mem.Allocator,
    url: []const u8,
    requested_rev: ?[]const u8,
    requested_tag: ?[]const u8,
    offline: bool,
    locked_commit: ?[]const u8,
) !Checkout {
    const canonical_url = try canonicalizeGitUrl(allocator, url);
    defer allocator.free(canonical_url);

    const git_root = try paths.gitRoot(allocator);
    defer allocator.free(git_root);
    try paths.ensurePath(git_root);

    const url_hash = try archive.sha256Hex(allocator, canonical_url);
    defer allocator.free(url_hash);

    const repos_root = try std.fs.path.join(allocator, &.{ git_root, "repos" });
    defer allocator.free(repos_root);
    try paths.ensurePath(repos_root);
    const repo_path = try std.fs.path.join(allocator, &.{ repos_root, url_hash });
    defer allocator.free(repo_path);

    const commit = if (locked_commit) |value|
        try allocator.dupe(u8, value)
    else
        try resolveCommit(allocator, repo_path, canonical_url, requested_rev, requested_tag, offline);
    errdefer allocator.free(commit);

    const source_root = try std.fs.path.join(allocator, &.{ git_root, "sources", url_hash, commit });
    errdefer allocator.free(source_root);
    if (dirExists(source_root)) {
        return .{
            .commit = commit,
            .source_root = source_root,
        };
    }

    if (offline) return error.GitCommitNotCached;
    try paths.ensurePath(source_root);

    const tar_path = try std.fs.path.join(allocator, &.{ git_root, "tmp-git.tar" });
    defer allocator.free(tar_path);
    _ = std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, tar_path) catch {};

    try ensureRepo(allocator, repo_path, canonical_url, false);
    try runGit(allocator, &.{ "git", "-C", repo_path, "archive", "--format=tar", "-o", tar_path, commit });
    try archive.extractTarSecure(allocator, tar_path, source_root);
    _ = std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, tar_path) catch {};

    return .{
        .commit = commit,
        .source_root = source_root,
    };
}

fn resolveCommit(
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    canonical_url: []const u8,
    requested_rev: ?[]const u8,
    requested_tag: ?[]const u8,
    offline: bool,
) ![]u8 {
    try ensureRepo(allocator, repo_path, canonical_url, offline);

    if (requested_rev) |rev| {
        if (!commitExists(allocator, repo_path, rev)) {
            if (offline) return error.GitCommitNotCached;
            try runGit(allocator, &.{ "git", "-C", repo_path, "fetch", "--depth", "1", "origin", rev });
        }
        return normalizeCommit(allocator, repo_path, rev);
    }

    if (requested_tag) |tag| {
        if (offline) return error.GitTagResolutionRequiresNetwork;
        try runGit(allocator, &.{ "git", "-C", repo_path, "fetch", "--tags", "origin" });
        const ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}^{{commit}}", .{tag});
        defer allocator.free(ref);
        return normalizeCommit(allocator, repo_path, ref);
    }

    return error.InvalidManifest;
}

fn ensureRepo(allocator: std.mem.Allocator, repo_path: []const u8, canonical_url: []const u8, offline: bool) !void {
    if (!dirExists(repo_path)) {
        if (offline) return error.GitRepositoryNotCached;
        if (std.fs.path.dirname(repo_path)) |parent| try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, parent);
        try runGit(allocator, &.{ "git", "clone", "--mirror", canonical_url, repo_path });
        return;
    }

    if (offline) return;
    try runGit(allocator, &.{ "git", "-C", repo_path, "fetch", "--prune", "--tags", "origin" });
}

fn commitExists(allocator: std.mem.Allocator, repo_path: []const u8, rev: []const u8) bool {
    const object = std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{rev}) catch return false;
    defer allocator.free(object);
    const result = std.process.run(allocator, std.Options.debug_io, .{
        .argv = &.{ "git", "-C", repo_path, "cat-file", "-e", object },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn normalizeCommit(allocator: std.mem.Allocator, repo_path: []const u8, rev: []const u8) ![]u8 {
    const object = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{rev});
    defer allocator.free(object);
    const result = try std.process.run(allocator, std.Options.debug_io, .{
        .argv = &.{ "git", "-C", repo_path, "rev-parse", object },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.GitCommitNotFound;
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return owned;
}

fn runGit(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, std.Options.debug_io, .{
        .argv = argv,
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.GitCommandFailed;
    }
}

fn canonicalizeGitUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidManifest;
    const without_trailing = std.mem.trimEnd(u8, trimmed, "/");
    return allocator.dupe(u8, without_trailing);
}

fn dirExists(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}
