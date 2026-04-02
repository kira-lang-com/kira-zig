pub const ProjectManifest = struct {
    name: []const u8,
    version: []const u8,
    packages: []const []const u8,
    execution_mode: []const u8 = "vm",
    build_target: []const u8 = "host",
};
