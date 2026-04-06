pub const Project = @import("project.zig").Project;
pub const ResolvedProject = @import("project.zig").ResolvedProject;
pub const Workspace = @import("workspace.zig").Workspace;
pub const loadProjectFromFile = @import("package_discovery.zig").loadProjectFromFile;
pub const loadProjectFromPath = @import("package_discovery.zig").loadProjectFromPath;
pub const manifest_file_name = @import("package_discovery.zig").manifest_file_name;
pub const entrypoint_rel_path = @import("package_discovery.zig").entrypoint_rel_path;
