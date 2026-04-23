const std = @import("std");
const manifest = @import("kira_manifest");
const package_manager = @import("kira_package_manager");
const package_support = @import("package_support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len == 0) return error.InvalidArguments;
    if (std.mem.eql(u8, args[0], "pack")) return executePack(allocator, args[1..], stdout);
    if (std.mem.eql(u8, args[0], "inspect")) return executeInspect(allocator, args[1..], stdout, stderr);
    return error.InvalidArguments;
}

fn executePack(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype) !void {
    if (args.len > 1) return error.InvalidArguments;
    const location = try package_support.loadManifestLocation(allocator, if (args.len == 0) null else args[0]);
    for (location.manifest.dependencies) |dep_spec| {
        if (dep_spec.source == .path) return error.InvalidArguments;
    }

    const generated_root = try std.fs.path.join(allocator, &.{ location.root_path, "generated" });
    defer allocator.free(generated_root);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, generated_root);

    const archive_name = try std.fmt.allocPrint(allocator, "{s}-{s}.tar", .{ location.manifest.name, location.manifest.version });
    defer allocator.free(archive_name);
    const archive_path = try std.fs.path.join(allocator, &.{ generated_root, archive_name });
    defer allocator.free(archive_path);

    const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, archive_path, .{ .truncate = true });
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(std.Options.debug_io, &buffer);
    var tar_writer = std.tar.Writer{ .underlying_writer = &writer.interface };
    try addProjectTree(allocator, location.root_path, location.root_path, &tar_writer);
    try tar_writer.finishPedantically();
    try writer.interface.flush();
    file.close(std.Options.debug_io);

    const archive_file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, archive_path, .{});
    defer archive_file.close(std.Options.debug_io);
    var read_buffer: [16 * 1024]u8 = undefined;
    var archive_reader = archive_file.reader(std.Options.debug_io, &read_buffer);
    const bytes = try archive_reader.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    const checksum = try package_manager.sha256Hex(allocator, bytes);
    defer allocator.free(checksum);

    try stdout.print("packed {s}\nsha256 {s}\n", .{ archive_path, checksum });
}

fn executeInspect(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    _ = stderr;
    if (args.len > 1) return error.InvalidArguments;
    const target = args[0];
    if (isDirectory(target)) {
        const location = try package_support.loadManifestLocation(allocator, target);
        try printManifestSummary(stdout, location.manifest);
        return;
    }

    const archive_path = try absolutize(allocator, target);
    defer allocator.free(archive_path);
    const temp_dir = try std.fmt.allocPrint(allocator, "{s}.inspect", .{archive_path});
    defer allocator.free(temp_dir);
    _ = std.Io.Dir.cwd().deleteTree(std.Options.debug_io, temp_dir) catch {};
    try package_manager.extractTarSecure(allocator, archive_path, temp_dir);

    try stdout.print("archive {s}\n", .{archive_path});
    const manifest_path = try printExtractedTree(allocator, stdout, temp_dir, temp_dir);
    if (manifest_path) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(2 * 1024 * 1024));
        const parsed = try manifest.parseProjectManifest(allocator, text);
        try printManifestSummary(stdout, parsed);
    }
}

fn printManifestSummary(stdout: anytype, project_manifest: manifest.ProjectManifest) !void {
    try stdout.print("package {s} {s}\n", .{ project_manifest.name, project_manifest.version });
    try stdout.print("kind {s}\n", .{@tagName(project_manifest.kind)});
    try stdout.print("kira {s}\n", .{project_manifest.kira_version});
    if (project_manifest.dependencies.len == 0) {
        try stdout.writeAll("dependencies none\n");
        return;
    }
    for (project_manifest.dependencies) |dep_spec| {
        switch (dep_spec.source) {
            .registry => |registry_source| try stdout.print("dependency {s} registry {s}\n", .{ dep_spec.name, registry_source.version }),
            .path => |path_source| try stdout.print("dependency {s} path {s}\n", .{ dep_spec.name, path_source.path }),
            .git => |git_source| try stdout.print("dependency {s} git {s}\n", .{ dep_spec.name, git_source.url }),
        }
    }
}

fn addProjectTree(allocator: std.mem.Allocator, root_path: []const u8, current_path: []const u8, tar_writer: *std.tar.Writer) !void {
    var dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, current_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var iterator = dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (shouldSkip(entry.name)) continue;
        const child_path = try std.fs.path.join(allocator, &.{ current_path, entry.name });
        defer allocator.free(child_path);
        const cwd = try std.process.currentPathAlloc(std.Options.debug_io, allocator);
        defer allocator.free(cwd);
        const relative_native = try std.fs.path.relative(allocator, cwd, null, root_path, child_path);
        defer allocator.free(relative_native);
        const relative = try normalizeArchivePath(allocator, relative_native);
        defer allocator.free(relative);

        switch (entry.kind) {
            .directory => try addProjectTree(allocator, root_path, child_path, tar_writer),
            .file => {
                if (shouldSkipFile(relative)) continue;
                const child_file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, child_path, .{});
                defer child_file.close(std.Options.debug_io);
                var read_buffer: [16 * 1024]u8 = undefined;
                var reader = child_file.reader(std.Options.debug_io, &read_buffer);
                const stat = try child_file.stat(std.Options.debug_io);
                const mtime_seconds = stat.mtime.toSeconds();
                try tar_writer.writeFile(relative, &reader, if (mtime_seconds > 0) @intCast(mtime_seconds) else 0);
            },
            else => {},
        }
    }
}

fn printExtractedTree(
    allocator: std.mem.Allocator,
    stdout: anytype,
    root_path: []const u8,
    current_path: []const u8,
) !?[]const u8 {
    var manifest_path: ?[]const u8 = null;
    var dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, current_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var iterator = dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ current_path, entry.name });
        defer allocator.free(child_path);
        const cwd = try std.process.currentPathAlloc(std.Options.debug_io, allocator);
        defer allocator.free(cwd);
        const relative = try std.fs.path.relative(allocator, cwd, null, root_path, child_path);
        defer allocator.free(relative);

        switch (entry.kind) {
            .directory => {
                const nested = try printExtractedTree(allocator, stdout, root_path, child_path);
                if (nested != null) manifest_path = nested;
            },
            .file => {
                try stdout.print("  {s}\n", .{relative});
                if (isManifestFile(relative)) manifest_path = try allocator.dupe(u8, child_path);
            },
            else => {},
        }
    }
    return manifest_path;
}

fn shouldSkip(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, ".kira") or
        std.mem.eql(u8, name, "generated");
}

fn shouldSkipFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.mem.eql(u8, ext, ".o") or
        std.mem.eql(u8, ext, ".obj") or
        std.mem.eql(u8, ext, ".dll") or
        std.mem.eql(u8, ext, ".so") or
        std.mem.eql(u8, ext, ".dylib") or
        std.mem.eql(u8, ext, ".exe") or
        std.mem.eql(u8, ext, ".a") or
        std.mem.eql(u8, ext, ".lib") or
        std.mem.eql(u8, ext, ".kbc") or
        std.mem.eql(u8, ext, ".khm");
}

fn isManifestFile(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, "kira.toml") or std.mem.eql(u8, base, "project.toml") or std.mem.eql(u8, base, "Kira.toml");
}

fn normalizeArchivePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path);
    _ = std.mem.replaceScalar(u8, normalized, '\\', '/');
    return normalized;
}

fn isDirectory(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}

fn absolutize(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, allocator);
}
