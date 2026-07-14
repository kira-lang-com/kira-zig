const std = @import("std");
const native = @import("kira_native_lib_definition");
const tests_config = @import("tests_config.zig");
const PackageKind = @import("project_manifest.zig").PackageKind;
const loadProjectManifestFromDeclaration = @import("declaration_loader.zig").loadProjectManifestFromDeclaration;

test "loads a full package.kira declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try loadProjectManifestFromDeclaration(allocator,
        \\Package LiquidGlass {
        \\    let version = "0.2.0"
        \\    let kira = "0.7.0"
        \\    let kind = .App
        \\    let defaults = Defaults { executionMode: .Hybrid, buildTarget: .Host }
        \\    let tests = Tests { backends: [.Vm, .Llvm, .Hybrid], phase: .Both }
        \\    let dependencies = [ Dependency { name: "Foundation", version: "0.1.0" } ]
        \\}
    , "package.kira");

    try std.testing.expect(result.ok());
    try std.testing.expectEqualStrings("LiquidGlass", result.manifest.name);
    try std.testing.expectEqualStrings("0.2.0", result.manifest.version);
    try std.testing.expectEqualStrings("0.7.0", result.manifest.kira_version);
    try std.testing.expectEqual(PackageKind.app, result.manifest.kind);
    try std.testing.expectEqualStrings("hybrid", result.manifest.execution_mode);
    try std.testing.expectEqualStrings("host", result.manifest.build_target);
    try std.testing.expect(result.manifest.tests != null);
    try std.testing.expectEqual(@as(usize, 3), result.manifest.tests.?.backends.len);
    try std.testing.expectEqual(tests_config.TestPhase.both, result.manifest.tests.?.phase);
    try std.testing.expectEqual(@as(usize, 1), result.manifest.dependencies.len);
    try std.testing.expectEqualStrings("Foundation", result.manifest.dependencies[0].name);
    try std.testing.expect(result.manifest.dependencies[0].source == .registry);
}

test "loads git dependency without changing its source kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try loadProjectManifestFromDeclaration(arena.allocator(),
        \\Package GitConsumer {
        \\    let dependencies = [ Dependency { name: "Remote", git: "https://example.com/remote.git", rev: "abc123", tag: "v1" } ]
        \\}
    , "package.kira");

    try std.testing.expect(result.ok());
    const source = result.manifest.dependencies[0].source.git;
    try std.testing.expectEqualStrings("https://example.com/remote.git", source.url);
    try std.testing.expectEqualStrings("abc123", source.rev.?);
    try std.testing.expectEqualStrings("v1", source.tag.?);
}

test "maps Wasm package default to the CLI backend spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try loadProjectManifestFromDeclaration(arena.allocator(),
        \\Package WebApp {
        \\    let defaults = Defaults { executionMode: .Wasm, buildTarget: .Wasm }
        \\}
    , "package.kira");

    try std.testing.expect(result.ok());
    try std.testing.expectEqualStrings("wasm32-emscripten", result.manifest.execution_mode);
    try std.testing.expectEqual(@import("platform_config.zig").ExecutionBackend.wasm_runtime, result.manifest.execution_policy.default_backend);
}

test "loads inline native library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try loadProjectManifestFromDeclaration(allocator,
        \\Package KikCorpusSokol {
        \\    let version = "0.1.0"
        \\    let kind = .App
        \\    let defaults = Defaults { executionMode: .Hybrid, buildTarget: .Host }
        \\    let nativeLibraries = [
        \\        NativeLibrary {
        \\            name: "sokol_gfx",
        \\            linkMode: .Static,
        \\            headers: Headers { entrypoint: "third_party/sokol/sokol_gfx.h", includeDirs: ["third_party/sokol"], defines: ["SOKOL_DUMMY_BACKEND"] },
        \\            sources: ["third_party/sokol/sokol_gfx_impl.c"],
        \\            autobind: Autobind { module: "sokol_gfx", profile: .Vulkan, headers: ["third_party/sokol/sokol_gfx.h"], functions: ["sg_setup", "sg_isvalid"], structs: ["sg_desc"] }
        \\        }
        \\    ]
        \\}
    , "package.kira");

    try std.testing.expect(result.ok());
    try std.testing.expectEqual(@as(usize, 1), result.manifest.inline_native_libraries.len);
    const lib = result.manifest.inline_native_libraries[0];
    try std.testing.expectEqualStrings("sokol_gfx", lib.name);
    try std.testing.expectEqual(native.LinkMode.static, lib.link_mode);
    try std.testing.expectEqualStrings("third_party/sokol/sokol_gfx.h", lib.headers.entrypoint.?);
    try std.testing.expectEqual(@as(usize, 1), lib.build.sources.len);
    try std.testing.expect(lib.autobinding != null);
    try std.testing.expectEqualStrings("sokol_gfx", lib.autobinding.?.module_name);
    try std.testing.expectEqualStrings("third_party/sokol/sokol_gfx.h", lib.autobinding.?.headers[0]);
    try std.testing.expectEqual(native.AutobindingProfile.vulkan, lib.autobinding.?.bindings.profile);
    try std.testing.expectEqual(@as(usize, 2), lib.autobinding.?.bindings.functions.len);
}

test "diagnoses unknown field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try loadProjectManifestFromDeclaration(allocator,
        \\Package Demo {
        \\    let version = "0.1.0"
        \\    let bogus = "nope"
        \\}
    , "package.kira");

    try std.testing.expect(!result.ok());
    try std.testing.expectEqualStrings("KMAN004", result.diagnostics[0].code.?);
}

test "diagnoses empty Tests backend matrix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try loadProjectManifestFromDeclaration(arena.allocator(),
        \\Package Demo {
        \\    let tests = Tests { backends: [], phase: .Both }
        \\}
    , "package.kira");

    try std.testing.expect(!result.ok());
    var found = false;
    for (result.diagnostics) |diagnostic| {
        if (diagnostic.code != null and std.mem.eql(u8, diagnostic.code.?, "KMAN008")) found = true;
    }
    try std.testing.expect(found);
}

test "diagnoses non-literal initializer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try loadProjectManifestFromDeclaration(allocator,
        \\Package Demo {
        \\    let version = someComputed()
        \\}
    , "package.kira");

    try std.testing.expect(!result.ok());
    try std.testing.expectEqualStrings("KMAN012", result.diagnostics[0].code.?);
}

test "diagnoses wrong-typed field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try loadProjectManifestFromDeclaration(allocator,
        \\Package Demo {
        \\    let version = 12
        \\}
    , "package.kira");

    try std.testing.expect(!result.ok());
    try std.testing.expectEqualStrings("KMAN012", result.diagnostics[0].code.?);
}

test "diagnoses unknown enum value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try loadProjectManifestFromDeclaration(allocator,
        \\Package Demo {
        \\    let kind = PackageKind.Widget
        \\}
    , "package.kira");

    try std.testing.expect(!result.ok());
    try std.testing.expectEqualStrings("KMAN005", result.diagnostics[0].code.?);
}

test "diagnoses unknown BuildTarget value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try loadProjectManifestFromDeclaration(arena.allocator(),
        \\Package Demo {
        \\    let defaults = Defaults { executionMode: .Vm, buildTarget: .Wsam }
        \\}
    , "package.kira");

    try std.testing.expect(!result.ok());
    var found = false;
    for (result.diagnostics) |diagnostic| {
        if (diagnostic.code != null and std.mem.eql(u8, diagnostic.code.?, "KMAN006")) found = true;
    }
    try std.testing.expect(found);
}

test "diagnoses missing Package declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try loadProjectManifestFromDeclaration(allocator,
        \\enum NotAPackage { A B }
    , "package.kira");

    try std.testing.expect(!result.ok());
    try std.testing.expectEqualStrings("KMAN001", result.diagnostics[0].code.?);
}

test "warns on explicit autobind output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try loadProjectManifestFromDeclaration(allocator,
        \\Package Demo {
        \\    let version = "0.1.0"
        \\    let nativeLibraries = [
        \\        NativeLibrary { name: "x", autobind: Autobind { module: "x", output: "../app/x.kira" } }
        \\    ]
        \\}
    , "package.kira");

    // A warning does not fail the load's `ok()`... but our loader treats any
    // diagnostic as non-ok. Assert the warning is present with the right code.
    var found = false;
    for (result.diagnostics) |d| {
        if (d.code != null and std.mem.eql(u8, d.code.?, "KMAN011")) found = true;
    }
    try std.testing.expect(found);
}

test "diagnoses unknown AutobindMode variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try loadProjectManifestFromDeclaration(arena.allocator(),
        \\Package Demo {
        \\    let nativeLibraries = [
        \\        NativeLibrary { name: "x", autobind: Autobind { module: "x", mode: .AllPublc } }
        \\    ]
        \\}
    , "package.kira");

    try std.testing.expect(!result.ok());
    var found = false;
    for (result.diagnostics) |diagnostic| {
        if (diagnostic.code != null and std.mem.eql(u8, diagnostic.code.?, "KMAN006")) found = true;
    }
    try std.testing.expect(found);
}
