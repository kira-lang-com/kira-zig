const std = @import("std");
const builtin = @import("builtin");
const native = @import("kira_native_lib_definition");
const llvm_backend = @import("kira_llvm_backend");

pub fn compileStaticLibrary(allocator: std.mem.Allocator, library: *native.ResolvedNativeLibrary) !void {
    const is_emscripten = llvm_backend.emscripten.isSelector(library.target);
    const compiler_path = try resolveCompilerDriver(allocator, library.target, is_emscripten);
    defer allocator.free(compiler_path);
    const archiver_path = try resolveArchiver(allocator, is_emscripten);
    defer allocator.free(archiver_path);

    var object_paths = std.array_list.Managed([]const u8).init(allocator);
    defer for (object_paths.items) |path| std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    const build_suffix = randomBuildSuffix();
    const staged_artifact_path = try stagedArtifactPath(allocator, library.artifact_path, build_suffix);
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, staged_artifact_path) catch {};

    try compileSourcesToObjects(allocator, compiler_path, is_emscripten, library.*, build_suffix, &object_paths);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(&.{ archiver_path, "rcs", staged_artifact_path });
    try argv.appendSlice(object_paths.items);
    try runCommand(allocator, argv.items);
    try publishStagedArtifact(staged_artifact_path, library.artifact_path);
}

/// Compiles the library sources and links them into a shared library that the
/// VM can load for direct LibFFI dispatch.
pub fn compileSharedLibrary(allocator: std.mem.Allocator, library: *native.ResolvedNativeLibrary) !void {
    const is_emscripten = llvm_backend.emscripten.isSelector(library.target);
    const compiler_path = try resolveCompilerDriver(allocator, library.target, is_emscripten);
    defer allocator.free(compiler_path);

    var object_paths = std.array_list.Managed([]const u8).init(allocator);
    defer for (object_paths.items) |path| std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    const build_suffix = randomBuildSuffix();
    const staged_artifact_path = try stagedArtifactPath(allocator, library.artifact_path, build_suffix);
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, staged_artifact_path) catch {};

    try compileSourcesToObjects(allocator, compiler_path, is_emscripten, library.*, build_suffix, &object_paths);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(compiler_path);
    if (!is_emscripten) try llvm_backend.clangDriver.appendClangDriverArgs(allocator, &argv, library.target);
    try argv.append("-shared");
    try argv.appendSlice(&.{ "-o", staged_artifact_path });
    try argv.appendSlice(object_paths.items);
    if (isAppleOperatingSystem(library.target.operating_system)) {
        for (library.headers.frameworks) |framework| try argv.appendSlice(&.{ "-framework", framework });
        for (library.link.frameworks) |framework| try argv.appendSlice(&.{ "-framework", framework });
    }
    for (library.headers.system_libs) |system_lib| try argv.append(try std.fmt.allocPrint(allocator, "-l{s}", .{system_lib}));
    for (library.link.system_libs) |system_lib| try argv.append(try std.fmt.allocPrint(allocator, "-l{s}", .{system_lib}));
    for (library.link.linker_flags) |flag| try argv.append(flag);
    try runCommand(allocator, argv.items);
    try publishStagedArtifact(staged_artifact_path, library.artifact_path);
}

fn resolveCompilerDriver(allocator: std.mem.Allocator, selector: native.TargetSelector, is_emscripten: bool) ![]const u8 {
    if (is_emscripten) return llvm_backend.emscripten.emccPath(allocator);
    if (try llvm_backend.clangDriver.appleClangPathForSelector(allocator, selector)) |path| return path;
    const llvm_toolchain = try llvm_backend.LlvmToolchain.discover(allocator);
    return llvm_toolchain.clangPath(allocator);
}

fn resolveArchiver(allocator: std.mem.Allocator, is_emscripten: bool) ![]const u8 {
    if (is_emscripten) return llvm_backend.emscripten.emarPath(allocator);
    const llvm_toolchain = try llvm_backend.LlvmToolchain.discover(allocator);
    return llvm_toolchain.llvmArPath(allocator);
}

fn randomBuildSuffix() u64 {
    var bytes: [8]u8 = undefined;
    std.Options.debug_io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

fn compileSourcesToObjects(
    allocator: std.mem.Allocator,
    compiler_path: []const u8,
    is_emscripten: bool,
    library: native.ResolvedNativeLibrary,
    build_suffix: u64,
    object_paths: *std.array_list.Managed([]const u8),
) !void {
    for (library.build.sources, 0..) |source_path, index| {
        const object_path = try sourceObjectPath(allocator, library.artifact_path, index, build_suffix);
        try object_paths.append(object_path);

        var argv = std.array_list.Managed([]const u8).init(allocator);
        try appendCompileCommand(&argv, compiler_path, is_emscripten, library, source_path, object_path);
        for (library.headers.include_dirs) |include_dir| try argv.append(try std.fmt.allocPrint(allocator, "-I{s}", .{include_dir}));
        for (library.build.include_dirs) |include_dir| try argv.append(try std.fmt.allocPrint(allocator, "-I{s}", .{include_dir}));
        for (library.link.include_dirs) |include_dir| try argv.append(try std.fmt.allocPrint(allocator, "-I{s}", .{include_dir}));
        for (library.headers.defines) |define| try argv.append(try std.fmt.allocPrint(allocator, "-D{s}", .{define}));
        for (library.build.defines) |define| try argv.append(try std.fmt.allocPrint(allocator, "-D{s}", .{define}));
        for (library.link.defines) |define| try argv.append(try std.fmt.allocPrint(allocator, "-D{s}", .{define}));
        for (library.compiler_flags) |flag| try argv.append(flag);
        try runCommand(allocator, argv.items);
    }
}

fn appendCompileCommand(
    argv: *std.array_list.Managed([]const u8),
    compiler_path: []const u8,
    is_emscripten: bool,
    library: native.ResolvedNativeLibrary,
    source_path: []const u8,
    object_path: []const u8,
) !void {
    try argv.appendSlice(&.{ compiler_path, "-c", "-O3" });
    if (!is_emscripten) {
        try llvm_backend.clangDriver.appendClangDriverArgs(argv.allocator, argv, library.target);
        if (shouldCompileAsObjectiveC(library.target, library, source_path)) try argv.appendSlice(&.{ "-x", "objective-c" });
    }
    if (isCxxSource(source_path)) try argv.append("-std=c++17");
    try argv.appendSlice(&.{ source_path, "-o", object_path });
}

fn isCxxSource(source_path: []const u8) bool {
    const extension = std.fs.path.extension(source_path);
    return std.mem.eql(u8, extension, ".cc") or
        std.mem.eql(u8, extension, ".cpp") or
        std.mem.eql(u8, extension, ".cxx") or
        std.mem.eql(u8, extension, ".mm");
}

pub fn shouldCompileAsObjectiveC(selector: native.TargetSelector, library: native.ResolvedNativeLibrary, source_path: []const u8) bool {
    if (!isAppleOperatingSystem(selector.operating_system)) return false;
    if (library.link.frameworks.len == 0 and library.headers.frameworks.len == 0) return false;
    const extension = std.fs.path.extension(source_path);
    if (std.mem.eql(u8, extension, ".m") or std.mem.eql(u8, extension, ".mm")) return false;
    return std.mem.eql(u8, extension, ".c");
}

fn isAppleOperatingSystem(operating_system: []const u8) bool {
    return std.mem.eql(u8, operating_system, "macos") or
        std.mem.eql(u8, operating_system, "ios") or
        std.mem.eql(u8, operating_system, "tvos") or
        std.mem.eql(u8, operating_system, "xros");
}

fn sourceObjectPath(allocator: std.mem.Allocator, artifact_path: []const u8, index: usize, build_suffix: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.src-{x}-{d}.o", .{ artifact_path, build_suffix, index });
}

fn stagedArtifactPath(allocator: std.mem.Allocator, artifact_path: []const u8, build_suffix: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.stage-{x}", .{ artifact_path, build_suffix });
}

fn publishStagedArtifact(staged_path: []const u8, artifact_path: []const u8) !void {
    if (std.fs.path.isAbsolute(staged_path) and std.fs.path.isAbsolute(artifact_path)) {
        try std.Io.Dir.renameAbsolute(staged_path, artifact_path, std.Options.debug_io);
        return;
    }
    try std.Io.Dir.cwd().rename(staged_path, std.Io.Dir.cwd(), artifact_path, std.Options.debug_io);
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const llvm_toolchain = try llvm_backend.LlvmToolchain.discover(allocator);
    var environ_map = try llvm_toolchain.processEnvironMap(allocator);
    defer environ_map.deinit();
    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(allocator, io_impl.io(), .{
        .argv = argv,
        .expand_arg0 = .expand,
        .environ_map = &environ_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) return;
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    return error.NativeLibraryBuildFailed;
}

fn inheritedProcessEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        .wasi, .emscripten, .freestanding, .other => .empty,
        else => .{ .block = .{ .slice = currentPosixEnvironBlock() } },
    };
}

fn currentPosixEnvironBlock() [:null]const ?[*:0]const u8 {
    if (!builtin.link_libc) return &.{};
    const environ = std.c.environ;
    var len: usize = 0;
    while (environ[len] != null) : (len += 1) {}
    return environ[0..len :null];
}
