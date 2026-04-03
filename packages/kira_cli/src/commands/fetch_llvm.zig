const std = @import("std");
const build = @import("kira_build");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len != 0) return error.InvalidArguments;

    const resource_root = support.resolveResourceRoot(allocator) catch {
        try stderr.print("could not locate Kira runtime resources for `{s} fetch-llvm`\n", .{support.binaryName()});
        return error.CommandFailed;
    };
    defer allocator.free(resource_root);

    build.fetchLlvm(allocator, stdout, stderr, resource_root) catch |run_err| {
        switch (run_err) {
            error.InvalidLlvmMetadata,
            error.UnsupportedLlvmHost,
            error.LlvmTargetNotPublished,
            error.GitHubReleaseTagNotFound,
            error.GitHubReleaseAssetNotFound,
            error.GitHubReleaseLookupFailed,
            error.GitHubReleaseTagMismatch,
            error.GitHubAssetDownloadFailed,
            error.InvalidInstalledToolchain,
            => return error.CommandFailed,
            else => return run_err,
        }
    };
}
