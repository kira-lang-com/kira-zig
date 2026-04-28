const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("kira_manifest");
const native = @import("kira_native_lib_definition");
const syntax = @import("kira_syntax_model");
const llvm_backend = @import("kira_llvm_backend");
const resolver = @import("native_lib_resolver.zig");
const autobind = @import("ffi_autobind.zig");

pub fn prepareNativeLibraries(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    imports: []const syntax.ast.ImportDecl,
) ![]const native.ResolvedNativeLibrary {
    const selector = try hostTargetSelector(allocator);
    const manifest_paths = try loadProjectNativeManifestPaths(allocator, source_path);
    _ = imports;

    var libraries = std.array_list.Managed(native.ResolvedNativeLibrary).init(allocator);
    for (manifest_paths) |manifest_path| {
        var library = try resolver.resolveNativeManifestFile(allocator, manifest_path, selector);
        try ensureNativeArtifact(allocator, &library);
        try autobind.ensureGeneratedBindings(allocator, library);
        try libraries.append(library);
    }
    return libraries.toOwnedSlice();
}

fn loadProjectNativeManifestPaths(allocator: std.mem.Allocator, source_path: []const u8) ![]const []const u8 {
    const project_manifest_path = try discoverProjectManifestPath(allocator, source_path) orelse return &.{};
    const manifest_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, project_manifest_path, allocator, .limited(1024 * 1024));
    const project_manifest = try manifest.parseProjectManifest(allocator, manifest_text);

    var manifests = std.array_list.Managed([]const u8).init(allocator);
    for (project_manifest.native_libraries) |value| {
        try manifests.append(try absolutizeFromManifest(allocator, project_manifest_path, value));
    }
    return manifests.toOwnedSlice();
}

fn ensureNativeArtifact(allocator: std.mem.Allocator, library: *native.ResolvedNativeLibrary) !void {
    if (library.build.sources.len == 0) return;
    const maybe_dir = std.fs.path.dirname(library.artifact_path) orelse ".";
    try makePath(maybe_dir);
    if (library.link_mode != .static) return error.UnsupportedNativeLibraryBuildMode;
    return compileStaticLibraryViaClang(allocator, library);
}

fn compileStaticLibraryViaClang(allocator: std.mem.Allocator, library: *native.ResolvedNativeLibrary) !void {
    const llvm_toolchain = try llvm_backend.LlvmToolchain.discover(allocator);
    const clang_path = try llvm_toolchain.clangPath(allocator);
    defer allocator.free(clang_path);
    const llvm_ar_path = try llvm_toolchain.llvmArPath(allocator);
    defer allocator.free(llvm_ar_path);
    const target_triple = try targetTriple(allocator, library.target);
    defer allocator.free(target_triple);

    var object_paths = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (object_paths.items) |path| {
            std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};
        }
    }

    for (library.build.sources, 0..) |source_path, index| {
        const object_path = try sourceObjectPath(allocator, library.artifact_path, index);
        try object_paths.append(object_path);

        var argv = std.array_list.Managed([]const u8).init(allocator);
        try appendClangCompileCommand(&argv, clang_path, target_triple, library.*, source_path, object_path);
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
        try runCommand(allocator, argv.items);
    }

    var argv = std.array_list.Managed([]const u8).init(allocator);
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, library.artifact_path) catch {};
    try argv.appendSlice(&.{ llvm_ar_path, "rcs", library.artifact_path });
    try argv.appendSlice(object_paths.items);
    try runCommand(allocator, argv.items);
}

fn appendClangCompileCommand(
    argv: *std.array_list.Managed([]const u8),
    clang_path: []const u8,
    target_triple: []const u8,
    library: native.ResolvedNativeLibrary,
    source_path: []const u8,
    object_path: []const u8,
) !void {
    try argv.appendSlice(&.{ clang_path, "-c", "-O3" });
    if (builtin.os.tag != .macos) {
        try argv.appendSlice(&.{ "-target", target_triple });
    }
    if (shouldCompileAsObjectiveC(builtin.os.tag, library, source_path)) {
        try argv.appendSlice(&.{ "-x", "objective-c" });
    }
    try argv.appendSlice(&.{ source_path, "-o", object_path });
}

fn shouldCompileAsObjectiveC(os_tag: std.Target.Os.Tag, library: native.ResolvedNativeLibrary, source_path: []const u8) bool {
    if (os_tag != .macos) return false;
    if (library.link.frameworks.len == 0 and library.headers.frameworks.len == 0) return false;

    const extension = std.fs.path.extension(source_path);
    if (std.mem.eql(u8, extension, ".m") or std.mem.eql(u8, extension, ".mm")) return false;
    return std.mem.eql(u8, extension, ".c");
}

fn sourceObjectPath(allocator: std.mem.Allocator, artifact_path: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.src-{d}.o", .{ artifact_path, index });
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(allocator, io_impl.io(), .{
        .argv = argv,
        .expand_arg0 = .expand,
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

fn targetTriple(allocator: std.mem.Allocator, selector: native.TargetSelector) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}",
        .{ selector.architecture, selector.operating_system, selector.abi },
    );
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
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
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
    var cursor = try absolutize(allocator, source_dir);
    errdefer allocator.free(cursor);

    while (true) {
        if (try findManifestInDirectory(allocator, cursor)) |manifest_path| {
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

fn findManifestInDirectory(allocator: std.mem.Allocator, directory: []const u8) !?[]const u8 {
    const names = [_][]const u8{ "kira.toml", "project.toml" };
    for (names) |name| {
        const candidate = try std.fs.path.join(allocator, &.{ directory, name });
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

fn makePath(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, path);
}

test "macOS framework-backed C source compiles as Objective-C" {
    const library: native.ResolvedNativeLibrary = .{
        .name = "sokol",
        .link_mode = .static,
        .abi = .c,
        .artifact_path = "/tmp/libsokol.a",
        .target = undefined,
        .headers = .{},
        .link = .{ .frameworks = &.{"AppKit"} },
    };

    try std.testing.expect(shouldCompileAsObjectiveC(.macos, library, "/tmp/sokol_impl.c"));
    try std.testing.expect(!shouldCompileAsObjectiveC(.macos, library, "/tmp/sokol_impl.m"));
    try std.testing.expect(!shouldCompileAsObjectiveC(.linux, library, "/tmp/sokol_impl.c"));
}
