//! Builds the SourceWatcher over every file-system input of a live bundle
//! build, for the main target and each dependency package: `app/`
//! sources/shaders/assets, native library sources under `NativeLibs/`, and
//! each package's `kira.toml`. Shared by the desktop supervisor and the Apple
//! live sessions so every `kira live` platform reloads on any input change.
const std = @import("std");
const live = @import("root.zig");
const SourceWatcher = @import("source_watcher.zig").SourceWatcher;

pub fn createSourceWatcher(
    allocator: std.mem.Allocator,
    target: live.ResolvedLiveTarget,
    bundles: live.BundleBuildArtifacts,
) !SourceWatcher {
    var watcher = SourceWatcher.init(allocator);
    errdefer watcher.deinit();

    try watchPackageInputs(&watcher, allocator, target.validation_app_root);
    for (bundles.graph.bundles) |bundle| {
        try watchPackageInputs(&watcher, allocator, bundle.package_root);
    }

    return watcher;
}

fn watchPackageInputs(watcher: *SourceWatcher, allocator: std.mem.Allocator, package_root: []const u8) !void {
    const watched_subdirs = [_][]const u8{ "app", "NativeLibs" };
    for (watched_subdirs) |subdir| {
        const dir = try std.fs.path.join(allocator, &.{ package_root, subdir });
        defer allocator.free(dir);
        if (directoryExists(dir)) {
            try watcher.addDirectory(dir);
        }
    }
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, "kira.toml" });
    defer allocator.free(manifest_path);
    try watcher.addFile(manifest_path);
}

fn directoryExists(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}
