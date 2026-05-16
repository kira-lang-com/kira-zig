const std = @import("std");
const build = @import("kira_build");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const options = try parseArgs(args);

    const resource_root = support.resolveResourceRoot(allocator) catch {
        try stderr.print("could not locate Kira runtime resources for `{s} fetch-llvm`\n", .{support.binaryName()});
        return error.CommandFailed;
    };
    defer allocator.free(resource_root);

    switch (options.mode) {
        .download_and_install => build.fetchLlvm(allocator, stdout, stderr, resource_root) catch |run_err| {
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
                error.LlvmArchiveNotFound,
                => return error.CommandFailed,
                else => return run_err,
            }
        },
        .ci_metadata_json => build.fetchLlvmPrintCiMetadataJson(allocator, stdout, stderr, resource_root) catch |run_err| {
            switch (run_err) {
                error.InvalidLlvmMetadata,
                error.UnsupportedLlvmHost,
                error.LlvmTargetNotPublished,
                => return error.CommandFailed,
                else => return run_err,
            }
        },
        .install_archive => build.fetchLlvmInstallArchive(allocator, stdout, stderr, resource_root, options.archive_path.?) catch |run_err| {
            switch (run_err) {
                error.InvalidLlvmMetadata,
                error.UnsupportedLlvmHost,
                error.LlvmTargetNotPublished,
                error.InvalidInstalledToolchain,
                error.LlvmArchiveNotFound,
                => return error.CommandFailed,
                else => return run_err,
            }
        },
    }
}

const Mode = enum {
    download_and_install,
    ci_metadata_json,
    install_archive,
};

const Options = struct {
    mode: Mode,
    archive_path: ?[]const u8 = null,
};

fn parseArgs(args: []const []const u8) !Options {
    var ci_metadata = false;
    var json = false;
    var archive_path: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--ci-metadata")) {
            ci_metadata = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--archive")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            if (archive_path != null) return error.InvalidArguments;
            archive_path = args[index];
            continue;
        }
        return error.InvalidArguments;
    }

    if (archive_path != null and ci_metadata) return error.InvalidArguments;
    if (archive_path != null and json) return error.InvalidArguments;
    if (json and !ci_metadata) return error.InvalidArguments;

    if (archive_path) |path| {
        return .{ .mode = .install_archive, .archive_path = path };
    }
    if (ci_metadata) {
        if (!json) return error.InvalidArguments;
        return .{ .mode = .ci_metadata_json };
    }
    return .{ .mode = .download_and_install };
}

test "parseArgs accepts default download flow" {
    const options = try parseArgs(&.{});
    try std.testing.expectEqual(Mode.download_and_install, options.mode);
    try std.testing.expectEqual(@as(?[]const u8, null), options.archive_path);
}

test "parseArgs accepts ci metadata json flow" {
    const options = try parseArgs(&.{ "--ci-metadata", "--json" });
    try std.testing.expectEqual(Mode.ci_metadata_json, options.mode);
    try std.testing.expectEqual(@as(?[]const u8, null), options.archive_path);
}

test "parseArgs accepts archive install flow" {
    const options = try parseArgs(&.{ "--archive", "/tmp/llvm.tar.xz" });
    try std.testing.expectEqual(Mode.install_archive, options.mode);
    try std.testing.expectEqualStrings("/tmp/llvm.tar.xz", options.archive_path.?);
}

test "parseArgs rejects invalid fetch llvm flag combinations" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--ci-metadata" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--json" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--archive" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--archive", "/tmp/llvm.tar.xz", "--json" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--archive", "/tmp/llvm.tar.xz", "--ci-metadata" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--ci-metadata", "--json", "--archive", "/tmp/llvm.tar.xz" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--unknown" }));
}
