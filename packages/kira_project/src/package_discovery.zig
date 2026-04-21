const std = @import("std");
const manifest = @import("kira_manifest");
const Project = @import("project.zig").Project;
const ResolvedProject = @import("project.zig").ResolvedProject;

pub const preferred_manifest_file_name = "kira.toml";
pub const legacy_manifest_file_name = "project.toml";
pub const repo_manifest_file_name = "Kira.toml";
pub const manifest_file_name = preferred_manifest_file_name;
pub const entrypoint_rel_path = "app/main.kira";

pub const manifest_file_names = [_][]const u8{
    preferred_manifest_file_name,
    legacy_manifest_file_name,
    repo_manifest_file_name,
};

pub fn loadProjectFromFile(allocator: std.mem.Allocator, path: []const u8) !Project {
    const text = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    return .{
        .manifest = try manifest.parseProjectManifest(allocator, text),
    };
}

pub fn loadProjectFromPath(allocator: std.mem.Allocator, path: []const u8) !ResolvedProject {
    const root_path = try resolveRootPath(allocator, path);
    const manifest_path = try discoverManifestPath(allocator, root_path) orelse return error.ProjectManifestNotFound;

    const entrypoint_path = try std.fs.path.join(allocator, &.{ root_path, "app", "main.kira" });
    if (!fileExists(entrypoint_path)) return error.ProjectEntrypointNotFound;

    return .{
        .root_path = root_path,
        .manifest_path = manifest_path,
        .entrypoint_path = entrypoint_path,
        .project = try loadProjectFromFile(allocator, manifest_path),
    };
}

fn resolveRootPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (isManifestPath(path)) {
        const directory = std.fs.path.dirname(path) orelse ".";
        return absolutize(allocator, directory);
    }

    if (directoryExists(path)) {
        return absolutize(allocator, path);
    }

    return error.ProjectManifestNotFound;
}

fn discoverManifestPath(allocator: std.mem.Allocator, root_path: []const u8) !?[]u8 {
    for (manifest_file_names) |name| {
        const candidate = try std.fs.path.join(allocator, &.{ root_path, name });
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn isManifestPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    for (manifest_file_names) |name| {
        if (std.mem.eql(u8, base, name)) return true;
    }
    return false;
}

fn absolutize(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.cwd().realpathAlloc(allocator, path);
}

fn fileExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        var file = std.fs.openFileAbsolute(path, .{}) catch return false;
        file.close();
        return true;
    }

    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn directoryExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
        dir.close();
        return true;
    }

    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}
