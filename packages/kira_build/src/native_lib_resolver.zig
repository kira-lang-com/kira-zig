const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("kira_manifest");
const native = @import("kira_native_lib_definition");

/// Resolve a native library declared inline in a `package.kira` manifest (a
/// `NativeLibrary { ... }` entry) into a `ResolvedNativeLibrary`, using the
/// project root as the base for every relative path.
///
/// Inline libraries carry no per-target `static_lib` paths and no `output`: the
/// artifact is compiled from `sources` into a project-local, target-scoped path,
/// and — the autobind law — bindings always write to
/// `<project_root>/app/bindings/<module>.kira`. `pseudo_manifest_path` is a
/// synthetic path (the project's `package.kira`) used only for diagnostics and
/// identity.
pub fn resolveInlineLibrary(
    allocator: std.mem.Allocator,
    spec: native.NativeLibrarySpec,
    target: native.TargetSelector,
    project_root: []const u8,
    pseudo_manifest_path: []const u8,
) !native.ResolvedNativeLibrary {
    var matched_target: ?native.TargetSpec = null;
    for (spec.targets) |candidate| {
        if (candidate.selector.eql(target)) {
            matched_target = candidate;
            break;
        }
    }
    // A target may declare its artifact explicitly: a path to a prebuilt
    // library, or the empty string meaning "no compiled shim — symbols
    // resolve in-process" (e.g. Foundation's kira_runtime). Only when no
    // artifact is declared does the inline build-cache path apply.
    const declared_artifact: ?[]const u8 = if (matched_target) |selected|
        (if (spec.link_mode == .static) selected.static_lib else selected.dynamic_lib)
    else
        null;
    const artifact_path = if (declared_artifact) |declared|
        (if (declared.len == 0)
            try allocator.dupe(u8, "")
        else
            try absolutizePath(allocator, try std.fs.path.join(allocator, &.{ project_root, "package.kira" }), declared))
    else
        try inlineArtifactPath(allocator, project_root, spec.name, spec.link_mode, target);
    var resolved = native.ResolvedNativeLibrary{
        .manifest_path = try allocator.dupe(u8, pseudo_manifest_path),
        .name = try allocator.dupe(u8, spec.name),
        .link_mode = spec.link_mode,
        .abi = spec.abi,
        .artifact_path = artifact_path,
        .target = target,
        .headers = spec.headers,
        .autobinding = spec.autobinding,
        .build = spec.build,
        .compiler_flags = if (matched_target) |selected| try cloneStrings(allocator, selected.compiler_flags) else &.{},
        .link = if (matched_target) |selected| try native.LinkExtras.clone(allocator, selected.link) else .{},
    };

    if (try firstUnresolvedEnvVar(allocator, resolved)) |missing| {
        resolved.unavailable = .{ .reason = .missing_environment_variable, .detail = missing };
        return resolved;
    }

    // Every relative path is resolved against the project root (there is no
    // sibling `.toml` file for an inline library).
    const base = try std.fs.path.join(allocator, &.{ project_root, "package.kira" });
    resolved.headers = try resolveHeaders(allocator, base, spec.headers);
    resolved.build = try resolveBuildRecipe(allocator, base, spec.build);
    resolved.link = try resolveLinkExtras(allocator, base, resolved.link);
    resolved.autobinding = if (spec.autobinding) |autobinding| blk: {
        // Autobind law: bindings always land at app/bindings/<module>.kira.
        const output_path = try std.fs.path.join(allocator, &.{ project_root, "app", "bindings", try std.fmt.allocPrint(allocator, "{s}.kira", .{autobinding.module_name}) });
        break :blk native.AutobindingSpec{
            .module_name = try allocator.dupe(u8, autobinding.module_name),
            .output_path = output_path,
            .headers = try absolutizePaths(allocator, base, autobinding.headers),
            .bindings = .{
                .mode = autobinding.bindings.mode,
                .profile = autobinding.bindings.profile,
                .functions = try cloneStrings(allocator, autobinding.bindings.functions),
                .structs = try cloneStrings(allocator, autobinding.bindings.structs),
                .callbacks = try cloneStrings(allocator, autobinding.bindings.callbacks),
            },
        };
    } else null;
    return resolved;
}

fn inlineArtifactPath(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    name: []const u8,
    link_mode: native.LinkMode,
    target: native.TargetSelector,
) ![]const u8 {
    const triple_dir = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ target.architecture, target.operating_system, target.abi });
    const is_windows = std.mem.eql(u8, target.operating_system, "windows");
    const file_name = if (link_mode == .dynamic)
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ if (is_windows) "" else "lib", name, if (is_windows) ".dll" else ".dylib" })
    else
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ if (is_windows) "" else "lib", name, if (is_windows) ".lib" else ".a" });
    const rel = try std.fs.path.join(allocator, &.{ ".kira-build", "native", triple_dir, file_name });
    return absolutizePath(allocator, try std.fs.path.join(allocator, &.{ project_root, "package.kira" }), rel);
}

pub fn resolveNativeManifestFile(allocator: std.mem.Allocator, path: []const u8, target: native.TargetSelector) !native.ResolvedNativeLibrary {
    const text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024 * 1024));
    const parsed = try manifest.parseNativeLibManifest(allocator, text);
    var resolved = try native.resolveLibrary(allocator, parsed.library, target);
    resolved.manifest_path = try absolutizePath(allocator, path, path);

    // A manifest path may reference an environment variable (e.g. an SDK root
    // like `${VULKAN_SDK}`). When that variable is unset we cannot resolve the
    // library on this machine; mark it unavailable so preparation skips it with
    // a warning instead of absolutizing a bogus `${VULKAN_SDK}/...` literal and
    // handing it to clang (which then fails opaquely).
    if (try firstUnresolvedEnvVar(allocator, resolved)) |missing| {
        resolved.unavailable = .{ .reason = .missing_environment_variable, .detail = missing };
        return resolved;
    }

    resolved.artifact_path = try absolutizePath(allocator, path, resolved.artifact_path);
    resolved.headers = try resolveHeaders(allocator, path, resolved.headers);
    resolved.autobinding = if (resolved.autobinding) |autobinding| try resolveAutobinding(allocator, path, autobinding) else null;
    resolved.build = try resolveBuildRecipe(allocator, path, resolved.build);
    resolved.link = try resolveLinkExtras(allocator, path, resolved.link);
    return resolved;
}

/// Returns the name of the first environment variable referenced by a manifest
/// path (via `${NAME}`) that is not set in the current process environment, or
/// null when every referenced variable resolves. The caller owns the returned
/// slice.
fn firstUnresolvedEnvVar(allocator: std.mem.Allocator, resolved: native.ResolvedNativeLibrary) !?[]const u8 {
    if (resolved.headers.entrypoint) |entrypoint| {
        if (try unresolvedEnvVarName(allocator, entrypoint)) |name| return name;
    }
    if (try firstUnresolvedEnvVarInList(allocator, resolved.headers.include_dirs)) |name| return name;
    if (try firstUnresolvedEnvVarInList(allocator, resolved.build.sources)) |name| return name;
    if (try firstUnresolvedEnvVarInList(allocator, resolved.build.include_dirs)) |name| return name;
    if (try firstUnresolvedEnvVarInList(allocator, resolved.link.include_dirs)) |name| return name;
    if (resolved.autobinding) |autobinding| {
        if (try firstUnresolvedEnvVarInList(allocator, autobinding.headers)) |name| return name;
    }
    if (try unresolvedEnvVarName(allocator, resolved.artifact_path)) |name| return name;
    return null;
}

fn firstUnresolvedEnvVarInList(allocator: std.mem.Allocator, values: []const []const u8) !?[]const u8 {
    for (values) |value| {
        if (try unresolvedEnvVarName(allocator, value)) |name| return name;
    }
    return null;
}

fn unresolvedEnvVarName(allocator: std.mem.Allocator, value: []const u8) !?[]const u8 {
    // Mirror `expandEnvPath`: only a leading `${NAME}` reference is treated as an
    // environment substitution.
    if (!std.mem.startsWith(u8, value, "${")) return null;
    const close = std.mem.indexOfScalar(u8, value, '}') orelse return null;
    const name = value[2..close];
    if (envVarOwned(allocator, name)) |resolved_value| {
        allocator.free(resolved_value);
        return null;
    } else |_| {
        return try allocator.dupe(u8, name);
    }
}

fn resolveHeaders(allocator: std.mem.Allocator, manifest_path: []const u8, headers: native.HeaderSpec) !native.HeaderSpec {
    return .{
        .entrypoint = if (headers.entrypoint) |value| try absolutizePath(allocator, manifest_path, value) else null,
        .include_dirs = try absolutizePaths(allocator, manifest_path, headers.include_dirs),
        .defines = try cloneStrings(allocator, headers.defines),
        .frameworks = try cloneStrings(allocator, headers.frameworks),
        .system_libs = try cloneStrings(allocator, headers.system_libs),
    };
}

fn resolveAutobinding(allocator: std.mem.Allocator, manifest_path: []const u8, autobinding: native.AutobindingSpec) !native.AutobindingSpec {
    return .{
        .module_name = try allocator.dupe(u8, autobinding.module_name),
        .output_path = try absolutizePath(allocator, manifest_path, autobinding.output_path),
        .headers = try absolutizePaths(allocator, manifest_path, autobinding.headers),
        .bindings = .{
            .mode = autobinding.bindings.mode,
            .profile = autobinding.bindings.profile,
            .functions = try cloneStrings(allocator, autobinding.bindings.functions),
            .structs = try cloneStrings(allocator, autobinding.bindings.structs),
            .callbacks = try cloneStrings(allocator, autobinding.bindings.callbacks),
        },
    };
}

fn resolveBuildRecipe(allocator: std.mem.Allocator, manifest_path: []const u8, build: native.BuildRecipe) !native.BuildRecipe {
    return .{
        .sources = try absolutizePaths(allocator, manifest_path, build.sources),
        .include_dirs = try absolutizePaths(allocator, manifest_path, build.include_dirs),
        .defines = try cloneStrings(allocator, build.defines),
    };
}

fn resolveLinkExtras(allocator: std.mem.Allocator, manifest_path: []const u8, extras: native.LinkExtras) !native.LinkExtras {
    return .{
        .include_dirs = try absolutizePaths(allocator, manifest_path, extras.include_dirs),
        .defines = try cloneStrings(allocator, extras.defines),
        .frameworks = try cloneStrings(allocator, extras.frameworks),
        .system_libs = try cloneStrings(allocator, extras.system_libs),
        .linker_flags = try cloneStrings(allocator, extras.linker_flags),
    };
}

fn absolutizePaths(allocator: std.mem.Allocator, manifest_path: []const u8, values: []const []const u8) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(allocator);
    for (values) |value| {
        try list.append(try absolutizePath(allocator, manifest_path, value));
    }
    return list.toOwnedSlice();
}

fn absolutizePath(allocator: std.mem.Allocator, manifest_path: []const u8, value: []const u8) ![]const u8 {
    if (value.len == 0) return allocator.dupe(u8, value);
    if (try expandEnvPath(allocator, value)) |expanded| {
        defer allocator.free(expanded);
        return std.fs.path.resolve(allocator, &.{expanded});
    }
    if (std.fs.path.isAbsolute(value)) return std.fs.path.resolve(allocator, &.{value});

    const base_dir = std.fs.path.dirname(manifest_path) orelse ".";
    return std.fs.path.resolve(allocator, &.{ base_dir, value });
}

fn expandEnvPath(allocator: std.mem.Allocator, value: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, value, "${")) return null;
    const close = std.mem.indexOfScalar(u8, value, '}') orelse return null;
    const name = value[2..close];
    const suffix = value[close + 1 ..];
    const root = envVarOwned(allocator, name) catch return null;
    defer allocator.free(root);
    if (suffix.len == 0) return @as(?[]const u8, try allocator.dupe(u8, root));
    const trimmed = std.mem.trim(u8, suffix, "/\\");
    return @as(?[]const u8, try std.fs.path.join(allocator, &.{ root, trimmed }));
}

fn envVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    // `Environ.createMap(.{ .block = .global }, ...)` only compiles on Windows; POSIX has no
    // `.global` environ block. Read through libc on POSIX, mirroring the repo's other
    // env-var helpers, and keep the Windows Kits fallback for the one synthetic name.
    if (builtin.os.tag == .windows or (builtin.os.tag == .wasi and !builtin.link_libc)) {
        var environ = try std.process.Environ.createMap(.{ .block = .global }, allocator);
        defer environ.deinit();
        if (environ.get(name)) |value| return allocator.dupe(u8, value);
    } else if (builtin.link_libc) {
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);
        if (std.c.getenv(name_z.ptr)) |value| return allocator.dupe(u8, std.mem.span(value));
    }
    if (std.mem.eql(u8, name, "WINDOWS_KITS_10_INCLUDE")) return discoverWindowsKitsInclude(allocator);
    return error.EnvironmentVariableNotFound;
}

fn discoverWindowsKitsInclude(allocator: std.mem.Allocator) ![]u8 {
    const root_path = "C:\\Program Files (x86)\\Windows Kits\\10\\Include";
    var root = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, root_path, .{ .iterate = true });
    defer root.close(std.Options.debug_io);

    var best: ?[]u8 = null;
    var iterator = root.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .directory) continue;
        if (best) |current| {
            if (std.mem.order(u8, entry.name, std.fs.path.basename(current)) != .gt) continue;
            allocator.free(current);
        }
        best = try std.fs.path.join(allocator, &.{ root_path, entry.name });
    }
    return best orelse error.EnvironmentVariableNotFound;
}

fn cloneStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(allocator);
    for (values) |value| {
        try list.append(try allocator.dupe(u8, value));
    }
    return list.toOwnedSlice();
}

// A variable name that no reasonable environment would define, so these tests
// exercise the unset-variable path deterministically.
const unset_env_probe = "KIRA_TEST_UNSET_ENV_XYZ";

test "unresolvedEnvVarName ignores plain paths and reports unset variables" {
    const allocator = std.testing.allocator;

    // Relative and absolute literal paths are not environment references.
    try std.testing.expect((try unresolvedEnvVarName(allocator, "Text/kira_text.h")) == null);
    try std.testing.expect((try unresolvedEnvVarName(allocator, "/usr/include/foo.h")) == null);

    const missing = try unresolvedEnvVarName(allocator, "${" ++ unset_env_probe ++ "}/Include/vulkan.h");
    try std.testing.expect(missing != null);
    defer allocator.free(missing.?);
    try std.testing.expectEqualStrings(unset_env_probe, missing.?);
}

test "resolveNativeManifestFile marks library unavailable when a required env var is unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "vulkan.toml",
        .data =
        \\[library]
        \\name = "vulkan"
        \\link_mode = "dynamic"
        \\abi = "c"
        \\
        \\[headers]
        \\entrypoint = "${KIRA_TEST_UNSET_ENV_XYZ}/Include/vulkan/vulkan.h"
        \\include_dirs = ["${KIRA_TEST_UNSET_ENV_XYZ}/Include"]
        \\
        \\[target.x86_64-linux-gnu]
        \\dynamic_lib = ""
        \\
        ,
    });

    const manifest_path = try tmp.dir.realPathFileAlloc(std.testing.io, "vulkan.toml", allocator);
    const selector = try native.TargetSelector.parse(allocator, "x86_64-linux-gnu");
    const resolved = try resolveNativeManifestFile(allocator, manifest_path, selector);

    try std.testing.expect(resolved.unavailable != null);
    try std.testing.expectEqual(
        native.Unavailable.Reason.missing_environment_variable,
        resolved.unavailable.?.reason,
    );
    try std.testing.expectEqualStrings(unset_env_probe, resolved.unavailable.?.detail);
}

test "resolveNativeManifestFile carries per-target compiler and linker flags through resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sokol.toml",
        .data =
        \\[library]
        \\name = "sokol"
        \\link_mode = "static"
        \\abi = "c"
        \\
        \\[build]
        \\sources = ["sokol_impl.c"]
        \\
        \\[target.wasm32-emscripten-unknown]
        \\static_lib = "libsokol.a"
        \\compiler_flags = ["--use-port=emdawnwebgpu"]
        \\linker_flags = ["--use-port=emdawnwebgpu", "-sERROR_ON_UNDEFINED_SYMBOLS=0"]
        \\
        ,
    });

    const manifest_path = try tmp.dir.realPathFileAlloc(std.testing.io, "sokol.toml", allocator);
    const selector = try native.TargetSelector.parse(allocator, "wasm32-emscripten-unknown");
    const resolved = try resolveNativeManifestFile(allocator, manifest_path, selector);

    try std.testing.expectEqual(@as(usize, 1), resolved.compiler_flags.len);
    try std.testing.expectEqualStrings("--use-port=emdawnwebgpu", resolved.compiler_flags[0]);
    try std.testing.expectEqual(@as(usize, 2), resolved.link.linker_flags.len);
    try std.testing.expectEqualStrings("--use-port=emdawnwebgpu", resolved.link.linker_flags[0]);
    try std.testing.expectEqualStrings("-sERROR_ON_UNDEFINED_SYMBOLS=0", resolved.link.linker_flags[1]);
}

test "resolveInlineLibrary applies matching target compiler and linker options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const manifest_path = try std.fs.path.join(allocator, &.{ project_root, "package.kira" });
    const selector = try native.TargetSelector.parse(allocator, "x86_64-linux-gnu");
    const spec = native.NativeLibrarySpec{
        .name = "demo",
        .link_mode = .static,
        .abi = .c,
        .build = .{ .sources = &.{"NativeLibs/demo.c"} },
        .targets = &.{.{
            .selector = .{ .architecture = "x86_64", .operating_system = "linux", .abi = "gnu" },
            .compiler_flags = &.{"-pthread"},
            .link = .{ .include_dirs = &.{"NativeLibs/include"}, .system_libs = &.{"X11"}, .linker_flags = &.{"-Wl,--as-needed"} },
        }},
    };

    const resolved = try resolveInlineLibrary(allocator, spec, selector, project_root, manifest_path);
    try std.testing.expectEqualStrings("-pthread", resolved.compiler_flags[0]);
    try std.testing.expectEqualStrings("X11", resolved.link.system_libs[0]);
    try std.testing.expectEqualStrings("-Wl,--as-needed", resolved.link.linker_flags[0]);
    try std.testing.expectEqualStrings(
        try std.fs.path.join(allocator, &.{ project_root, "NativeLibs", "include" }),
        resolved.link.include_dirs[0],
    );
    const expected_target_dir = try std.fs.path.join(allocator, &.{ ".kira-build", "native", "x86_64-linux-gnu" });
    try std.testing.expect(std.mem.indexOf(u8, resolved.artifact_path, expected_target_dir) != null);
}

test "resolveInlineLibrary keeps generic sources without a matching target override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const manifest_path = try std.fs.path.join(allocator, &.{ project_root, "package.kira" });
    const macos = try native.TargetSelector.parse(allocator, "aarch64-macos-none");
    const spec = native.NativeLibrarySpec{
        .name = "demo",
        .link_mode = .static,
        .abi = .c,
        .build = .{ .sources = &.{"NativeLibs/demo.c"} },
        .targets = &.{.{
            .selector = .{ .architecture = "x86_64", .operating_system = "linux", .abi = "gnu" },
            .compiler_flags = &.{"-pthread"},
            .link = .{ .system_libs = &.{"X11"} },
        }},
    };

    const resolved = try resolveInlineLibrary(allocator, spec, macos, project_root, manifest_path);
    try std.testing.expectEqual(@as(usize, 0), resolved.compiler_flags.len);
    try std.testing.expectEqual(@as(usize, 0), resolved.link.system_libs.len);
    try std.testing.expectEqualStrings(
        try std.fs.path.join(allocator, &.{ project_root, "NativeLibs", "demo.c" }),
        resolved.build.sources[0],
    );
}

test "inline native artifact paths distinguish target ABIs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const gnu = try native.TargetSelector.parse(allocator, "x86_64-linux-gnu");
    const musl = try native.TargetSelector.parse(allocator, "x86_64-linux-musl");
    const gnu_path = try inlineArtifactPath(allocator, "/project", "demo", .static, gnu);
    const musl_path = try inlineArtifactPath(allocator, "/project", "demo", .static, musl);
    try std.testing.expect(!std.mem.eql(u8, gnu_path, musl_path));
    try std.testing.expect(std.mem.indexOf(u8, gnu_path, "x86_64-linux-gnu") != null);
    try std.testing.expect(std.mem.indexOf(u8, musl_path, "x86_64-linux-musl") != null);
}
