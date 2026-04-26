const std = @import("std");
const builtin = @import("builtin");
const kira_toolchain = @import("kira_toolchain");
const llvm_metadata = @import("llvm_metadata.zig");
const github_release_fetch = @import("github_release_fetch.zig");
const archive_extract = @import("archive_extract.zig");

const install_marker_name = ".kira-toolchain.json";

pub const InstallMarker = struct {
    llvm_version: []const u8,
    host_key: []const u8,
    release_tag: []const u8,
    asset_name: []const u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    out: anytype,
    err: anytype,
    metadata_root: []const u8,
) !void {
    const metadata_path = try std.fs.path.join(allocator, &.{ metadata_root, "llvm-metadata.toml" });
    defer allocator.free(metadata_path);

    const metadata = llvm_metadata.parseFile(allocator, metadata_path) catch {
        try err.print("Failed to parse llvm-metadata.toml at {s}.\n", .{metadata_path});
        return error.InvalidLlvmMetadata;
    };
    defer metadata.deinit(allocator);

    const host_key = @import("kira_llvm_backend").toolchainLayout.hostLlvmBundleKey(builtin.target) orelse {
        try err.print(
            "Unsupported host target for Kira LLVM bundles: {s}-{s}.\n",
            .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) },
        );
        return error.UnsupportedLlvmHost;
    };

    const target = metadata.findTarget(host_key) orelse {
        try err.print("llvm-metadata.toml does not publish a bundle for host target {s}.\n", .{host_key});
        return error.LlvmTargetNotPublished;
    };

    const install_home = try kira_toolchain.managedLlvmHome(allocator, metadata.llvm_version, host_key);
    defer allocator.free(install_home);

    const marker_path = try installMarkerPath(allocator, install_home);
    defer allocator.free(marker_path);

    try out.print(
        "LLVM {s}\nrelease tag: {s}\nhost target: {s}\nasset: {s}\ninstall dir: {s}\n",
        .{
            metadata.llvm_version,
            metadata.llvm_release_tag,
            host_key,
            target.asset,
            install_home,
        },
    );

    if (try isInstalledAndValid(allocator, install_home, .{
        .llvm_version = metadata.llvm_version,
        .host_key = host_key,
        .release_tag = metadata.llvm_release_tag,
        .asset_name = target.asset,
    })) {
        try out.print("LLVM toolchain is already installed and matches the pinned metadata. Skipping.\n", .{});
        return;
    }

    const version_root = try kira_toolchain.managedLlvmVersionRoot(allocator, metadata.llvm_version);
    defer allocator.free(version_root);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, version_root);

    if (dirExistsAbsolute(install_home)) {
        try out.print("Removing stale install at {s} before reinstalling.\n", .{install_home});
        try std.Io.Dir.cwd().deleteTree(std.Options.debug_io, install_home);
    }

    const resolved_asset = github_release_fetch.resolveReleaseAsset(
        allocator,
        metadata_root,
        metadata.llvm_release_tag,
        target.asset,
    ) catch |fetch_err| {
        switch (fetch_err) {
            error.GitHubReleaseTagNotFound => try err.print(
                "GitHub release tag {s} was not found in repository {s}.\n",
                .{ metadata.llvm_release_tag, github_release_fetch.default_repository },
            ),
            error.GitHubReleaseAssetNotFound => try err.print(
                "GitHub release {s} exists, but asset {s} was not found.\n",
                .{ metadata.llvm_release_tag, target.asset },
            ),
            else => try err.print(
                "Failed to resolve GitHub release asset {s} from tag {s}: {s}\n",
                .{ target.asset, metadata.llvm_release_tag, @errorName(fetch_err) },
            ),
        }
        return fetch_err;
    };
    defer resolved_asset.deinit(allocator);

    const temp_root_dir = try temporaryInstallDir(allocator, version_root, host_key);
    defer allocator.free(temp_root_dir);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, temp_root_dir);
    errdefer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, temp_root_dir) catch {};

    const temp_install_dir = try std.fs.path.join(allocator, &.{ temp_root_dir, "payload" });
    defer allocator.free(temp_install_dir);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, temp_install_dir);

    const archive_path = try std.fs.path.join(allocator, &.{ temp_root_dir, target.asset });
    defer allocator.free(archive_path);

    try out.print("Downloading {s}\n", .{resolved_asset.download_url});
    github_release_fetch.downloadAssetToFile(allocator, resolved_asset.download_url, archive_path) catch |download_err| {
        switch (download_err) {
            error.GitHubReleaseAssetNotFound => try err.print("Release asset download returned 404 for {s}.\n", .{resolved_asset.download_url}),
            else => try err.print("Failed to download LLVM archive from {s}: {s}\n", .{ resolved_asset.download_url, @errorName(download_err) }),
        }
        return download_err;
    };

    try out.print("Extracting {s}\n", .{target.asset});
    archive_extract.extractArchive(allocator, archive_path, target.archive, temp_install_dir) catch |extract_err| {
        try err.print("Failed to extract {s}: {s}\n", .{ archive_path, @errorName(extract_err) });
        return extract_err;
    };

    if (!looksLikeLlvmInstall(allocator, temp_install_dir)) {
        try err.print("Extracted LLVM archive did not produce a usable install tree at {s}.\n", .{temp_install_dir});
        return error.InvalidInstalledToolchain;
    }

    try writeInstallMarker(allocator, temp_install_dir, .{
        .llvm_version = metadata.llvm_version,
        .host_key = host_key,
        .release_tag = metadata.llvm_release_tag,
        .asset_name = target.asset,
    });

    try std.Io.Dir.renameAbsolute(temp_install_dir, install_home, std.Options.debug_io);
    if (dirExistsAbsolute(temp_root_dir)) {
        std.Io.Dir.cwd().deleteTree(std.Options.debug_io, temp_root_dir) catch {};
    }
    try out.print("Installed LLVM toolchain into {s}\n", .{install_home});
}

fn isInstalledAndValid(
    allocator: std.mem.Allocator,
    install_home: []const u8,
    expected: InstallMarker,
) !bool {
    if (!dirExistsAbsolute(install_home)) return false;
    if (!looksLikeLlvmInstall(allocator, install_home)) return false;

    const marker_path = try installMarkerPath(allocator, install_home);
    defer allocator.free(marker_path);
    if (!fileExistsAbsolute(marker_path)) return false;

    const marker = readInstallMarker(allocator, marker_path) catch return false;
    defer marker.deinit(allocator);

    return std.mem.eql(u8, marker.llvm_version, expected.llvm_version) and
        std.mem.eql(u8, marker.host_key, expected.host_key) and
        std.mem.eql(u8, marker.release_tag, expected.release_tag) and
        std.mem.eql(u8, marker.asset_name, expected.asset_name);
}

fn writeInstallMarker(
    allocator: std.mem.Allocator,
    install_home: []const u8,
    marker: InstallMarker,
) !void {
    const marker_path = try installMarkerPath(allocator, install_home);
    defer allocator.free(marker_path);

    const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, marker_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.Options.debug_io, &buffer);
    try std.json.Stringify.value(marker, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn readInstallMarker(allocator: std.mem.Allocator, marker_path: []const u8) !OwnedMarker {
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, marker_path, allocator, .limited(4 * 1024));
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(InstallMarker, allocator, contents, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    return .{
        .llvm_version = try allocator.dupe(u8, parsed.value.llvm_version),
        .host_key = try allocator.dupe(u8, parsed.value.host_key),
        .release_tag = try allocator.dupe(u8, parsed.value.release_tag),
        .asset_name = try allocator.dupe(u8, parsed.value.asset_name),
    };
}

const OwnedMarker = struct {
    llvm_version: []const u8,
    host_key: []const u8,
    release_tag: []const u8,
    asset_name: []const u8,

    fn deinit(self: OwnedMarker, allocator: std.mem.Allocator) void {
        allocator.free(self.llvm_version);
        allocator.free(self.host_key);
        allocator.free(self.release_tag);
        allocator.free(self.asset_name);
    }
};

fn installMarkerPath(allocator: std.mem.Allocator, install_home: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ install_home, install_marker_name });
}

fn temporaryInstallDir(
    allocator: std.mem.Allocator,
    version_root: []const u8,
    host_key: []const u8,
) ![]const u8 {
    var stamp_bytes: [8]u8 = undefined;
    std.Options.debug_io.random(&stamp_bytes);
    const stamp = std.mem.readInt(u64, &stamp_bytes, .little);
    const dirname = try std.fmt.allocPrint(allocator, ".{s}.tmp-{d}", .{ host_key, stamp });
    defer allocator.free(dirname);
    return std.fs.path.join(allocator, &.{ version_root, dirname });
}

fn looksLikeLlvmInstall(allocator: std.mem.Allocator, install_home: []const u8) bool {
    const include_dir = std.fs.path.join(allocator, &.{ install_home, "include" }) catch return false;
    defer allocator.free(include_dir);

    const core_header = std.fs.path.join(allocator, &.{ include_dir, "llvm-c", "Core.h" }) catch return false;
    defer allocator.free(core_header);
    const config_header = std.fs.path.join(allocator, &.{ include_dir, "llvm", "Config", "llvm-config.h" }) catch return false;
    defer allocator.free(config_header);
    if (!fileExistsAbsolute(core_header) or !fileExistsAbsolute(config_header)) return false;

    const library_candidates = switch (builtin.os.tag) {
        .windows => [_][]const []const u8{
            &.{ install_home, "bin", "LLVM-C.dll" },
            &.{ install_home, "lib", "LLVM-C.dll" },
        },
        .linux => [_][]const []const u8{
            &.{ install_home, "lib", "libLLVM-C.so" },
            &.{ install_home, "bin", "libLLVM-C.so" },
        },
        .macos => [_][]const []const u8{
            &.{ install_home, "lib", "libLLVM-C.dylib" },
            &.{ install_home, "lib", "libLLVM.dylib" },
            &.{ install_home, "bin", "libLLVM-C.dylib" },
            &.{ install_home, "bin", "libLLVM.dylib" },
        },
        else => return false,
    };

    for (library_candidates) |parts| {
        const path = std.fs.path.join(allocator, parts) catch continue;
        defer allocator.free(path);
        if (fileExistsAbsolute(path)) return true;
    }
    return false;
}

fn dirExistsAbsolute(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}

fn fileExistsAbsolute(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}

test "validates managed marker and install path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const install_home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(install_home);
    try tmp.dir.createDirPath(std.testing.io, "include/llvm-c");
    try tmp.dir.createDirPath(std.testing.io, "include/llvm/Config");
    const library_relative_path = switch (builtin.os.tag) {
        .windows => "bin/LLVM-C.dll",
        .linux => "lib/libLLVM-C.so",
        .macos => "lib/libLLVM.dylib",
        else => return error.UnsupportedLlvmHost,
    };
    if (std.fs.path.dirname(library_relative_path)) |parent| {
        try tmp.dir.createDirPath(std.testing.io, parent);
    }

    try writeFile(tmp.dir, "include/llvm-c/Core.h", "");
    try writeFile(tmp.dir, "include/llvm/Config/llvm-config.h", "");
    try writeFile(tmp.dir, library_relative_path, "");

    const metadata = try llvm_metadata.parseFile(std.testing.allocator, "llvm-metadata.toml");
    defer metadata.deinit(std.testing.allocator);
    const target = metadata.findTarget("x86_64-windows-msvc").?;

    try writeInstallMarker(std.testing.allocator, install_home, .{
        .llvm_version = metadata.llvm_version,
        .host_key = target.key,
        .release_tag = metadata.llvm_release_tag,
        .asset_name = target.asset,
    });

    try std.testing.expect(try isInstalledAndValid(std.testing.allocator, install_home, .{
        .llvm_version = metadata.llvm_version,
        .host_key = target.key,
        .release_tag = metadata.llvm_release_tag,
        .asset_name = target.asset,
    }));
}

fn writeFile(dir: std.fs.Dir, relative_path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(relative_path)) |parent| {
        try dir.createDirPath(std.Options.debug_io, parent);
    }
    const file = try dir.createFile(relative_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, contents);
}
