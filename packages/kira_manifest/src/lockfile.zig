const dependency = @import("dependency.zig");

pub const LockFile = struct {
    schema_version: u32 = 1,
    root: Root = .{},
    packages: []const LockedPackage = &.{},

    pub const Root = struct {
        name: []const u8 = "",
        version: []const u8 = "",
        kind: []const u8 = "app",
        kira_version: []const u8 = "0.1.0",
        dependencies: []const RootDependency = &.{},
    };

    pub const RootDependency = struct {
        name: []const u8,
        source: dependency.DependencySpec.Source,
    };

    pub const LockedPackage = struct {
        name: []const u8,
        version: []const u8 = "",
        kind: []const u8 = "library",
        kira_version: []const u8 = "0.1.0",
        module_root: []const u8,
        source: Source,
        dependencies: []const []const u8 = &.{},

        pub const Source = union(enum) {
            registry: RegistrySource,
            path: PathSource,
            git: GitSource,
        };

        pub const RegistrySource = struct {
            registry_url: []const u8,
            archive_path: []const u8,
            checksum: []const u8,
        };

        pub const PathSource = struct {
            path: []const u8,
        };

        pub const GitSource = struct {
            url: []const u8,
            commit: []const u8,
            requested_rev: ?[]const u8 = null,
            requested_tag: ?[]const u8 = null,
        };
    };
};
