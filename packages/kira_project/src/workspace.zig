const project_pkg = @import("project.zig");

pub const Workspace = struct {
    root_path: []const u8,
    project: project_pkg.Project,
};
