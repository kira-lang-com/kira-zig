const dependency = @import("dependency.zig");
const platform_config = @import("platform_config.zig");
const native = @import("kira_native_lib_definition");
const tests_config = @import("tests_config.zig");

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
    native_libraries: []const []const u8 = &.{},
    /// Native libraries declared inline in a `package.kira` manifest (the
    /// `NativeLibrary { ... }` entries). The TOML loader leaves this empty and
    /// uses `native_libraries` (paths to `NativeLibs/*.toml`) instead; the
    /// declaration loader populates this and leaves `native_libraries` empty.
    /// Both feed the same native-library resolution pipeline in `kira_build`.
    inline_native_libraries: []const native.NativeLibrarySpec = &.{},
    /// Project-root-relative directories (or files) bundled into a
    /// self-contained `wasm32-emscripten` package via emcc `--preload-file`.
    /// Accepted (and validated) on every target; only wasm builds package them,
    /// because host/native builds read the same paths from disk at runtime.
    assets: []const []const u8 = &.{},
    dependencies: []const dependency.DependencySpec = &.{},
    packages: []const []const u8 = &.{},
    execution_mode: []const u8 = "vm",
    execution_policy: platform_config.ExecutionPolicy = .{},
    build_target: []const u8 = "host",
    registry_url: ?[]const u8 = null,
    registry_token_env: ?[]const u8 = null,
    /// The `Tests { backends: [...], phase: ... }` config honored by `kira test`.
    /// `null` means the manifest omitted it (runner keeps historical behavior).
    tests: ?tests_config.TestsConfig = null,
    resolved_config: platform_config.ResolvedConfig = platform_config.defaultResolvedConfig(),
};
