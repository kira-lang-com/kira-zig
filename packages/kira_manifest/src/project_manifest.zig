const dependency = @import("dependency.zig");

pub const PackageKind = enum {
    app,
    library,
};

pub const ProjectManifest = struct {
    name: []const u8,
    version: []const u8,
    kind: PackageKind = .app,
    kira_version: []const u8 = "0.1.0",
    module_root: ?[]const u8 = null,
    dependencies: []const dependency.DependencySpec = &.{},
    packages: []const []const u8 = &.{},
    execution_mode: []const u8 = "vm",
    build_target: []const u8 = "host",
    registry_url: ?[]const u8 = null,
    registry_token_env: ?[]const u8 = null,
};
