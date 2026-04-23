const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const manifest = @import("kira_manifest");
const package_manager = @import("kira_package_manager");
const support = @import("../support.zig");

pub const ManifestLocation = struct {
    root_path: []const u8,
    manifest_path: []const u8,
    manifest: manifest.ProjectManifest,
};

pub fn loadManifestLocation(allocator: std.mem.Allocator, input_path: ?[]const u8) !ManifestLocation {
    const path = input_path orelse ".";
    const root_path = if (isManifestPath(path))
        try absolutize(allocator, std.fs.path.dirname(path) orelse ".")
    else blk: {
        const absolute = try absolutize(allocator, path);
        if (!isDirectory(absolute)) {
            allocator.free(absolute);
            break :blk try absolutize(allocator, ".");
        }
        break :blk absolute;
    };
    errdefer allocator.free(root_path);

    const manifest_path = try discoverManifestPath(allocator, root_path) orelse return error.ProjectManifestNotFound;
    errdefer allocator.free(manifest_path);
    const text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, manifest_path, allocator, .limited(2 * 1024 * 1024));
    return .{
        .root_path = root_path,
        .manifest_path = manifest_path,
        .manifest = try manifest.parseProjectManifest(allocator, text),
    };
}

pub fn writeManifest(manifest_path: []const u8, project_manifest: manifest.ProjectManifest) !void {
    const allocator = std.heap.page_allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try manifest.writeProjectManifest(&output.writer, project_manifest);
    const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, manifest_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, output.written());
}

pub fn latestRegistryVersion(
    allocator: std.mem.Allocator,
    registry_url: []const u8,
    package_name: []const u8,
) ![]u8 {
    const metadata = try package_manager.fetchPackageMetadata(allocator, registry_url, package_name);
    if (metadata.versions.len == 0) return error.RegistryVersionNotFound;

    var best = metadata.versions[0].version;
    for (metadata.versions[1..]) |version| {
        if (versionNewerThan(version.version, best)) best = version.version;
    }
    return allocator.dupe(u8, best);
}

pub fn versionNewerThan(lhs: []const u8, rhs: []const u8) bool {
    const left = std.SemanticVersion.parse(lhs) catch return std.mem.order(u8, lhs, rhs) == .gt;
    const right = std.SemanticVersion.parse(rhs) catch return std.mem.order(u8, lhs, rhs) == .gt;
    return std.SemanticVersion.order(left, right) == .gt;
}

pub fn upsertDependency(
    allocator: std.mem.Allocator,
    project_manifest: *manifest.ProjectManifest,
    dep_spec: manifest.DependencySpec,
) !void {
    var items = std.array_list.Managed(manifest.DependencySpec).init(allocator);
    var replaced = false;
    for (project_manifest.dependencies) |existing| {
        if (std.mem.eql(u8, existing.name, dep_spec.name)) {
            try items.append(dep_spec);
            replaced = true;
        } else {
            try items.append(existing);
        }
    }
    if (!replaced) try items.append(dep_spec);
    project_manifest.dependencies = try items.toOwnedSlice();
}

pub fn removeDependency(project_manifest: *manifest.ProjectManifest, name: []const u8) bool {
    var items = std.array_list.Managed(manifest.DependencySpec).init(std.heap.page_allocator);
    var found = false;
    for (project_manifest.dependencies) |item| {
        if (std.mem.eql(u8, item.name, name)) {
            found = true;
            continue;
        }
        items.append(item) catch return found;
    }
    project_manifest.dependencies = items.toOwnedSlice() catch return found;
    return found;
}

pub fn syncAndRender(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    stdout: anytype,
    stderr: anytype,
    options: package_manager.SyncOptions,
) !void {
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = package_manager.syncProject(allocator, root_path, support.versionString(), options, &diags) catch |err| {
        if (err == error.DiagnosticsEmitted) {
            try support.renderStandaloneDiagnostics(stderr, diags.items);
            return error.CommandFailed;
        }
        return err;
    };

    if (result.changed) {
        try stdout.writeAll("updated kira.lock\n");
    } else {
        try stdout.writeAll("kira.lock is up to date\n");
    }
}

fn discoverManifestPath(allocator: std.mem.Allocator, root_path: []const u8) !?[]u8 {
    const candidates = [_][]const u8{ "kira.toml", "project.toml", "Kira.toml" };
    for (candidates) |name| {
        const path = try std.fs.path.join(allocator, &.{ root_path, name });
        if (fileExists(path)) return path;
        allocator.free(path);
    }
    return null;
}

fn isDirectory(path: []const u8) bool {
    var dir = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}

fn isManifestPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, "kira.toml") or std.mem.eql(u8, base, "project.toml") or std.mem.eql(u8, base, "Kira.toml");
}

fn absolutize(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, allocator);
}

fn fileExists(path: []const u8) bool {
    var file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}
