const std = @import("std");
const builtin = @import("builtin");
const native = @import("kira_native_lib_definition");
const llvm_backend = @import("kira_llvm_backend");
const paths = @import("native_build_paths.zig");

/// Compiles and archives the C/C++/Objective-C sources declared by a resolved
/// native library into its on-disk artifact, with content-addressed freshness
/// caching. Split out of `ffi_support.zig` (Core Law #5) so manifest discovery
/// and artifact compilation stay separately focused.
///
/// Backend selection is driven entirely by the resolved target selector: an
/// `wasm32-emscripten-*` target compiles with `emcc`/`emar` (no `-target`
/// needed, since emcc implies `wasm32-emscripten`), every other target uses the
/// managed clang + `llvm-ar`.
pub fn ensureNativeArtifact(allocator: std.mem.Allocator, library: *native.ResolvedNativeLibrary) !void {
    if (library.build.sources.len == 0) return;
    const maybe_dir = std.fs.path.dirname(library.artifact_path) orelse ".";
    try paths.makePath(maybe_dir);

    const fingerprint = try nativeArtifactFingerprint(allocator, library.*);
    defer allocator.free(fingerprint);
    const fingerprint_path = try nativeArtifactFingerprintPath(allocator, library.*);
    defer allocator.free(fingerprint_path);

    if (try nativeArtifactIsFresh(allocator, library.artifact_path, fingerprint_path, fingerprint)) {
        return;
    }
    switch (library.link_mode) {
        .static => try compileStaticLibrary(allocator, library),
        .dynamic => try compileSharedLibrary(allocator, library),
    }
    try writeFile(fingerprint_path, fingerprint);
}

pub fn nativeArtifactFingerprintPath(allocator: std.mem.Allocator, library: native.ResolvedNativeLibrary) ![]const u8 {
    const metadata_root = try nativeMetadataRoot(allocator, library);
    defer allocator.free(metadata_root);
    const digest = try nativeMetadataDigest(allocator, library);
    defer allocator.free(digest);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.fingerprint", .{digest});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ metadata_root, file_name });
}

pub fn nativeArtifactIsFresh(allocator: std.mem.Allocator, artifact_path: []const u8, fingerprint_path: []const u8, expected_fingerprint: []const u8) !bool {
    std.Io.Dir.cwd().access(std.Options.debug_io, artifact_path, .{}) catch return false;
    const existing = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, fingerprint_path, allocator, .limited(1024)) catch return false;
    defer allocator.free(existing);
    return std.mem.eql(u8, existing, expected_fingerprint);
}

pub fn nativeArtifactFingerprint(allocator: std.mem.Allocator, library: native.ResolvedNativeLibrary) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("kira-native-artifact-v1\n");
    hashString(&hasher, "name", library.name);
    hashString(&hasher, "link_mode", @tagName(library.link_mode));
    hashString(&hasher, "abi", @tagName(library.abi));
    hashString(&hasher, "arch", library.target.architecture);
    hashString(&hasher, "os", library.target.operating_system);
    hashString(&hasher, "target_abi", library.target.abi);
    if (library.manifest_path) |path| try hashFile(allocator, &hasher, path);
    try hashFiles(allocator, &hasher, library.build.sources);
    try hashFiles(allocator, &hasher, library.headers.include_dirs);
    try hashFiles(allocator, &hasher, library.build.include_dirs);
    if (library.headers.entrypoint) |path| try hashFile(allocator, &hasher, path);
    if (library.autobinding) |autobinding| try hashFiles(allocator, &hasher, autobinding.headers);
    hashStrings(&hasher, "header_define", library.headers.defines);
    hashStrings(&hasher, "build_define", library.build.defines);
    hashStrings(&hasher, "header_framework", library.headers.frameworks);
    hashStrings(&hasher, "link_framework", library.link.frameworks);
    hashStrings(&hasher, "header_system_lib", library.headers.system_libs);
    hashStrings(&hasher, "link_system_lib", library.link.system_libs);
    hashStrings(&hasher, "compiler_flag", library.compiler_flags);
    hashStrings(&hasher, "linker_flag", library.link.linker_flags);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexDigest(allocator, &digest);
}

pub fn nativeMetadataRoot(allocator: std.mem.Allocator, library: native.ResolvedNativeLibrary) ![]const u8 {
    const base_path = if (library.manifest_path) |manifest_path|
        std.fs.path.dirname(manifest_path) orelse manifest_path
    else
        std.fs.path.dirname(library.artifact_path) orelse ".";
    const project_root = try paths.discoverProjectRootFromPath(allocator, base_path);
    defer allocator.free(project_root);
    return std.fs.path.join(allocator, &.{ project_root, ".kira-build", "native" });
}

fn nativeMetadataDigest(allocator: std.mem.Allocator, library: native.ResolvedNativeLibrary) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    if (library.manifest_path) |manifest_path| {
        const canonical_manifest = try paths.absolutize(allocator, manifest_path);
        defer allocator.free(canonical_manifest);
        hasher.update(canonical_manifest);
    }
    hasher.update(library.name);
    hasher.update("\n");
    hasher.update(library.artifact_path);
    hasher.update("\n");
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = try hexDigest(allocator, &digest);
    return hex[0 .. hex.len - 1];
}

fn hashFiles(allocator: std.mem.Allocator, hasher: anytype, input_paths: []const []const u8) !void {
    var files = std.array_list.Managed([]const u8).init(allocator);
    for (input_paths) |path| {
        try collectNativeInputFiles(allocator, path, &files);
    }
    sortStrings(files.items);
    for (files.items) |path| {
        try hashFile(allocator, hasher, path);
    }
}

fn collectNativeInputFiles(allocator: std.mem.Allocator, path: []const u8, files: *std.array_list.Managed([]const u8)) !void {
    const stat = try std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{});

    if (stat.kind == .file) {
        if (isNativeBuildInput(path)) try files.append(try paths.absolutize(allocator, path));
        return;
    }
    if (stat.kind != .directory) return;
    const absolute = try paths.absolutize(allocator, path);
    try collectNativeInputFilesInDir(allocator, absolute, "", files);
}

fn collectNativeInputFilesInDir(
    allocator: std.mem.Allocator,
    root: []const u8,
    relative: []const u8,
    files: *std.array_list.Managed([]const u8),
) !void {
    const dir_path = if (relative.len == 0) root else try std.fs.path.join(allocator, &.{ root, relative });
    var dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var iterator = dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, ".kira-build") or std.mem.eql(u8, entry.name, "generated")) continue;
            const child_rel = if (relative.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &.{ relative, entry.name });
            try collectNativeInputFilesInDir(allocator, root, child_rel, files);
            continue;
        }
        if (entry.kind != .file or !isNativeBuildInput(entry.name)) continue;
        const rel_path = if (relative.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &.{ relative, entry.name });
        try files.append(try std.fs.path.join(allocator, &.{ root, rel_path }));
    }
}

fn isNativeBuildInput(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.mem.eql(u8, ext, ".c") or
        std.mem.eql(u8, ext, ".cc") or
        std.mem.eql(u8, ext, ".cpp") or
        std.mem.eql(u8, ext, ".cxx") or
        std.mem.eql(u8, ext, ".h") or
        std.mem.eql(u8, ext, ".hpp") or
        std.mem.eql(u8, ext, ".hh") or
        std.mem.eql(u8, ext, ".inc") or
        std.mem.eql(u8, ext, ".m") or
        std.mem.eql(u8, ext, ".mm");
}

fn hashFile(allocator: std.mem.Allocator, hasher: anytype, path: []const u8) !void {
    hashString(hasher, "file", path);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(contents);
    hasher.update(contents);
    hasher.update("\n");
}

fn hashString(hasher: anytype, name: []const u8, value: []const u8) void {
    hasher.update(name);
    hasher.update("=");
    hasher.update(value);
    hasher.update("\n");
}

fn hashStrings(hasher: anytype, name: []const u8, values: []const []const u8) void {
    for (values) |value| hashString(hasher, name, value);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    try paths.makePath(std.fs.path.dirname(path) orelse ".");
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true })
    else
        try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, data);
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
}

fn hexDigest(allocator: std.mem.Allocator, digest: []const u8) ![]const u8 {
    const alphabet = "0123456789abcdef";
    const out = try allocator.alloc(u8, digest.len * 2);
    for (digest, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

fn compileStaticLibrary(allocator: std.mem.Allocator, library: *native.ResolvedNativeLibrary) !void {
    const is_emscripten = llvm_backend.emscripten.isSelector(library.target);
    const compiler_path = try resolveCompilerDriver(allocator, library.target, is_emscripten);
    defer allocator.free(compiler_path);
    const archiver_path = try resolveArchiver(allocator, is_emscripten);
    defer allocator.free(archiver_path);

    var object_paths = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (object_paths.items) |path| {
            std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};
        }
    }

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

/// Compiles the library sources and links them into a shared library
/// (`.dll`/`.so`/`.dylib`/wasm side module) the VM can `dlopen` for direct
/// LibFFI dispatch. Exported symbols rely on `__declspec(dllexport)` (Windows)
/// or default visibility (POSIX) in the sources.
fn compileSharedLibrary(allocator: std.mem.Allocator, library: *native.ResolvedNativeLibrary) !void {
    const is_emscripten = llvm_backend.emscripten.isSelector(library.target);
    const compiler_path = try resolveCompilerDriver(allocator, library.target, is_emscripten);
    defer allocator.free(compiler_path);

    var object_paths = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (object_paths.items) |path| {
            std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};
        }
    }

    const build_suffix = randomBuildSuffix();
    const staged_artifact_path = try stagedArtifactPath(allocator, library.artifact_path, build_suffix);
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, staged_artifact_path) catch {};

    try compileSourcesToObjects(allocator, compiler_path, is_emscripten, library.*, build_suffix, &object_paths);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(compiler_path);
    if (!is_emscripten) {
        try llvm_backend.clangDriver.appendClangDriverArgs(allocator, &argv, library.target);
    }
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

/// Compiles each declared source into an object file, appending the produced
/// object paths (caller owns cleanup). Shared by the static and dynamic builds.
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
        for (library.headers.include_dirs) |include_dir| {
            try argv.append(try std.fmt.allocPrint(allocator, "-I{s}", .{include_dir}));
        }
        for (library.build.include_dirs) |include_dir| {
            try argv.append(try std.fmt.allocPrint(allocator, "-I{s}", .{include_dir}));
        }
        for (library.link.include_dirs) |include_dir| {
            try argv.append(try std.fmt.allocPrint(allocator, "-I{s}", .{include_dir}));
        }
        for (library.headers.defines) |define| {
            try argv.append(try std.fmt.allocPrint(allocator, "-D{s}", .{define}));
        }
        for (library.build.defines) |define| {
            try argv.append(try std.fmt.allocPrint(allocator, "-D{s}", .{define}));
        }
        for (library.link.defines) |define| {
            try argv.append(try std.fmt.allocPrint(allocator, "-D{s}", .{define}));
        }
        // Target-scoped compiler flags apply to every backend (e.g.
        // `--use-port=emdawnwebgpu` on wasm, `-fno-exceptions` elsewhere).
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
        // `emcc` implies `wasm32-emscripten`; a `-target` flag would fight the
        // Emscripten sysroot, so only clang builds get an explicit target.
        try llvm_backend.clangDriver.appendClangDriverArgs(argv.allocator, argv, library.target);
        if (shouldCompileAsObjectiveC(library.target, library, source_path)) {
            try argv.appendSlice(&.{ "-x", "objective-c" });
        }
    }
    if (isCxxSource(source_path)) {
        // C++ translation units (e.g. HarfBuzz) need an explicit standard; emcc
        // dispatches to em++ by source extension, so this holds on wasm too.
        try argv.append("-std=c++17");
    }
    try argv.appendSlice(&.{ source_path, "-o", object_path });
}

fn isCxxSource(source_path: []const u8) bool {
    const extension = std.fs.path.extension(source_path);
    return std.mem.eql(u8, extension, ".cc") or
        std.mem.eql(u8, extension, ".cpp") or
        std.mem.eql(u8, extension, ".cxx") or
        std.mem.eql(u8, extension, ".mm");
}

fn shouldCompileAsObjectiveC(selector: native.TargetSelector, library: native.ResolvedNativeLibrary, source_path: []const u8) bool {
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

pub fn hostTargetSelector(allocator: std.mem.Allocator) !native.TargetSelector {
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

fn nowNanoseconds() i128 {
    return std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.toNanoseconds();
}

test "macOS framework-backed C source compiles as Objective-C" {
    const macos: native.TargetSelector = .{ .architecture = "aarch64", .operating_system = "macos", .abi = "none" };
    const linux: native.TargetSelector = .{ .architecture = "x86_64", .operating_system = "linux", .abi = "gnu" };
    const library: native.ResolvedNativeLibrary = .{
        .name = "sokol",
        .link_mode = .static,
        .abi = .c,
        .artifact_path = "/tmp/libsokol.a",
        .target = undefined,
        .headers = .{},
        .link = .{ .frameworks = &.{"AppKit"} },
    };

    try std.testing.expect(shouldCompileAsObjectiveC(macos, library, "/tmp/sokol_impl.c"));
    try std.testing.expect(!shouldCompileAsObjectiveC(macos, library, "/tmp/sokol_impl.m"));
    try std.testing.expect(!shouldCompileAsObjectiveC(linux, library, "/tmp/sokol_impl.c"));
}

test "native artifact freshness tracks C and header content changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "Native");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Native/fresh.h",
        .data =
        \\#ifndef KIRA_NATIVE_FRESH_H
        \\#define KIRA_NATIVE_FRESH_H
        \\#define KIRA_NATIVE_STRESS_VALUE 41
        \\int kira_native_stress(void);
        \\#endif
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Native/fresh.c",
        .data =
        \\#include "fresh.h"
        \\int kira_native_stress(void) { return KIRA_NATIVE_STRESS_VALUE; }
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Native/fresh.toml",
        .data =
        \\[native]
        \\name = "fresh"
        \\
        ,
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "Native", allocator);
    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Native/fresh.c", allocator);
    const header_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Native/fresh.h", allocator);
    const manifest_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Native/fresh.toml", allocator);
    var library: native.ResolvedNativeLibrary = .{
        .manifest_path = manifest_path,
        .name = "fresh",
        .link_mode = .static,
        .abi = .c,
        .artifact_path = try std.fs.path.join(allocator, &.{ root, "libfresh.a" }),
        .target = try hostTargetSelector(allocator),
        .headers = .{
            .entrypoint = header_path,
            .include_dirs = &.{root},
        },
        .build = .{
            .sources = &.{source_path},
            .include_dirs = &.{root},
        },
        .link = .{},
    };
    const artifact_path = library.artifact_path;
    const fingerprint_path = try nativeArtifactFingerprintPath(allocator, library);

    try ensureNativeArtifact(allocator, &library);
    const fingerprint1 = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, fingerprint_path, allocator, .limited(1024));
    const artifact1 = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, artifact_path, allocator, .limited(1024 * 1024));
    try std.testing.expect(try nativeArtifactIsFresh(allocator, artifact_path, fingerprint_path, fingerprint1));

    try ensureNativeArtifact(allocator, &library);
    const fingerprint2 = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, fingerprint_path, allocator, .limited(1024));
    const artifact2 = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, artifact_path, allocator, .limited(1024 * 1024));
    try std.testing.expectEqualStrings(fingerprint1, fingerprint2);
    try std.testing.expectEqualSlices(u8, artifact1, artifact2);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Native/fresh.c",
        .data =
        \\#include "fresh.h"
        \\int kira_native_stress(void) { return KIRA_NATIVE_STRESS_VALUE + 1; }
        \\
        ,
    });
    const source_fingerprint = try nativeArtifactFingerprint(allocator, library);
    try std.testing.expect(!std.mem.eql(u8, fingerprint1, source_fingerprint));
    try std.testing.expect(!try nativeArtifactIsFresh(allocator, artifact_path, fingerprint_path, source_fingerprint));
    try ensureNativeArtifact(allocator, &library);
    const fingerprint3 = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, fingerprint_path, allocator, .limited(1024));
    const artifact3 = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, artifact_path, allocator, .limited(1024 * 1024));
    try std.testing.expectEqualStrings(source_fingerprint, fingerprint3);
    try std.testing.expect(!std.mem.eql(u8, artifact1, artifact3));

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Native/fresh.h",
        .data =
        \\#ifndef KIRA_NATIVE_FRESH_H
        \\#define KIRA_NATIVE_FRESH_H
        \\#define KIRA_NATIVE_STRESS_VALUE 55
        \\int kira_native_stress(void);
        \\#endif
        \\
        ,
    });
    const header_fingerprint = try nativeArtifactFingerprint(allocator, library);
    try std.testing.expect(!std.mem.eql(u8, fingerprint3, header_fingerprint));
    try std.testing.expect(!try nativeArtifactIsFresh(allocator, artifact_path, fingerprint_path, header_fingerprint));
    try ensureNativeArtifact(allocator, &library);
    const fingerprint4 = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, fingerprint_path, allocator, .limited(1024));
    const artifact4 = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, artifact_path, allocator, .limited(1024 * 1024));
    try std.testing.expectEqualStrings(header_fingerprint, fingerprint4);
    try std.testing.expect(!std.mem.eql(u8, artifact3, artifact4));
    try std.testing.expect(try nativeArtifactIsFresh(allocator, artifact_path, fingerprint_path, fingerprint4));
}

test "native artifact fingerprint tracks compiler and linker flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const base: native.ResolvedNativeLibrary = .{
        .name = "flagged",
        .link_mode = .static,
        .abi = .c,
        .artifact_path = "/tmp/libflagged.a",
        .target = .{ .architecture = "wasm32", .operating_system = "emscripten", .abi = "unknown" },
        .headers = .{},
        .link = .{},
    };
    const base_fingerprint = try nativeArtifactFingerprint(allocator, base);

    var with_compiler_flags = base;
    with_compiler_flags.compiler_flags = &.{"--use-port=emdawnwebgpu"};
    const compiler_fingerprint = try nativeArtifactFingerprint(allocator, with_compiler_flags);
    try std.testing.expect(!std.mem.eql(u8, base_fingerprint, compiler_fingerprint));

    var with_linker_flags = base;
    with_linker_flags.link = .{ .linker_flags = &.{"-sASYNCIFY"} };
    const linker_fingerprint = try nativeArtifactFingerprint(allocator, with_linker_flags);
    try std.testing.expect(!std.mem.eql(u8, base_fingerprint, linker_fingerprint));
    try std.testing.expect(!std.mem.eql(u8, compiler_fingerprint, linker_fingerprint));
}

test "native metadata stays inside the library root without a project manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scratch_parent = paths.processTempRoot() orelse return error.SkipZigTest;
    const unique = try std.fmt.allocPrint(allocator, "{x}", .{nowNanoseconds()});
    const scratch_root = try std.fs.path.join(allocator, &.{ scratch_parent, "kirac-native-artifact-no-manifest", unique });
    try paths.makePath(scratch_root);

    var parent_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, scratch_parent, .{});
    defer parent_dir.close(std.testing.io);
    defer parent_dir.deleteTree(std.testing.io, std.fs.path.basename(scratch_root)) catch {};

    var scratch_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, scratch_root, .{});
    defer scratch_dir.close(std.testing.io);
    try scratch_dir.createDirPath(std.testing.io, "Native");
    try scratch_dir.writeFile(std.testing.io, .{
        .sub_path = "Native/example.c",
        .data = "int kira_native_example(void) { return 0; }\n",
    });

    const root = try std.fs.path.join(allocator, &.{ scratch_root, "Native" });
    const source_path = try std.fs.path.join(allocator, &.{ scratch_root, "Native", "example.c" });
    const library: native.ResolvedNativeLibrary = .{
        .manifest_path = null,
        .name = "example",
        .link_mode = .static,
        .abi = .c,
        .artifact_path = try std.fs.path.join(allocator, &.{ root, "libexample.a" }),
        .target = try hostTargetSelector(allocator),
        .headers = .{},
        .build = .{
            .sources = &.{source_path},
        },
        .link = .{},
    };

    const metadata_root = try nativeMetadataRoot(allocator, library);
    const expected = try std.fs.path.join(allocator, &.{ root, ".kira-build", "native" });
    try std.testing.expectEqualStrings(expected, metadata_root);
}
