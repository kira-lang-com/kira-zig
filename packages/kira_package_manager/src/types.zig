const manifest = @import("kira_manifest");

pub const SyncOptions = struct {
    offline: bool = false,
    locked: bool = false,
    update_registry: bool = false,
    update_git: bool = false,
    registry_url_override: ?[]const u8 = null,
};

pub const ResolvedGraph = struct {
    packages: []const ResolvedPackage,
};

pub const ResolvedPackage = struct {
    name: []const u8,
    version: []const u8 = "",
    kind: []const u8 = "library",
    kira_version: []const u8 = "0.1.0",
    module_root: []const u8,
    source_root: []const u8,
    source: Source,
    dependencies: []const manifest.DependencySpec = &.{},

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

pub const SyncResult = struct {
    graph: ResolvedGraph,
    lockfile: manifest.LockFile,
    changed: bool = false,
};

pub const ModuleMap = struct {
    owners: []const ModuleOwner,

    pub const ModuleOwner = struct {
        module_root: []const u8,
        package_name: []const u8,
        source_root: []const u8,
    };
};
