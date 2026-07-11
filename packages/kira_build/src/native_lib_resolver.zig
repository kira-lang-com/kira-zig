const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("kira_manifest");
const native = @import("kira_native_lib_definition");

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
    if (try expandEnvPath(allocator, value)) |expanded| return expanded;
    if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);

    const base_dir = std.fs.path.dirname(manifest_path) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ base_dir, value });
    if (std.fs.path.isAbsolute(joined)) return joined;

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, joined });
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
