const std = @import("std");
const native = @import("kira_native_lib_definition");
const build_options = @import("kira_llvm_build_options");

pub fn buildRuntimeHelpersObject(allocator: std.mem.Allocator, object_path: []const u8) ![]const u8 {
    const helper_object = try helperObjectPath(allocator, object_path);
    const helper_source = try std.fs.path.join(allocator, &.{ build_options.repo_root, "packages", "kira_native_bridge", "src", "runtime_helpers.c" });
    try ensureParentDir(helper_object);
    try runCommand(allocator, &.{
        build_options.zig_exe,
        "cc",
        "-c",
        helper_source,
        "-o",
        helper_object,
    });
    return helper_object;
}

pub fn linkExecutable(
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    object_paths: []const []const u8,
    native_libraries: []const native.ResolvedNativeLibrary,
) !void {
    try ensureParentDir(executable_path);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(&.{ build_options.zig_exe, "cc", "-o", executable_path });
    for (object_paths) |path| try argv.append(path);

    for (native_libraries) |library| {
        try argv.append(library.artifact_path);
        for (library.link.system_libs) |system_lib| {
            try argv.append(try std.fmt.allocPrint(allocator, "-l{s}", .{system_lib}));
        }
        for (library.link.frameworks) |framework| {
            try argv.appendSlice(&.{ "-framework", framework });
        }
    }

    try runCommand(allocator, argv.items);
}

pub fn linkSharedLibrary(
    allocator: std.mem.Allocator,
    library_path: []const u8,
    object_paths: []const []const u8,
    native_libraries: []const native.ResolvedNativeLibrary,
) !void {
    try ensureParentDir(library_path);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(&.{ build_options.zig_exe, "cc", "-shared", "-o", library_path });
    for (object_paths) |path| try argv.append(path);

    for (native_libraries) |library| {
        try argv.append(library.artifact_path);
        for (library.link.system_libs) |system_lib| {
            try argv.append(try std.fmt.allocPrint(allocator, "-l{s}", .{system_lib}));
        }
        for (library.link.frameworks) |framework| {
            try argv.appendSlice(&.{ "-framework", framework });
        }
    }

    try runCommand(allocator, argv.items);
}

fn helperObjectPath(allocator: std.mem.Allocator, object_path: []const u8) ![]const u8 {
    const ext = std.fs.path.extension(object_path);
    if (ext.len == 0) return std.fmt.allocPrint(allocator, "{s}.bridge.o", .{object_path});
    const stem = object_path[0 .. object_path.len - ext.len];
    return std.fmt.allocPrint(allocator, "{s}.bridge{s}", .{ stem, ext });
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) return;
    return error.ExternalCommandFailed;
}

fn ensureParentDir(path: []const u8) !void {
    const maybe_dir = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(maybe_dir);
}
