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
            const lib_path = try std.fs.path.join(allocator, &.{ project_root, rel });
            const lib_text = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, lib_path, allocator, .limited(1024 * 1024)) catch {
                try stderr.print("warning: could not read native library manifest {s}; skipping\n", .{lib_path});
                continue;
            };
            const parsed = manifest.parseNativeLibManifest(allocator, lib_text) catch {
                try stderr.print("warning: could not parse native library manifest {s}; skipping\n", .{lib_path});
                continue;
            };
            const legacy_base = std.fs.path.dirname(rel) orelse ".";
            try libs.append(try rebaseNativeLibrary(allocator, legacy_base, parsed.library));
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
    if (value.len == 0 or std.fs.path.isAbsolute(value) or std.mem.startsWith(u8, value, "${")) return allocator.dupe(u8, value);
    if (std.mem.eql(u8, base, ".") or base.len == 0) return allocator.dupe(u8, value);
    return std.fs.path.join(allocator, &.{ base, value });
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
        try std.fs.path.join(allocator, &.{ "NativeLibs", "include", "demo.h" }),
        rebased.headers.entrypoint.?,
    );
    try std.testing.expectEqualStrings(
        try std.fs.path.join(allocator, &.{ "NativeLibs", "include" }),
        rebased.headers.include_dirs[0],
    );
    try std.testing.expectEqualStrings(
        try std.fs.path.join(allocator, &.{ "NativeLibs", "src", "demo.c" }),
        rebased.build.sources[0],
    );
    try std.testing.expectEqualStrings(
        try std.fs.path.join(allocator, &.{ "NativeLibs", "include", "demo.h" }),
        rebased.autobinding.?.headers[0],
    );
    try std.testing.expectEqualStrings(
        try std.fs.path.join(allocator, &.{ "NativeLibs", "target", "include" }),
        rebased.targets[0].link.include_dirs[0],
    );
    try std.testing.expectEqualStrings("X11", rebased.targets[0].link.system_libs[0]);
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
