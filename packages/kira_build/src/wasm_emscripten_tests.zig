const std = @import("std");
const build_def = @import("kira_build_definition");
const BuildSystem = @import("build_system.zig").BuildSystem;
const support = @import("wasm_emscripten_test_support.zig");

// General wasm32-emscripten build/run pipeline tests. The C-ABI width regression
// family (size_t/pointer/callback/clone-contents width bugs) lives in
// wasm_emscripten_width_tests.zig (Core Law #5 split); shared test infrastructure
// lives in wasm_emscripten_test_support.zig. Alias the helpers so the test bodies
// below read unchanged.
const firstArtifactWithExtension = support.firstArtifactWithExtension;
const hasArtifact = support.hasArtifact;
const replaceExtension = support.replaceExtension;
const ensureRuntimeToolingAvailable = support.ensureRuntimeToolingAvailable;
const inheritedProcessEnviron = support.inheritedProcessEnviron;

test "wasm32 emscripten build runs real Kira entrypoint through node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const process_allocator = std.heap.smp_allocator;
    try ensureRuntimeToolingAvailable(process_allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.createDirPath(std.testing.io, "out");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\@Main
        \\function main() {
        \\    print("wasm-entrypoint-ok");
        \\    return;
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "App/app/main.kira", allocator);
    const output_root = try tmp.dir.realPathFileAlloc(std.testing.io, "out", allocator);
    const output_path = try std.fs.path.join(allocator, &.{ output_root, "main.js" });

    var system = BuildSystem.init(allocator);
    system.use_cache = false;
    const outcome = try system.build(.{
        .source_path = source_path,
        .output_path = output_path,
        .target = build_def.BuildTarget{ .execution = .wasm32_emscripten },
    });

    try std.testing.expect(!outcome.failed());
    try std.testing.expect(hasArtifact(outcome.artifacts, output_path));
    try std.testing.expect(hasArtifact(outcome.artifacts, try replaceExtension(allocator, output_path, ".wasm")));

    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(process_allocator, io_impl.io(), .{
        .argv = &.{ "node", output_path },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);

    try std.testing.expectEqual(@as(std.process.Child.Term, .{ .exited = 0 }), result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "wasm-entrypoint-ok") != null);
}

test "wasm32 emscripten compiles and links a declared native library through emcc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const process_allocator = std.heap.smp_allocator;
    try ensureRuntimeToolingAvailable(process_allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.createDirPath(std.testing.io, "App/NativeLibs");
    try tmp.dir.createDirPath(std.testing.io, "out");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/kira.toml",
        .data =
        \\[package]
        \\name = "App"
        \\version = "0.1.0"
        \\kind = "app"
        \\kira = "0.1.0"
        \\native_libraries = ["NativeLibs/kira_add.toml"]
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/NativeLibs/kira_add.toml",
        .data =
        \\[library]
        \\name = "kira_add"
        \\link_mode = "static"
        \\abi = "c"
        \\
        \\[build]
        \\sources = ["kira_add.c"]
        \\
        \\[target.wasm32-emscripten-unknown]
        \\static_lib = "libkira_add.a"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/NativeLibs/kira_add.c",
        .data = "int kira_test_add(int a, int b) { return a + b; }\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/kira_add.kira",
        .data =
        \\@FFI.Extern { library: kira_add; symbol: kira_test_add; abi: c; }
        \\function kira_test_add(a: I32, b: I32): I32;
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\@Main
        \\@Native
        \\function main() {
        \\    let sum: I32 = kira_test_add(40, 2)
        \\    print(sum)
        \\    return
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "App/app/main.kira", allocator);
    const output_root = try tmp.dir.realPathFileAlloc(std.testing.io, "out", allocator);
    const output_path = try std.fs.path.join(allocator, &.{ output_root, "main.js" });

    var system = BuildSystem.init(allocator);
    system.use_cache = false;
    const outcome = try system.build(.{
        .source_path = source_path,
        .output_path = output_path,
        .target = build_def.BuildTarget{ .execution = .wasm32_emscripten },
    });

    try std.testing.expect(!outcome.failed());
    // A packaged app names its artifacts after the package, so locate the
    // emitted JS/wasm loader by extension rather than assuming `main.js`.
    const js_path = firstArtifactWithExtension(outcome.artifacts, ".js") orelse return error.TestUnexpectedResult;
    try std.testing.expect(firstArtifactWithExtension(outcome.artifacts, ".wasm") != null);

    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(process_allocator, io_impl.io(), .{
        .argv = &.{ "node", js_path },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);

    try std.testing.expectEqual(@as(std.process.Child.Term, .{ .exited = 0 }), result.term);
    // The native `kira_test_add(40, 2)` was compiled by emcc, archived by emar,
    // linked into the wasm module, and invoked through the real Kira @Native FFI path.
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "42") != null);
}

test "wasm32 emscripten reports host native library target exclusion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.createDirPath(std.testing.io, "App/NativeLibs");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/kira.toml",
        .data =
        \\[package]
        \\name = "App"
        \\version = "0.1.0"
        \\kind = "app"
        \\kira = "0.1.0"
        \\native_libraries = ["NativeLibs/host_only.toml"]
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\@Main
        \\function main() {
        \\    print("host-only-native-lib");
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/NativeLibs/host_only.toml",
        .data =
        \\[library]
        \\name = "host_only"
        \\link_mode = "static"
        \\abi = "c"
        \\
        \\[target.aarch64-macos-none]
        \\static_lib = "libhost_only.a"
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "App/app/main.kira", allocator);
    var system = BuildSystem.init(allocator);
    system.use_cache = false;
    const result = try system.checkForBuildTarget(source_path, .{ .execution = .wasm32_emscripten });

    try std.testing.expect(result.failed());
    try std.testing.expectEqualStrings("KTC003", result.diagnostics[0].code.?);
    try std.testing.expectEqualStrings("unsupported native library target", result.diagnostics[0].title);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostics[0].message, "wasm32-emscripten-unknown") != null);
}
