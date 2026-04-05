const std = @import("std");
const builtin = @import("builtin");
const native = @import("kira_native_lib_definition");
const syntax = @import("kira_syntax_model");
const resolver = @import("native_lib_resolver.zig");
const autobind = @import("ffi_autobind.zig");

pub fn prepareNativeLibraries(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    imports: []const syntax.ast.ImportDecl,
) ![]const native.ResolvedNativeLibrary {
    const selector = try hostTargetSelector(allocator);
    const manifest_paths = try discoverManifestFiles(allocator, source_path);
    const imported_modules = try importModuleNames(allocator, imports);

    var libraries = std.array_list.Managed(native.ResolvedNativeLibrary).init(allocator);
    for (manifest_paths) |manifest_path| {
        if (!manifestPathMatchesImports(allocator, manifest_path, imported_modules)) continue;
        var library = try resolver.resolveNativeManifestFile(allocator, manifest_path, selector);
        try ensureNativeArtifact(allocator, &library);
        try autobind.ensureGeneratedBindings(allocator, library);
        try libraries.append(library);
    }
    return libraries.toOwnedSlice();
}

fn discoverManifestFiles(allocator: std.mem.Allocator, source_path: []const u8) ![]const []const u8 {
    var manifests = std.array_list.Managed([]const u8).init(allocator);
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    var cursor = try absolutize(allocator, source_dir);
    defer allocator.free(cursor);

    while (true) {
        const native_dir = try std.fs.path.join(allocator, &.{ cursor, "native_libs" });
        defer allocator.free(native_dir);
        try collectTomls(allocator, native_dir, &seen, &manifests);

        const parent = std.fs.path.dirname(cursor) orelse break;
        if (std.mem.eql(u8, parent, cursor)) break;
        cursor = try allocator.dupe(u8, parent);
    }

    return manifests.toOwnedSlice();
}

fn importModuleNames(allocator: std.mem.Allocator, imports: []const syntax.ast.ImportDecl) ![]const []const u8 {
    var modules = std.array_list.Managed([]const u8).init(allocator);
    for (imports) |import_decl| {
        var builder = std.array_list.Managed(u8).init(allocator);
        for (import_decl.module_name.segments, 0..) |segment, index| {
            if (index != 0) try builder.append('.');
            try builder.appendSlice(segment.text);
        }
        try modules.append(try builder.toOwnedSlice());
    }
    return modules.toOwnedSlice();
}

fn manifestMatchesImports(library: native.ResolvedNativeLibrary, imports: []const []const u8) bool {
    if (imports.len == 0) return false;
    const autobinding = library.autobinding orelse return false;
    for (imports) |import_name| {
        if (std.mem.eql(u8, import_name, autobinding.module_name)) return true;
    }
    return false;
}

fn manifestPathMatchesImports(allocator: std.mem.Allocator, manifest_path: []const u8, imports: []const []const u8) bool {
    if (imports.len == 0) return false;
    const text = std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024) catch return false;
    defer allocator.free(text);

    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = line[1 .. line.len - 1];
            continue;
        }
        if (!std.mem.eql(u8, section, "autobinding")) continue;
        if (!std.mem.startsWith(u8, line, "module")) continue;
        const equal_index = std.mem.indexOfScalar(u8, line, '=') orelse return false;
        const value = std.mem.trim(u8, line[equal_index + 1 ..], " \t\"");
        for (imports) |import_name| {
            if (std.mem.eql(u8, import_name, value)) return true;
        }
        return false;
    }
    return false;
}

fn collectTomls(
    allocator: std.mem.Allocator,
    native_dir: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    manifests: *std.array_list.Managed([]const u8),
) !void {
    var dir = std.fs.openDirAbsolute(native_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        if (std.mem.endsWith(u8, entry.name, ".bind.toml")) continue;
        const manifest_path = try std.fs.path.join(allocator, &.{ native_dir, entry.name });
        if (seen.contains(manifest_path)) continue;
        try seen.put(allocator, manifest_path, {});
        try manifests.append(manifest_path);
    }
}

fn ensureNativeArtifact(allocator: std.mem.Allocator, library: *native.ResolvedNativeLibrary) !void {
    if (library.build.sources.len == 0) return;
    const maybe_dir = std.fs.path.dirname(library.artifact_path) orelse ".";
    try makePath(maybe_dir);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(&.{ "zig", "build-lib", "-static", try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{library.artifact_path}) });
    for (library.headers.include_dirs) |include_dir| {
        try argv.append(try std.fmt.allocPrint(allocator, "-I{s}", .{include_dir}));
    }
    for (library.build.include_dirs) |include_dir| {
        try argv.append(try std.fmt.allocPrint(allocator, "-I{s}", .{include_dir}));
    }
    for (library.headers.defines) |define| {
        try argv.append(try std.fmt.allocPrint(allocator, "-D{s}", .{define}));
    }
    for (library.build.defines) |define| {
        try argv.append(try std.fmt.allocPrint(allocator, "-D{s}", .{define}));
    }
    try argv.appendSlice(library.build.sources);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) return error.NativeLibraryBuildFailed;
}

fn hostTargetSelector(allocator: std.mem.Allocator) !native.TargetSelector {
    return native.TargetSelector.parse(allocator, switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "x86_64-linux-gnu",
            else => return error.UnsupportedTarget,
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "aarch64-macos-none",
            else => return error.UnsupportedTarget,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => if (builtin.abi == .gnu) "x86_64-windows-gnu" else "x86_64-windows-msvc",
            else => return error.UnsupportedTarget,
        },
        else => return error.UnsupportedTarget,
    });
}

fn absolutize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn makePath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        try std.fs.cwd().makePath(path);
        return;
    }
    var root = try std.fs.openDirAbsolute("/", .{});
    defer root.close();
    try root.makePath(path[1..]);
}
