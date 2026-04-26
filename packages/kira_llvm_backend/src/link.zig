const std = @import("std");
const builtin = @import("builtin");
const native = @import("kira_native_lib_definition");
const build_options = @import("kira_llvm_build_options");
const backend_utils = @import("backend_utils.zig");
const toolchain = @import("toolchain.zig");

pub fn buildRuntimeHelpersObject(allocator: std.mem.Allocator, object_path: []const u8) ![]const u8 {
    const helper_object = try helperObjectPath(allocator, object_path);
    const helper_source = try std.fs.path.join(allocator, &.{ build_options.repo_root, "packages", "kira_native_bridge", "src", "runtime_helpers.c" });
    const llvm_toolchain = try toolchain.Toolchain.discover(allocator);
    const driver_path = try llvm_toolchain.compilerDriverPath(allocator);
    try ensureParentDir(helper_object);
    if (builtin.os.tag == .macos) {
        try runCommand(allocator, &.{ driver_path, "-c", helper_source, "-o", helper_object });
    } else {
        const target = try zigTargetTriple(allocator);
        try runCommand(allocator, &.{
            driver_path,
            "-target",
            target,
            "-c",
            helper_source,
            "-o",
            helper_object,
        });
    }
    return helper_object;
}

pub fn linkExecutable(
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    object_paths: []const []const u8,
    native_libraries: []const native.ResolvedNativeLibrary,
) !void {
    try ensureParentDir(executable_path);
    const llvm_toolchain = try toolchain.Toolchain.discover(allocator);
    const driver_path = try llvm_toolchain.compilerDriverPath(allocator);
    var argv = std.array_list.Managed([]const u8).init(allocator);
    if (builtin.os.tag == .macos) {
        try argv.appendSlice(&.{ driver_path, "-o", executable_path });
    } else {
        const target = try zigTargetTriple(allocator);
        try argv.appendSlice(&.{ driver_path, "-target", target, "-o", executable_path });
    }
    if (builtin.os.tag == .windows) {
        try argv.append("-Wl,/subsystem:console");
    }
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
    const llvm_toolchain = try toolchain.Toolchain.discover(allocator);
    const driver_path = try llvm_toolchain.compilerDriverPath(allocator);
    var argv = std.array_list.Managed([]const u8).init(allocator);
    if (builtin.os.tag == .macos) {
        try argv.appendSlice(&.{ driver_path, "-shared", "-o", library_path });
    } else {
        const target = try zigTargetTriple(allocator);
        try argv.appendSlice(&.{ driver_path, "-target", target, "-shared", "-o", library_path });
    }
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
    const process_environ = backend_utils.inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(allocator, io_impl.io(), .{
        .argv = argv,
        .expand_arg0 = .expand,
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return;
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    return error.ExternalCommandFailed;
}

fn ensureParentDir(path: []const u8) !void {
    const maybe_dir = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, maybe_dir);
}

fn zigTargetTriple(allocator: std.mem.Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => allocator.dupe(u8, if (builtin.abi == .gnu) "x86_64-windows-gnu" else "x86_64-windows-msvc"),
            else => error.UnsupportedTarget,
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => allocator.dupe(u8, "aarch64-macos-none"),
            else => error.UnsupportedTarget,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => allocator.dupe(u8, "x86_64-linux-gnu"),
            else => error.UnsupportedTarget,
        },
        else => error.UnsupportedTarget,
    };
}
