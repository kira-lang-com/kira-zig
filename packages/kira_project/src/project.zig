const manifest = @import("kira_manifest");

pub const Project = struct {
    manifest: manifest.ProjectManifest,
};

pub const ResolvedProject = struct {
    root_path: []const u8,
    manifest_path: []const u8,
    entrypoint_path: []const u8,
    project: Project,
};

pub const ResolvedPackageRoot = struct {
    root_path: []const u8,
    manifest_path: []const u8,
    entrypoint_path: ?[]const u8 = null,
    module_source_root: []const u8,
    project: Project,
};
