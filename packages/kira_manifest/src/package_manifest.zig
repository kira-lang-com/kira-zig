pub const PackageManifest = struct {
    name: []const u8,
    version: []const u8 = "0.1.0",
    dependencies: []const []const u8 = &.{},
    native_libs: []const []const u8 = &.{},
};
