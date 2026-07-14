const std = @import("std");
const manifest = @import("kira_manifest");

/// `kira migrate-manifest <path>` — read a legacy `kira.toml` and write an
/// equivalent `package.kira` declaration manifest beside it. The `kira.toml` is
/// left in place; deleting it is the caller's choice (package.kira takes
/// precedence when both exist).
///
/// `<path>` is a package directory or a manifest file. Native libraries declared
/// via `native_libraries = ["NativeLibs/*.toml"]` are inlined as
/// `NativeLibrary { ... }` entries; their per-target `static_lib` paths and the
/// autobind `output` field are dropped (build-from-source + the always-on
/// `app/bindings/<module>.kira` autobind law replace them).
pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len != 1) {
        try stderr.print("usage: kira migrate-manifest <path>\n", .{});
        return error.InvalidArguments;
    }

    const input = args[0];
    const manifest_path = try resolveTomlPath(allocator, input) orelse {
        try stderr.print("error: no kira.toml/project.toml found at {s}\n", .{input});
        return error.CommandFailed;
    };
    const project_root = std.fs.path.dirname(manifest_path) orelse ".";

    const text = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, manifest_path, allocator, .limited(1024 * 1024)) catch {
        try stderr.print("error: could not read {s}\n", .{manifest_path});
        return error.CommandFailed;
    };

    var project = manifest.parseProjectManifest(allocator, text) catch |err| {
        try stderr.print("error: could not parse {s}: {s}\n", .{ manifest_path, @errorName(err) });
        return error.CommandFailed;
    };

    // Inline every referenced NativeLibs/*.toml.
    if (project.native_libraries.len > 0) {
        var libs = std.array_list.Managed(@import("kira_native_lib_definition").NativeLibrarySpec).init(allocator);
        for (project.native_libraries) |rel| {
            const expanded = expandNativeLibraryPaths(allocator, project_root, rel) catch {
                try stderr.print("error: native library pattern {s} could not be expanded\n", .{rel});
                return error.CommandFailed;
            };
            if (expanded.len == 0) {
                try stderr.print("error: native library pattern {s} matched no manifests\n", .{rel});
                return error.CommandFailed;
            }
            for (expanded) |expanded_rel| {
                const lib_path = try std.fs.path.join(allocator, &.{ project_root, expanded_rel });
                const lib_text = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, lib_path, allocator, .limited(1024 * 1024)) catch {
                    try stderr.print("error: could not read native library manifest {s}\n", .{lib_path});
                    return error.CommandFailed;
                };
                const parsed = manifest.parseNativeLibManifest(allocator, lib_text) catch {
                    try stderr.print("error: could not parse native library manifest {s}\n", .{lib_path});
                    return error.CommandFailed;
                };
                const legacy_base = std.fs.path.dirname(expanded_rel) orelse ".";
                try libs.append(try rebaseNativeLibrary(allocator, legacy_base, parsed.library));
            }
        }
        project.inline_native_libraries = try libs.toOwnedSlice();
        project.native_libraries = &.{};
    }

    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try manifest.writeProjectManifestAsDeclaration(&rendered.writer, project);

    const output_path = try std.fs.path.join(allocator, &.{ project_root, "package.kira" });
    try writeFileAt(output_path, rendered.written());

    try stdout.print("wrote {s} (kira.toml left in place; package.kira takes precedence)\n", .{output_path});
}

fn expandNativeLibraryPaths(allocator: std.mem.Allocator, project_root: []const u8, pattern: []const u8) ![]const []const u8 {
    if (std.mem.indexOfAny(u8, pattern, "*?") == null) {
        const one = try allocator.alloc([]const u8, 1);
        one[0] = try allocator.dupe(u8, pattern);
        return one;
    }

    const directory = std.fs.path.dirname(pattern) orelse ".";
    if (std.mem.indexOfAny(u8, directory, "*?") != null) return error.UnsupportedGlobDirectory;
    const file_pattern = std.fs.path.basename(pattern);
    const directory_path = try std.fs.path.join(allocator, &.{ project_root, directory });
    var dir = if (std.fs.path.isAbsolute(directory_path))
        try std.Io.Dir.openDirAbsolute(std.Options.debug_io, directory_path, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(std.Options.debug_io, directory_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var paths = std.array_list.Managed([]const u8).init(allocator);
    var iterator = dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file or !wildcardMatches(file_pattern, entry.name)) continue;
        const relative = if (std.mem.eql(u8, directory, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, directory, "/\\"), entry.name });
        try paths.append(relative);
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    return paths.toOwnedSlice();
}

fn wildcardMatches(pattern: []const u8, value: []const u8) bool {
    var pattern_index: usize = 0;
    var value_index: usize = 0;
    var star_index: ?usize = null;
    var star_value_index: usize = 0;
    while (value_index < value.len) {
        if (pattern_index < pattern.len and (pattern[pattern_index] == '?' or pattern[pattern_index] == value[value_index])) {
            pattern_index += 1;
            value_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_value_index = value_index;
        } else if (star_index) |star| {
            pattern_index = star + 1;
            star_value_index += 1;
            value_index = star_value_index;
        } else {
            return false;
        }
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

/// Legacy NativeLib paths are relative to the referenced TOML file. Inline
/// package.kira libraries resolve paths from the project root, so migration
/// must carry the TOML directory into every path-bearing field.
fn rebaseNativeLibrary(
    allocator: std.mem.Allocator,
    base: []const u8,
    library: @import("kira_native_lib_definition").NativeLibrarySpec,
) !@import("kira_native_lib_definition").NativeLibrarySpec {
    var rebased = library;
    rebased.headers.entrypoint = if (library.headers.entrypoint) |value| try rebasePath(allocator, base, value) else null;
    rebased.headers.include_dirs = try rebasePaths(allocator, base, library.headers.include_dirs);
    rebased.build.sources = try rebasePaths(allocator, base, library.build.sources);
    rebased.build.include_dirs = try rebasePaths(allocator, base, library.build.include_dirs);
    var targets = std.array_list.Managed(@import("kira_native_lib_definition").TargetSpec).init(allocator);
    for (library.targets) |target| {
        var rebased_target = target;
        rebased_target.link.include_dirs = try rebasePaths(allocator, base, target.link.include_dirs);
        rebased_target.static_lib = if (target.static_lib) |value| try rebasePath(allocator, base, value) else null;
        rebased_target.dynamic_lib = if (target.dynamic_lib) |value| try rebasePath(allocator, base, value) else null;
        try targets.append(rebased_target);
    }
    rebased.targets = try targets.toOwnedSlice();
    if (library.autobinding) |autobinding| {
        var rebased_autobinding = autobinding;
        rebased_autobinding.headers = try rebasePaths(allocator, base, autobinding.headers);
        rebased.autobinding = rebased_autobinding;
    }
    return rebased;
}

fn rebasePaths(allocator: std.mem.Allocator, base: []const u8, values: []const []const u8) ![]const []const u8 {
    var paths = std.array_list.Managed([]const u8).init(allocator);
    for (values) |value| try paths.append(try rebasePath(allocator, base, value));
    return paths.toOwnedSlice();
}

fn rebasePath(allocator: std.mem.Allocator, base: []const u8, value: []const u8) ![]const u8 {
    if (value.len == 0 or std.mem.startsWith(u8, value, "${")) return allocator.dupe(u8, value);
    if (std.fs.path.isAbsolute(value) or std.mem.eql(u8, base, ".") or base.len == 0)
        return normalizeManifestPath(allocator, value);
    const joined = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ std.mem.trimEnd(u8, base, "/\\"), std.mem.trimStart(u8, value, "/\\") },
    );
    for (joined) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
    return joined;
}

fn normalizeManifestPath(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const normalized = try allocator.dupe(u8, value);
    for (normalized) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
    return normalized;
}

test "migration rebases native library paths from TOML directory to project root" {
    const native = @import("kira_native_lib_definition");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const library = native.NativeLibrarySpec{
        .name = "demo",
        .link_mode = .static,
        .abi = .c,
        .headers = .{ .entrypoint = "include/demo.h", .include_dirs = &.{"include"} },
        .autobinding = .{ .module_name = "demo", .output_path = "generated/demo.kira", .headers = &.{"include/demo.h"} },
        .build = .{ .sources = &.{"src/demo.c"}, .include_dirs = &.{"include"} },
        .targets = &.{.{
            .selector = .{ .architecture = "x86_64", .operating_system = "linux", .abi = "gnu" },
            .link = .{ .include_dirs = &.{"target/include"}, .system_libs = &.{"X11"} },
        }},
    };
    const rebased = try rebaseNativeLibrary(allocator, "NativeLibs", library);
    try std.testing.expectEqualStrings(
        "NativeLibs/include/demo.h",
        rebased.headers.entrypoint.?,
    );
    try std.testing.expectEqualStrings(
        "NativeLibs/include",
        rebased.headers.include_dirs[0],
    );
    try std.testing.expectEqualStrings(
        "NativeLibs/src/demo.c",
        rebased.build.sources[0],
    );
    try std.testing.expectEqualStrings(
        "NativeLibs/include/demo.h",
        rebased.autobinding.?.headers[0],
    );
    try std.testing.expectEqualStrings(
        "NativeLibs/target/include",
        rebased.targets[0].link.include_dirs[0],
    );
    try std.testing.expectEqualStrings("X11", rebased.targets[0].link.system_libs[0]);
}

test "migration expands native library globs deterministically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "NativeLibs", .default_dir);
    var native_dir = try tmp.dir.openDir(std.testing.io, "NativeLibs", .{});
    defer native_dir.close(std.testing.io);
    try native_dir.writeFile(std.testing.io, .{ .sub_path = "z.toml", .data = "" });
    try native_dir.writeFile(std.testing.io, .{ .sub_path = "a.toml", .data = "" });
    try native_dir.writeFile(std.testing.io, .{ .sub_path = "ignore.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const expanded = try expandNativeLibraryPaths(allocator, root, "NativeLibs/*.toml");
    try std.testing.expectEqual(@as(usize, 2), expanded.len);
    try std.testing.expectEqualStrings("NativeLibs/a.toml", expanded[0]);
    try std.testing.expectEqualStrings("NativeLibs/z.toml", expanded[1]);
    try std.testing.expect(wildcardMatches("*.toml", "sokol.toml"));
    try std.testing.expect(!wildcardMatches("*.toml", "sokol.h"));
}

fn resolveTomlPath(allocator: std.mem.Allocator, input: []const u8) !?[]const u8 {
    const base = std.fs.path.basename(input);
    if (std.mem.eql(u8, base, "kira.toml") or std.mem.eql(u8, base, "project.toml") or std.mem.eql(u8, base, "Kira.toml")) {
        return if (fileExists(input)) try allocator.dupe(u8, input) else null;
    }
    // Treat as a directory: search for a legacy manifest.
    for ([_][]const u8{ "kira.toml", "project.toml", "Kira.toml" }) |name| {
        const candidate = try std.fs.path.join(allocator, &.{ input, name });
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    var file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}

fn writeFileAt(path: []const u8, data: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        defer file.close(std.Options.debug_io);
        try file.writeStreamingAll(std.Options.debug_io, data);
    } else {
        try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = path, .data = data });
    }
}
