const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("kira_manifest");
const native = @import("kira_native_lib_definition");
const syntax = @import("kira_syntax_model");
const package_manager = @import("kira_package_manager");
const program_graph = @import("kira_program_graph");
const resolver = @import("native_lib_resolver.zig");
const autobind = @import("ffi_autobind.zig");
const autobind_cache = @import("ffi_autobind_cache.zig");
const artifact = @import("native_artifact_build.zig");
const paths = @import("native_build_paths.zig");

fn nowTimestamp() std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
}

fn elapsedNs(start: std.Io.Clock.Timestamp) u64 {
    const duration_ns = start.durationTo(std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake)).raw.toNanoseconds();
    return @intCast(@max(duration_ns, 0));
}

fn timingsEnvEnabled() bool {
    if (!builtin.link_libc) return false;
    const raw = std.c.getenv("KIRA_TIMINGS") orelse return false;
    const value = std.mem.span(raw);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

fn timingPrint(comptime fmt: []const u8, args: anytype) void {
    if (timingsEnvEnabled()) std.debug.print(fmt, args);
}

pub const NativePreparationMode = enum {
    full,
    artifacts_only,
    resolve_only,
};

pub const NativeWarningKind = enum {
    artifact_out_of_date,
    bindings_out_of_date,
    skipped_missing_environment,
};

pub const NativeWarning = struct {
    kind: NativeWarningKind,
    library_name: []const u8,
    manifest_path: ?[]const u8 = null,
    artifact_path: ?[]const u8 = null,
    bindings_path: ?[]const u8 = null,
    /// Extra context for the warning; for `skipped_missing_environment` this is
    /// the name of the unset environment variable.
    detail: ?[]const u8 = null,
};

var native_preparation_mode: NativePreparationMode = .full;

pub fn setNativePreparationMode(mode: NativePreparationMode) void {
    native_preparation_mode = mode;
    autobind.setBindingMode(if (mode == .full) .ensure else .skip);
}

pub fn prepareNativeLibraries(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    imports: []const syntax.ast.ImportDecl,
) ![]const native.ResolvedNativeLibrary {
    return prepareNativeLibrariesForTarget(allocator, source_path, imports, null);
}

pub fn prepareNativeLibrariesForTarget(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    imports: []const syntax.ast.ImportDecl,
    explicit_selector: ?native.TargetSelector,
) ![]const native.ResolvedNativeLibrary {
    const selector = try resolvedTargetSelector(allocator, explicit_selector);
    const manifest_paths = try loadProjectNativeManifestPaths(allocator, source_path);
    _ = imports;

    var libraries = std.array_list.Managed(native.ResolvedNativeLibrary).init(allocator);
    for (manifest_paths) |manifest_path| {
        var library = try resolver.resolveNativeManifestFile(allocator, manifest_path, selector);
        try applyPreparationPolicy(allocator, &library);
        try libraries.append(library);
    }
    return libraries.toOwnedSlice();
}

pub fn prepareImportedNativeLibraries(
    allocator: std.mem.Allocator,
    existing: []const native.ResolvedNativeLibrary,
    imports: []const syntax.ast.ImportDecl,
    module_map: package_manager.ModuleMap,
) ![]const native.ResolvedNativeLibrary {
    return prepareImportedNativeLibrariesForTarget(allocator, existing, imports, module_map, null);
}

/// Prepare native libraries (artifacts + generated bindings) for every package the
/// module map declares, not just packages named by parsed imports. This must run
/// before the program graph is built so freshly generated `bindings/` sources are
/// part of the same compilation instead of appearing one run later.
pub fn prepareDeclaredNativeLibrariesForTarget(
    allocator: std.mem.Allocator,
    existing: []const native.ResolvedNativeLibrary,
    module_map: package_manager.ModuleMap,
    explicit_selector: ?native.TargetSelector,
) ![]const native.ResolvedNativeLibrary {
    const selector = try resolvedTargetSelector(allocator, explicit_selector);
    var libraries = std.array_list.Managed(native.ResolvedNativeLibrary).init(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    var visited_packages = std.StringHashMap(void).init(allocator);

    for (existing) |library| {
        try libraries.append(library);
        try seen.put(try artifactIdentity(allocator, library), {});
    }

    for (module_map.owners) |owner| {
        const package_root = std.fs.path.dirname(owner.source_root) orelse continue;
        try appendNativeLibrariesFromPackageRootRecursive(allocator, selector, package_root, module_map, &visited_packages, &seen, &libraries);
    }

    return libraries.toOwnedSlice();
}

pub fn collectDeclaredNativeWarningsForSource(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    explicit_selector: ?native.TargetSelector,
) ![]const NativeWarning {
    const libraries = try resolveDeclaredNativeLibrariesForSource(allocator, source_path, explicit_selector);
    return collectWarningsForLibraries(allocator, libraries);
}

pub fn collectDeclaredNativeWarningsForSourceRoot(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    explicit_selector: ?native.TargetSelector,
) ![]const NativeWarning {
    const module_files = try program_graph.collectPackageModuleFiles(allocator, source_root);
    if (module_files.len == 0) return &.{};
    return collectDeclaredNativeWarningsForSource(allocator, module_files[0], explicit_selector);
}

pub fn ensureDeclaredNativeBindingsForSource(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    explicit_selector: ?native.TargetSelector,
) ![]const native.ResolvedNativeLibrary {
    const libraries = try resolveDeclaredNativeLibrariesForSource(allocator, source_path, explicit_selector);
    for (libraries) |library| {
        // A library whose required environment/SDK is unresolved on this machine
        // cannot be autobound; skip it here and let the caller surface a warning.
        if (library.unavailable != null) continue;
        try autobind.ensureGeneratedBindings(allocator, library);
    }
    return libraries;
}

pub fn ensureDeclaredNativeBindingsForSourceRoot(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    explicit_selector: ?native.TargetSelector,
) ![]const native.ResolvedNativeLibrary {
    const module_files = try program_graph.collectPackageModuleFiles(allocator, source_root);
    if (module_files.len == 0) return &.{};
    return ensureDeclaredNativeBindingsForSource(allocator, module_files[0], explicit_selector);
}

pub fn prepareImportedNativeLibrariesForTarget(
    allocator: std.mem.Allocator,
    existing: []const native.ResolvedNativeLibrary,
    imports: []const syntax.ast.ImportDecl,
    module_map: package_manager.ModuleMap,
    explicit_selector: ?native.TargetSelector,
) ![]const native.ResolvedNativeLibrary {
    const selector = try resolvedTargetSelector(allocator, explicit_selector);
    var libraries = std.array_list.Managed(native.ResolvedNativeLibrary).init(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    var visited_packages = std.StringHashMap(void).init(allocator);

    for (existing) |library| {
        try libraries.append(library);
        try seen.put(try artifactIdentity(allocator, library), {});
    }

    for (imports) |import_decl| {
        const owner = program_graph.packageRootOwnerForImport(module_map, import_decl.module_name) orelse continue;
        const package_root = std.fs.path.dirname(owner.source_root) orelse continue;
        try appendNativeLibrariesFromPackageRootRecursive(allocator, selector, package_root, module_map, &visited_packages, &seen, &libraries);
    }

    return libraries.toOwnedSlice();
}

fn appendNativeLibrariesFromPackageRootRecursive(
    allocator: std.mem.Allocator,
    selector: native.TargetSelector,
    package_root: []const u8,
    module_map: package_manager.ModuleMap,
    visited_packages: *std.StringHashMap(void),
    seen: *std.StringHashMap(void),
    libraries: *std.array_list.Managed(native.ResolvedNativeLibrary),
) !void {
    const package_key = try packageIdentity(allocator, package_root);
    if (visited_packages.contains(package_key)) return;
    try visited_packages.put(package_key, {});

    try appendNativeLibrariesFromPackageRoot(allocator, selector, package_root, seen, libraries);

    const project_manifest = try loadProjectManifestFromRoot(allocator, package_root);
    for (project_manifest.dependencies) |dependency| {
        const owner = findModuleOwner(module_map, dependency.name) orelse continue;
        const dependency_root = std.fs.path.dirname(owner.source_root) orelse continue;
        try appendNativeLibrariesFromPackageRootRecursive(allocator, selector, dependency_root, module_map, visited_packages, seen, libraries);
    }
}

fn findModuleOwner(module_map: package_manager.ModuleMap, package_name: []const u8) ?package_manager.ModuleMap.ModuleOwner {
    for (module_map.owners) |owner| {
        if (std.mem.eql(u8, owner.package_name, package_name)) return owner;
    }
    return null;
}

fn appendNativeLibrariesFromPackageRoot(
    allocator: std.mem.Allocator,
    selector: native.TargetSelector,
    package_root: []const u8,
    seen: *std.StringHashMap(void),
    libraries: *std.array_list.Managed(native.ResolvedNativeLibrary),
) !void {
    const manifest_paths = try loadNativeManifestPathsFromProjectRoot(allocator, package_root);
    for (manifest_paths) |manifest_path| {
        var library = try resolver.resolveNativeManifestFile(allocator, manifest_path, selector);
        const identity = try artifactIdentity(allocator, library);
        if (seen.contains(identity)) continue;
        try applyPreparationPolicy(allocator, &library);
        try seen.put(identity, {});
        try libraries.append(library);
    }
}

fn resolveDeclaredNativeLibrariesForSource(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    explicit_selector: ?native.TargetSelector,
) ![]const native.ResolvedNativeLibrary {
    const selector = try resolvedTargetSelector(allocator, explicit_selector);
    var libraries = std.array_list.Managed(native.ResolvedNativeLibrary).init(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    var visited_packages = std.StringHashMap(void).init(allocator);

    const manifest_paths = try loadProjectNativeManifestPaths(allocator, source_path);
    try appendResolvedNativeLibrariesFromManifestPaths(allocator, selector, manifest_paths, &seen, &libraries);

    if (package_manager.loadModuleMapForSource(allocator, source_path)) |module_map| {
        for (module_map.owners) |owner| {
            const package_root = std.fs.path.dirname(owner.source_root) orelse continue;
            try appendResolvedNativeLibrariesFromPackageRootRecursive(allocator, selector, package_root, module_map, &visited_packages, &seen, &libraries);
        }
    } else |_| {}

    return libraries.toOwnedSlice();
}

fn appendResolvedNativeLibrariesFromManifestPaths(
    allocator: std.mem.Allocator,
    selector: native.TargetSelector,
    manifest_paths: []const []const u8,
    seen: *std.StringHashMap(void),
    libraries: *std.array_list.Managed(native.ResolvedNativeLibrary),
) !void {
    for (manifest_paths) |manifest_path| {
        const library = try resolver.resolveNativeManifestFile(allocator, manifest_path, selector);
        const identity = try artifactIdentity(allocator, library);
        if (seen.contains(identity)) continue;
        try seen.put(identity, {});
        try libraries.append(library);
    }
}

fn appendResolvedNativeLibrariesFromPackageRootRecursive(
    allocator: std.mem.Allocator,
    selector: native.TargetSelector,
    package_root: []const u8,
    module_map: package_manager.ModuleMap,
    visited_packages: *std.StringHashMap(void),
    seen: *std.StringHashMap(void),
    libraries: *std.array_list.Managed(native.ResolvedNativeLibrary),
) !void {
    const package_key = try packageIdentity(allocator, package_root);
    if (visited_packages.contains(package_key)) return;
    try visited_packages.put(package_key, {});

    const manifest_paths = try loadNativeManifestPathsFromProjectRoot(allocator, package_root);
    try appendResolvedNativeLibrariesFromManifestPaths(allocator, selector, manifest_paths, seen, libraries);

    const project_manifest = try loadProjectManifestFromRoot(allocator, package_root);
    for (project_manifest.dependencies) |dependency| {
        const owner = findModuleOwner(module_map, dependency.name) orelse continue;
        const dependency_root = std.fs.path.dirname(owner.source_root) orelse continue;
        try appendResolvedNativeLibrariesFromPackageRootRecursive(allocator, selector, dependency_root, module_map, visited_packages, seen, libraries);
    }
}

fn collectWarningsForLibraries(
    allocator: std.mem.Allocator,
    libraries: []const native.ResolvedNativeLibrary,
) ![]const NativeWarning {
    var warnings = std.array_list.Managed(NativeWarning).init(allocator);
    for (libraries) |library| {
        if (library.unavailable) |unavailable| {
            // Skipped libraries have unresolved (`${VAR}`) paths that would fail
            // filesystem freshness probing; surface the skip and move on.
            try warnings.append(.{
                .kind = .skipped_missing_environment,
                .library_name = library.name,
                .manifest_path = library.manifest_path,
                .detail = unavailable.detail,
            });
            continue;
        }
        if (library.build.sources.len != 0) {
            const fingerprint = try artifact.nativeArtifactFingerprint(allocator, library);
            defer allocator.free(fingerprint);
            const fingerprint_path = try artifact.nativeArtifactFingerprintPath(allocator, library);
            defer allocator.free(fingerprint_path);
            if (!try artifact.nativeArtifactIsFresh(allocator, library.artifact_path, fingerprint_path, fingerprint)) {
                try warnings.append(.{
                    .kind = .artifact_out_of_date,
                    .library_name = library.name,
                    .manifest_path = library.manifest_path,
                    .artifact_path = library.artifact_path,
                });
            }
        }
        if (library.autobinding) |autobinding| {
            const cache_key = try autobind_cache.cacheKey(allocator, library, autobinding);
            defer allocator.free(cache_key);
            if (!try autobind_cache.bindingsAreCurrent(allocator, autobinding.output_path, cache_key)) {
                try warnings.append(.{
                    .kind = .bindings_out_of_date,
                    .library_name = library.name,
                    .manifest_path = library.manifest_path,
                    .bindings_path = autobinding.output_path,
                });
            }
        }
    }
    return warnings.toOwnedSlice();
}

fn applyPreparationPolicy(allocator: std.mem.Allocator, library: *native.ResolvedNativeLibrary) !void {
    // Unresolvable libraries (e.g. missing `${VULKAN_SDK}`) carry `${VAR}`
    // literals instead of real paths; neither artifact compilation nor
    // autobinding can run against them, so skip preparation entirely.
    if (library.unavailable != null) return;
    switch (native_preparation_mode) {
        .resolve_only => {},
        .artifacts_only => {
            const artifact_start = nowTimestamp();
            try artifact.ensureNativeArtifact(allocator, library);
            timingPrint("[kira:timing] native.ensureArtifact library={s} path={s} ns={d}\n", .{ library.name, library.artifact_path, elapsedNs(artifact_start) });
        },
        .full => {
            const artifact_start = nowTimestamp();
            try artifact.ensureNativeArtifact(allocator, library);
            timingPrint("[kira:timing] native.ensureArtifact library={s} path={s} ns={d}\n", .{ library.name, library.artifact_path, elapsedNs(artifact_start) });
            const autobind_start = nowTimestamp();
            try autobind.ensureGeneratedBindings(allocator, library.*);
            timingPrint("[kira:timing] native.ensureGeneratedBindings library={s} ns={d}\n", .{ library.name, elapsedNs(autobind_start) });
        },
    }
}

fn artifactIdentity(allocator: std.mem.Allocator, library: native.ResolvedNativeLibrary) ![]const u8 {
    if (library.artifact_path.len == 0) {
        return std.fmt.allocPrint(allocator, "runtime-dynamic:{s}:{s}", .{ library.manifest_path orelse "", library.name });
    }
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, library.artifact_path, allocator) catch allocator.dupe(u8, library.artifact_path);
}

fn packageIdentity(allocator: std.mem.Allocator, package_root: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, package_root, allocator) catch allocator.dupe(u8, package_root);
}

fn loadProjectNativeManifestPaths(allocator: std.mem.Allocator, source_path: []const u8) ![]const []const u8 {
    const project_manifest_path = try discoverProjectManifestPath(allocator, source_path) orelse return &.{};
    const project_root = std.fs.path.dirname(project_manifest_path) orelse ".";
    return loadNativeManifestPathsFromProjectRoot(allocator, project_root);
}

fn loadNativeManifestPathsFromProjectRoot(allocator: std.mem.Allocator, project_root: []const u8) ![]const []const u8 {
    const project_manifest = try loadProjectManifestFromRoot(allocator, project_root);

    var manifests = std.array_list.Managed([]const u8).init(allocator);
    for (project_manifest.native_libraries) |value| {
        const project_manifest_path = try paths.findManifestInDirectory(allocator, project_root) orelse return &.{};
        try manifests.append(try absolutizeFromManifest(allocator, project_manifest_path, value));
    }
    return manifests.toOwnedSlice();
}

pub const AssetResolution = struct {
    mounts: []const native.AssetMount,
    /// The first declared `assets` entry whose directory/file does not exist on
    /// disk, or null when every declared asset resolved. Surfaced as a build
    /// diagnostic so a typo or missing directory fails the build instead of
    /// silently shipping an empty package.
    missing: ?[]const u8 = null,
};

/// Resolves the project's `assets` manifest entries into absolute
/// host-path/mount-path pairs for wasm packaging. Entries are project-root
/// relative; each mounts at its project-relative location under the MEMFS root
/// (`/`) so a running app's runtime-relative `fopen` keeps resolving. A project
/// with no manifest or no `assets` key yields an empty list.
pub fn prepareProjectAssets(allocator: std.mem.Allocator, source_path: []const u8) !AssetResolution {
    const project_manifest_path = try discoverProjectManifestPath(allocator, source_path) orelse return .{ .mounts = &.{} };
    const project_root = std.fs.path.dirname(project_manifest_path) orelse ".";
    const project_manifest = try loadProjectManifestFromRoot(allocator, project_root);
    if (project_manifest.assets.len == 0) return .{ .mounts = &.{} };

    const project_root_abs = try paths.absolutize(allocator, project_root);

    var mounts = std.array_list.Managed(native.AssetMount).init(allocator);
    for (project_manifest.assets) |entry| {
        const rel = normalizeAssetRelative(entry);
        if (rel.len == 0) continue;
        const host_path = try std.fs.path.join(allocator, &.{ project_root_abs, rel });
        if (!pathExists(host_path)) return .{ .mounts = try mounts.toOwnedSlice(), .missing = entry };
        const mount_path = try std.fmt.allocPrint(allocator, "/{s}", .{rel});
        try mounts.append(.{ .host_path = host_path, .mount_path = mount_path });
    }
    return .{ .mounts = try mounts.toOwnedSlice() };
}

fn normalizeAssetRelative(entry: []const u8) []const u8 {
    var rel = entry;
    while (std.mem.startsWith(u8, rel, "./")) rel = rel[2..];
    return std.mem.trim(u8, rel, "/");
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

fn loadProjectManifestFromRoot(allocator: std.mem.Allocator, project_root: []const u8) !manifest.ProjectManifest {
    const project_manifest_path = try paths.findManifestInDirectory(allocator, project_root) orelse return error.ProjectManifestNotFound;
    const manifest_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, project_manifest_path, allocator, .limited(1024 * 1024));
    return manifest.parseProjectManifest(allocator, manifest_text);
}

fn resolvedTargetSelector(allocator: std.mem.Allocator, explicit_selector: ?native.TargetSelector) !native.TargetSelector {
    if (explicit_selector) |selector| return selector;
    return artifact.hostTargetSelector(allocator);
}

fn absolutizeFromManifest(allocator: std.mem.Allocator, manifest_path: []const u8, value: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);
    const base_dir = std.fs.path.dirname(manifest_path) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ base_dir, value });
    if (std.fs.path.isAbsolute(joined)) return joined;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, joined });
}

fn discoverProjectManifestPath(allocator: std.mem.Allocator, source_path: []const u8) !?[]const u8 {
    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    var cursor = try paths.absolutize(allocator, source_dir);
    errdefer allocator.free(cursor);

    while (true) {
        if (try paths.findManifestInDirectory(allocator, cursor)) |manifest_path| {
            allocator.free(cursor);
            return manifest_path;
        }

        const parent = std.fs.path.dirname(cursor) orelse break;
        if (std.mem.eql(u8, parent, cursor)) break;
        const copy = try allocator.dupe(u8, parent);
        allocator.free(cursor);
        cursor = copy;
    }

    allocator.free(cursor);
    return null;
}
