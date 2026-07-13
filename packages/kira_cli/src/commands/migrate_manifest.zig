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
            try libs.append(parsed.library);
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
