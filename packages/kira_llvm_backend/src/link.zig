const std = @import("std");
const builtin = @import("builtin");
const native = @import("kira_native_lib_definition");
const build_options = @import("kira_llvm_build_options");
const backend_utils = @import("backend_utils.zig");
const runtime_utils = @import("backend_runtime_utils.zig");
const clang_driver = @import("clang_driver.zig");
const emscripten = @import("emscripten.zig");
const toolchain = @import("toolchain.zig");
const progress = @import("progress.zig");

pub fn buildRuntimeHelpersObject(
    allocator: std.mem.Allocator,
    object_path: []const u8,
    pic: bool,
    selector: ?native.TargetSelector,
) ![]const u8 {
    const helper_object = try helperObjectPath(allocator, object_path);
    const helper_source = try std.fs.path.join(allocator, &.{ build_options.repo_root, "packages", "kira_native_bridge", "src", "runtime_helpers.c" });
    try compileHelperSource(allocator, helper_source, helper_object, pic, selector);
    return helper_object;
}

pub fn buildDynamicFfiHelpersObject(
    allocator: std.mem.Allocator,
    object_path: []const u8,
    pic: bool,
    selector: ?native.TargetSelector,
) ![]const u8 {
    const helper_object = try siblingObjectPath(allocator, object_path, ".dynamic_ffi");
    const helper_source = try std.fs.path.join(allocator, &.{ build_options.repo_root, "packages", "kira_native_bridge", "src", "dynamic_ffi_helpers.c" });
    try compileHelperSource(allocator, helper_source, helper_object, pic, selector);
    return helper_object;
}

fn compileHelperSource(
    allocator: std.mem.Allocator,
    helper_source: []const u8,
    helper_object: []const u8,
    pic: bool,
    selector: ?native.TargetSelector,
) !void {
    const driver_path = try compilerDriverPathForSelector(allocator, selector);
    try ensureParentDir(helper_object);
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(driver_path);
    try clang_driver.appendClangDriverArgs(allocator, &argv, selector);
    if (pic and !isWindowsTarget(selector)) try argv.append("-fPIC");
    // Array ownership free is unconditional: kira_array_release reclaims owned
    // arrays on the pure-native path (the hybrid/VM path still defers to the VM's
    // destructors). The old KIRA_ARRAY_OWNERSHIP_FREE gate is gone — the clone
    // coverage it waited on (native-state boxing, field move-outs, borrowed-array
    // returns) is complete and validated under `leaks` on leak-harness,
    // liquid-glass, basic-foundation-app, and the project-matter editor.
    try argv.appendSlice(&.{ "-c", helper_source, "-o", helper_object });
    try runCommand(allocator, argv.items);
}

/// Relocatable-link (`-r`) the given objects into a single native object. The
/// incremental path uses this to produce the whole-program `object_path` artifact
/// from its per-function + support CGU objects, so native builds still report a
/// `native_object` and the build cache (which stores/restores that `.o`) works.
pub fn combineObjects(
    allocator: std.mem.Allocator,
    output_object_path: []const u8,
    object_paths: []const []const u8,
    selector: ?native.TargetSelector,
) !void {
    try ensureParentDir(output_object_path);
    if (combineObjectsAsArchive(selector)) {
        // COFF/MSVC has no GNU-style relocatable `-r` link. Passing `-r` to
        // clang on Windows reaches link.exe as `/r`, which is ignored and then
        // accidentally attempts an executable link. A COFF archive preserves
        // the per-CGU objects as one cacheable artifact and is accepted as an
        // ordinary input by the final clang/link.exe invocation.
        const llvm_toolchain = try toolchain.Toolchain.discover(allocator);
        const ar_path = try llvm_toolchain.llvmArPath(allocator);
        var archive_argv = std.array_list.Managed([]const u8).init(allocator);
        try archive_argv.appendSlice(&.{ ar_path, "rcs", output_object_path });
        for (object_paths) |path| try archive_argv.append(path);
        try runCommand(allocator, archive_argv.items);
        return;
    }
    const driver_path = try compilerDriverPathForSelector(allocator, selector);
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(driver_path);
    try clang_driver.appendClangDriverArgs(allocator, &argv, selector);
    try argv.appendSlice(&.{ "-r", "-nostdlib", "-o", output_object_path });
    for (object_paths) |path| try argv.append(path);
    try runCommand(allocator, argv.items);
}

pub fn linkExecutable(
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    object_paths: []const []const u8,
    native_libraries: []const native.ResolvedNativeLibrary,
    selector: ?native.TargetSelector,
    assets: []const native.AssetMount,
) !void {
    try ensureParentDir(executable_path);
    const driver_path = try compilerDriverPathForSelector(allocator, selector);
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(driver_path);
    try clang_driver.appendClangDriverArgs(allocator, &argv, selector);
    try argv.appendSlice(&.{ "-o", executable_path });
    if (windowsConsoleSubsystemArg(selector)) |subsystem_arg| {
        try argv.append(subsystem_arg);
    }
    try appendNativeExecutableFlags(&argv, selector);
    try appendEmscriptenExecutableFlags(&argv, selector);
    try appendPreloadedAssets(allocator, &argv, selector, assets);
    try appendNativeLibraryPaths(allocator, &argv);
    for (object_paths) |path| try argv.append(path);

    for (native_libraries) |library| {
        if (library.artifact_path.len != 0) try argv.append(library.artifact_path);
        for (library.link.system_libs) |system_lib| {
            try argv.append(try std.fmt.allocPrint(allocator, "-l{s}", .{system_lib}));
        }
        for (library.link.frameworks) |framework| {
            try argv.appendSlice(&.{ "-framework", framework });
        }
        for (library.link.linker_flags) |flag| try argv.append(flag);
    }
    try appendDefaultSystemLibraries(&argv, selector);

    try runCommand(allocator, argv.items);

    // On Apple targets DWARF stays in the object files' debug sections; the
    // debugger reads it from a companion `.dSYM` bundle that `dsymutil` builds
    // from the linked executable. Best-effort: a missing/failing dsymutil warns
    // (the executable is still linked) rather than failing the build.
    if (runtime_utils.debugInfoRequested() and isAppleTarget(selector)) {
        progress.print("Generating debug symbols for {s}", .{std.fs.path.basename(executable_path)});
        generateDsym(allocator, executable_path) catch |err| {
            std.debug.print("kira llvm backend: dsymutil did not run ({s}); executable linked without a .dSYM bundle\n", .{@errorName(err)});
        };
    }
    progress.print("Published executable {s}", .{std.fs.path.basename(executable_path)});
}

/// Kira's current LLVM object model uses absolute relocations for native global
/// data. Linux distributions commonly configure clang to link PIE executables
/// by default, which rejects those objects with R_X86_64_32S relocation errors.
/// Make the executable policy explicit until object emission itself is PIC.
fn appendNativeExecutableFlags(argv: *std.array_list.Managed([]const u8), selector: ?native.TargetSelector) !void {
    if (isLinuxTarget(selector) and !emscripten.isSelector(selector)) try argv.append("-no-pie");
}

pub fn linkSharedLibrary(
    allocator: std.mem.Allocator,
    library_path: []const u8,
    object_paths: []const []const u8,
    native_libraries: []const native.ResolvedNativeLibrary,
    selector: ?native.TargetSelector,
) !void {
    try ensureParentDir(library_path);
    const driver_path = try compilerDriverPathForSelector(allocator, selector);
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(driver_path);
    try clang_driver.appendClangDriverArgs(allocator, &argv, selector);
    try argv.appendSlice(&.{ "-shared", "-o", library_path });
    try appendNativeLibraryPaths(allocator, &argv);
    for (object_paths) |path| try argv.append(path);

    for (native_libraries) |library| {
        if (library.artifact_path.len != 0) try argv.append(library.artifact_path);
        for (library.link.system_libs) |system_lib| {
            try argv.append(try std.fmt.allocPrint(allocator, "-l{s}", .{system_lib}));
        }
        for (library.link.frameworks) |framework| {
            try argv.appendSlice(&.{ "-framework", framework });
        }
        for (library.link.linker_flags) |flag| try argv.append(flag);
    }
    try appendDefaultSystemLibraries(&argv, selector);

    try runCommand(allocator, argv.items);
}

/// Bundle build-time asset directories into a self-contained wasm package. Only
/// the Emscripten link understands `--preload-file`; every other target reads
/// its assets straight from disk at runtime, so the list is ignored there. Each
/// mount is emitted as `--preload-file <host>@<mount>`, placing the on-disk
/// directory at its project-relative path inside the browser MEMFS so a
/// runtime-relative `fopen` (resolved against MEMFS cwd `/`) still finds it.
fn appendPreloadedAssets(
    allocator: std.mem.Allocator,
    argv: *std.array_list.Managed([]const u8),
    selector: ?native.TargetSelector,
    assets: []const native.AssetMount,
) !void {
    if (!emscripten.isSelector(selector)) return;
    for (assets) |asset| {
        try argv.append("--preload-file");
        try argv.append(try std.fmt.allocPrint(allocator, "{s}@{s}", .{ asset.host_path, asset.mount_path }));
    }
}

/// Emscripten executable links keep Emscripten's default 16MB INITIAL_MEMORY but
/// enable ALLOW_MEMORY_GROWTH so the wasm heap can `sbrk`/`emscripten_resize_heap`
/// past that ceiling at runtime. Real Kira apps (UI Foundation dashboards, the
/// Kira graphics path) allocate well beyond 16MB per frame; without growth the
/// first large allocation aborts the module. Only the final executable link (emcc
/// linking to a `.js`/`.wasm` bundle) understands `-s` settings — object compiles
/// and relocatable links must not receive them.
///
/// GROWABLE_ARRAYBUFFERS=0 pairs with growth: with the default (=1) Emscripten
/// auto-detects the growable-views Web platform feature and backs `WebAssembly.
/// Memory` with a RESIZABLE `ArrayBuffer`. `TextDecoder.decode` rejects any view
/// over a resizable buffer on current V8 ("The provided ArrayBuffer value must not
/// be resizable"), which aborts every `UTF8ToString` — e.g. `fopen`'s path string
/// in Kira's FreeType font discovery during layout. Disabling growable views
/// makes growth use the classic detach-and-refresh path, where the active heap
/// view is a plain non-resizable `ArrayBuffer` that TextDecoder accepts. (Setting
/// does nothing unless ALLOW_MEMORY_GROWTH is set.)
fn appendEmscriptenExecutableFlags(argv: *std.array_list.Managed([]const u8), selector: ?native.TargetSelector) !void {
    if (!emscripten.isSelector(selector)) return;
    try argv.append("-sALLOW_MEMORY_GROWTH=1");
    try argv.append("-sGROWABLE_ARRAYBUFFERS=0");
    // Kira objects are already optimized (KIRA_NATIVE_OPT, default -O2), but the
    // emcc LINK stage defaults to -O0: no binaryen wasm-opt and an unoptimized JS
    // loader, which costs real frame time in browsers. Mirror the object-level
    // level here so a `-O0` build stays debuggable end to end.
    try argv.append(emccLinkOptFlag());
}

fn emccLinkOptFlag() []const u8 {
    const raw = std.c.getenv("KIRA_NATIVE_OPT") orelse return "-O2";
    const level = std.mem.span(raw);
    if (std.mem.eql(u8, level, "0")) return "-O0";
    if (std.mem.eql(u8, level, "1")) return "-O1";
    if (std.mem.eql(u8, level, "3")) return "-O3";
    if (std.mem.eql(u8, level, "s")) return "-Os";
    if (std.mem.eql(u8, level, "z")) return "-Oz";
    return "-O2";
}

fn appendDefaultSystemLibraries(argv: *std.array_list.Managed([]const u8), selector: ?native.TargetSelector) !void {
    if (emscripten.isSelector(selector)) return;
    if (isLinuxTarget(selector)) try argv.append("-lm");
}

fn appendNativeLibraryPaths(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8)) !void {
    var environ_map = try std.process.Environ.createMap(backend_utils.inheritedProcessEnviron(), allocator);
    defer environ_map.deinit();
    const value = environ_map.get("KIRA_NATIVE_LIBRARY_PATH") orelse return;
    var paths = std.mem.splitScalar(u8, value, std.fs.path.delimiter);
    while (paths.next()) |path| {
        if (path.len != 0) try argv.append(try std.fmt.allocPrint(allocator, "-L{s}", .{path}));
    }
}

fn compilerDriverPathForSelector(allocator: std.mem.Allocator, selector: ?native.TargetSelector) ![]const u8 {
    if (emscripten.isSelector(selector)) return emscripten.emccPath(allocator);
    if (try clang_driver.appleClangPathForSelector(allocator, selector)) |path| return path;
    const llvm_toolchain = try toolchain.Toolchain.discover(allocator);
    return llvm_toolchain.compilerDriverPath(allocator);
}

fn helperObjectPath(allocator: std.mem.Allocator, object_path: []const u8) ![]const u8 {
    return siblingObjectPath(allocator, object_path, ".bridge");
}

fn siblingObjectPath(allocator: std.mem.Allocator, object_path: []const u8, suffix: []const u8) ![]const u8 {
    const ext = std.fs.path.extension(object_path);
    if (ext.len == 0) return std.fmt.allocPrint(allocator, "{s}{s}.o", .{ object_path, suffix });
    const stem = object_path[0 .. object_path.len - ext.len];
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ stem, suffix, ext });
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const llvm_toolchain = try toolchain.Toolchain.discover(allocator);
    var environ_map = try llvm_toolchain.processEnvironMap(allocator);
    defer environ_map.deinit();
    const process_environ = backend_utils.inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(allocator, io_impl.io(), .{
        .argv = argv,
        .expand_arg0 = .expand,
        .environ_map = &environ_map,
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

fn shouldAddWindowsConsoleSubsystem(selector: ?native.TargetSelector) bool {
    return isWindowsTarget(selector) and !emscripten.isSelector(selector);
}

fn windowsConsoleSubsystemArg(selector: ?native.TargetSelector) ?[]const u8 {
    if (!shouldAddWindowsConsoleSubsystem(selector)) return null;
    const value = selector orelse return "-Wl,/subsystem:console";
    return if (std.mem.eql(u8, value.abi, "gnu"))
        "-Wl,--subsystem,console"
    else
        "-Wl,/subsystem:console";
}

fn isWindowsTarget(selector: ?native.TargetSelector) bool {
    const value = selector orelse return builtin.os.tag == .windows;
    return std.mem.eql(u8, value.operating_system, "windows");
}

fn combineObjectsAsArchive(selector: ?native.TargetSelector) bool {
    return isWindowsTarget(selector);
}

fn isLinuxTarget(selector: ?native.TargetSelector) bool {
    const value = selector orelse return builtin.os.tag == .linux;
    return std.mem.eql(u8, value.operating_system, "linux");
}

fn isAppleTarget(selector: ?native.TargetSelector) bool {
    const value = selector orelse return builtin.os.tag == .macos or builtin.os.tag == .ios;
    const os = value.operating_system;
    return std.mem.eql(u8, os, "macos") or
        std.mem.eql(u8, os, "ios") or
        std.mem.eql(u8, os, "tvos") or
        std.mem.eql(u8, os, "watchos") or
        std.mem.eql(u8, os, "xros");
}

// Run `dsymutil <executable>` to produce the companion `.dSYM` bundle. Tolerant:
// returns an error (which the caller downgrades to a warning) if dsymutil is
// missing or exits non-zero, so a toolchain without dsymutil still links.
fn generateDsym(allocator: std.mem.Allocator, executable_path: []const u8) !void {
    const llvm_toolchain = try toolchain.Toolchain.discover(allocator);
    const dsymutil_path = try llvm_toolchain.toolPath(allocator, "dsymutil");
    defer allocator.free(dsymutil_path);
    var environ_map = try llvm_toolchain.processEnvironMap(allocator);
    defer environ_map.deinit();
    const process_environ = backend_utils.inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(allocator, io_impl.io(), .{
        .argv = &.{ dsymutil_path, executable_path },
        .expand_arg0 = .expand,
        .environ_map = &environ_map,
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) return;
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    return error.DsymutilFailed;
}

test "windows console subsystem only applies to native windows targets" {
    try std.testing.expect(shouldAddWindowsConsoleSubsystem(.{
        .architecture = "x86_64",
        .operating_system = "windows",
        .abi = "msvc",
    }));
    try std.testing.expect(!shouldAddWindowsConsoleSubsystem(.{
        .architecture = "x86_64",
        .operating_system = "linux",
        .abi = "gnu",
    }));
    try std.testing.expect(!shouldAddWindowsConsoleSubsystem(.{
        .architecture = "wasm32",
        .operating_system = "emscripten",
        .abi = "unknown",
    }));
}

test "preload-file args are emitted only for the emscripten target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const assets = [_]native.AssetMount{
        .{ .host_path = "/proj/.kira-build/shaders", .mount_path = "/.kira-build/shaders" },
        .{ .host_path = "/proj/fonts", .mount_path = "/fonts" },
    };

    // Emscripten selector: each asset becomes a `--preload-file host@mount` pair.
    var wasm_argv = std.array_list.Managed([]const u8).init(allocator);
    try appendPreloadedAssets(allocator, &wasm_argv, .{
        .architecture = "wasm32",
        .operating_system = "emscripten",
        .abi = "unknown",
    }, &assets);
    try std.testing.expectEqual(@as(usize, 4), wasm_argv.items.len);
    try std.testing.expectEqualStrings("--preload-file", wasm_argv.items[0]);
    try std.testing.expectEqualStrings("/proj/.kira-build/shaders@/.kira-build/shaders", wasm_argv.items[1]);
    try std.testing.expectEqualStrings("--preload-file", wasm_argv.items[2]);
    try std.testing.expectEqualStrings("/proj/fonts@/fonts", wasm_argv.items[3]);

    // Non-emscripten target: assets are read from disk, so nothing is emitted.
    var host_argv = std.array_list.Managed([]const u8).init(allocator);
    try appendPreloadedAssets(allocator, &host_argv, .{
        .architecture = "x86_64",
        .operating_system = "linux",
        .abi = "gnu",
    }, &assets);
    try std.testing.expectEqual(@as(usize, 0), host_argv.items.len);

    // Null selector (host default) likewise emits nothing.
    var default_argv = std.array_list.Managed([]const u8).init(allocator);
    try appendPreloadedAssets(allocator, &default_argv, null, &assets);
    try std.testing.expectEqual(@as(usize, 0), default_argv.items.len);
}

test "ALLOW_MEMORY_GROWTH is emitted only for emscripten executable links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Emscripten selector: the growth flag is appended.
    var wasm_argv = std.array_list.Managed([]const u8).init(allocator);
    try appendEmscriptenExecutableFlags(&wasm_argv, .{
        .architecture = "wasm32",
        .operating_system = "emscripten",
        .abi = "unknown",
    });
    try std.testing.expectEqual(@as(usize, 2), wasm_argv.items.len);
    try std.testing.expectEqualStrings("-sALLOW_MEMORY_GROWTH=1", wasm_argv.items[0]);
    try std.testing.expectEqualStrings("-sGROWABLE_ARRAYBUFFERS=0", wasm_argv.items[1]);

    // Native target: no emscripten `-s` settings.
    var host_argv = std.array_list.Managed([]const u8).init(allocator);
    try appendEmscriptenExecutableFlags(&host_argv, .{
        .architecture = "x86_64",
        .operating_system = "linux",
        .abi = "gnu",
    });
    try std.testing.expectEqual(@as(usize, 0), host_argv.items.len);

    // Null selector (host default) likewise emits nothing.
    var default_argv = std.array_list.Managed([]const u8).init(allocator);
    try appendEmscriptenExecutableFlags(&default_argv, null);
    try std.testing.expectEqual(@as(usize, 0), default_argv.items.len);
}

test "windows console subsystem flag matches windows toolchain abi" {
    try std.testing.expectEqualStrings("-Wl,/subsystem:console", windowsConsoleSubsystemArg(.{
        .architecture = "x86_64",
        .operating_system = "windows",
        .abi = "msvc",
    }).?);
    try std.testing.expectEqualStrings("-Wl,--subsystem,console", windowsConsoleSubsystemArg(.{
        .architecture = "x86_64",
        .operating_system = "windows",
        .abi = "gnu",
    }).?);
}

test "linux executable links explicitly disable pie" {
    var linux_args = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer linux_args.deinit();
    try appendNativeExecutableFlags(&linux_args, .{
        .architecture = "x86_64",
        .operating_system = "linux",
        .abi = "gnu",
    });
    try std.testing.expectEqualSlices([]const u8, &.{"-no-pie"}, linux_args.items);

    var windows_args = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer windows_args.deinit();
    try appendNativeExecutableFlags(&windows_args, .{
        .architecture = "x86_64",
        .operating_system = "windows",
        .abi = "msvc",
    });
    try std.testing.expectEqual(@as(usize, 0), windows_args.items.len);
}

test "windows object combination uses the coff archive path" {
    try std.testing.expect(combineObjectsAsArchive(.{
        .architecture = "x86_64",
        .operating_system = "windows",
        .abi = "msvc",
    }));
    try std.testing.expect(!combineObjectsAsArchive(.{
        .architecture = "x86_64",
        .operating_system = "linux",
        .abi = "gnu",
    }));
}
