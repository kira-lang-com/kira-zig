const dependency = @import("dependency.zig");
const PackageKind = @import("project_manifest.zig").PackageKind;

pub const PackageManifest = struct {
    name: []const u8,
    version: []const u8 = "0.1.0",
    kind: PackageKind = .library,
    kira_version: []const u8 = "0.1.0",
    module_root: ?[]const u8 = null,
    dependencies: []const dependency.DependencySpec = &.{},
    native_libs: []const []const u8 = &.{},
};
