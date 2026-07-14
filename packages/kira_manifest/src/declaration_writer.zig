const std = @import("std");
const core = @import("kira_core");
const dependency = @import("dependency.zig");
const native = @import("kira_native_lib_definition");
const ProjectManifest = @import("project_manifest.zig").ProjectManifest;
const PackageKind = @import("project_manifest.zig").PackageKind;

/// Render a `ProjectManifest` as a `package.kira` declaration manifest — the
/// inverse of `declaration_loader.loadProjectManifestFromDeclaration`. Used by
/// `kira migrate-manifest` to turn a loaded `kira.toml` into `package.kira`.
///
/// Native libraries are emitted inline from `manifest.inline_native_libraries`
/// (the migrate command resolves `native_libraries` TOML paths into specs before
/// calling this). Per-target static-lib paths and the autobind `output` field
/// are intentionally dropped: prebuilt targets are replaced by build-from-source
/// and bindings always write to `app/bindings/<module>.kira`.
pub fn writeProjectManifestAsDeclaration(writer: anytype, manifest: ProjectManifest) !void {
    try writer.writeAll("Package ");
    try writePackageName(writer, manifest.name);
    try writer.writeAll(" {\n");
    try writer.writeAll("    let version = ");
    try writeQuotedString(writer, manifest.version);
    try writer.writeAll("\n");
    try writer.writeAll("    let kira = ");
    try writeQuotedString(writer, manifest.kira_version);
    try writer.writeAll("\n");
    try writer.print("    let kind = PackageKind.{s}\n", .{kindVariant(manifest.kind)});
    if (manifest.module_root) |root| {
        try writer.writeAll("    let moduleRoot = ");
        try writeQuotedString(writer, root);
        try writer.writeAll("\n");
    }
    try writer.print("    let defaults = Defaults {{ executionMode: Backend.{s}, buildTarget: BuildTarget.{s} }}\n", .{
        backendVariant(manifest.execution_mode),
        buildTargetVariant(manifest.build_target),
    });

    if (manifest.tests) |tests| {
        try writer.writeAll("    let tests = Tests { backends: [");
        for (tests.backends, 0..) |backend, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.print("Backend.{s}", .{backendEnumVariant(backend)});
        }
        try writer.print("], phase: TestPhase.{s} }}\n", .{phaseVariant(tests.phase)});
    }

    if (manifest.assets.len > 0) {
        try writer.writeAll("    let assets = ");
        try writeStringArray(writer, manifest.assets);
        try writer.writeAll("\n");
    }

    if (manifest.dependencies.len > 0) {
        try writer.writeAll("    let dependencies = [\n");
        for (manifest.dependencies, 0..) |dep, index| {
            try writer.writeAll("        Dependency { name: ");
            try writeQuotedString(writer, dep.name);
            switch (dep.source) {
                .registry => |r| {
                    try writer.writeAll(", version: ");
                    try writeQuotedString(writer, r.version);
                },
                .path => |p| {
                    try writer.writeAll(", path: ");
                    try writeQuotedString(writer, p.path);
                },
                .git => |g| {
                    try writer.writeAll(", git: ");
                    try writeQuotedString(writer, g.url);
                    if (g.rev) |rev| {
                        try writer.writeAll(", rev: ");
                        try writeQuotedString(writer, rev);
                    }
                    if (g.tag) |tag| {
                        try writer.writeAll(", tag: ");
                        try writeQuotedString(writer, tag);
                    }
                },
            }
            try writer.writeAll(if (index + 1 == manifest.dependencies.len) " }\n" else " },\n");
        }
        try writer.writeAll("    ]\n");
    }

    if (manifest.inline_native_libraries.len > 0) {
        try writer.writeAll("    let nativeLibraries = [\n");
        for (manifest.inline_native_libraries, 0..) |lib, index| {
            try writeNativeLibrary(writer, lib);
            if (index + 1 != manifest.inline_native_libraries.len) try writer.writeAll(",");
            try writer.writeAll("\n");
        }
        try writer.writeAll("    ]\n");
    }

    try writer.writeAll("}\n");
}

fn writeNativeLibrary(writer: anytype, lib: native.NativeLibrarySpec) !void {
    try writer.writeAll("        NativeLibrary {\n");
    try writer.writeAll("            name: ");
    try writeQuotedString(writer, lib.name);
    try writer.writeAll(",\n");
    try writer.print("            linkMode: LinkMode.{s},\n", .{linkModeVariant(lib.link_mode)});
    try writeHeaders(writer, lib.headers, lib.build);
    if (lib.build.sources.len > 0) {
        try writer.writeAll("            sources: ");
        try writeStringArray(writer, lib.build.sources);
        try writer.writeAll(",\n");
    }
    if (lib.autobinding) |auto| {
        try writeAutobind(writer, auto);
    }
    if (lib.targets.len > 0) {
        try writeTargets(writer, lib.targets);
    }
    try writer.writeAll("        }");
}

fn writeTargets(writer: anytype, targets: []const native.TargetSpec) !void {
    try writer.writeAll("            nativeTargets: [\n");
    for (targets, 0..) |target, index| {
        try writer.writeAll("                NativeTarget { triple: \"");
        try writeEscapedStringContents(writer, target.selector.architecture);
        try writer.writeAll("-");
        try writeEscapedStringContents(writer, target.selector.operating_system);
        try writer.writeAll("-");
        try writeEscapedStringContents(writer, target.selector.abi);
        try writer.writeAll("\"");
        // Emit artifact paths even when empty: `dynamicLib: ""` means "no
        // compiled shim — resolve symbols in-process", which is distinct
        // from the field being absent (build from sources / unsupported).
        if (target.static_lib) |path| {
            try writer.writeAll(", staticLib: ");
            try writeQuotedString(writer, path);
        }
        if (target.dynamic_lib) |path| {
            try writer.writeAll(", dynamicLib: ");
            try writeQuotedString(writer, path);
        }
        if (target.compiler_flags.len > 0) {
            try writer.writeAll(", compilerFlags: ");
            try writeStringArray(writer, target.compiler_flags);
        }
        if (target.link.include_dirs.len > 0) {
            try writer.writeAll(", includeDirs: ");
            try writeStringArray(writer, target.link.include_dirs);
        }
        if (target.link.defines.len > 0) {
            try writer.writeAll(", defines: ");
            try writeStringArray(writer, target.link.defines);
        }
        if (target.link.frameworks.len > 0) {
            try writer.writeAll(", frameworks: ");
            try writeStringArray(writer, target.link.frameworks);
        }
        if (target.link.system_libs.len > 0) {
            try writer.writeAll(", systemLibs: ");
            try writeStringArray(writer, target.link.system_libs);
        }
        if (target.link.linker_flags.len > 0) {
            try writer.writeAll(", linkerFlags: ");
            try writeStringArray(writer, target.link.linker_flags);
        }
        try writer.writeAll(if (index + 1 == targets.len) " }\n" else " },\n");
    }
    try writer.writeAll("            ],\n");
}

fn writeHeaders(writer: anytype, headers: native.HeaderSpec, build: native.BuildRecipe) !void {
    // The declaration schema carries one includeDirs/defines set (the loader
    // applies it to both header parsing and source builds), so legacy
    // build-only flags must be folded in here or migration drops them.
    const has_include_dirs = headers.include_dirs.len > 0 or build.include_dirs.len > 0;
    const has_defines = headers.defines.len > 0 or build.defines.len > 0;
    if (headers.entrypoint == null and !has_include_dirs and !has_defines and
        headers.frameworks.len == 0 and headers.system_libs.len == 0) return;
    try writer.writeAll("            headers: Headers {");
    var first = true;
    if (headers.entrypoint) |entry| {
        try writer.writeAll(" entrypoint: ");
        try writeQuotedString(writer, entry);
        first = false;
    }
    if (has_include_dirs) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll(" includeDirs: ");
        try writeMergedStringArray(writer, headers.include_dirs, build.include_dirs);
        first = false;
    }
    if (has_defines) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll(" defines: ");
        try writeMergedStringArray(writer, headers.defines, build.defines);
        first = false;
    }
    if (headers.frameworks.len > 0) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll(" frameworks: ");
        try writeStringArray(writer, headers.frameworks);
        first = false;
    }
    if (headers.system_libs.len > 0) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll(" systemLibs: ");
        try writeStringArray(writer, headers.system_libs);
    }
    try writer.writeAll(" },\n");
}

fn writeAutobind(writer: anytype, auto: native.AutobindingSpec) !void {
    try writer.writeAll("            autobind: Autobind { module: ");
    try writeQuotedString(writer, auto.module_name);
    if (auto.headers.len > 0) {
        try writer.writeAll(", headers: ");
        try writeStringArray(writer, auto.headers);
    }
    if (auto.bindings.mode == .all_public) {
        try writer.writeAll(", mode: AutobindMode.AllPublic");
    }
    if (auto.bindings.profile != .generic) {
        try writer.print(", profile: AutobindProfile.{s}", .{autobindProfileVariant(auto.bindings.profile)});
    }
    if (auto.bindings.functions.len > 0) {
        try writer.writeAll(", functions: ");
        try writeStringArray(writer, auto.bindings.functions);
    }
    if (auto.bindings.structs.len > 0) {
        try writer.writeAll(", structs: ");
        try writeStringArray(writer, auto.bindings.structs);
    }
    if (auto.bindings.callbacks.len > 0) {
        try writer.writeAll(", callbacks: ");
        try writeStringArray(writer, auto.bindings.callbacks);
    }
    try writer.writeAll(" }\n");
}

fn autobindProfileVariant(profile: native.AutobindingProfile) []const u8 {
    return switch (profile) {
        .generic => "Generic",
        .vulkan => "Vulkan",
        .directx12 => "DirectX12",
    };
}

fn writeStringArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeAll("[");
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeQuotedString(writer, value);
    }
    try writer.writeAll("]");
}

/// Emit `primary` followed by entries of `extra` not already in `primary`,
/// as one deduplicated array.
fn writeMergedStringArray(writer: anytype, primary: []const []const u8, extra: []const []const u8) !void {
    try writer.writeAll("[");
    var written: usize = 0;
    for (primary) |value| {
        if (written != 0) try writer.writeAll(", ");
        try writeQuotedString(writer, value);
        written += 1;
    }
    outer: for (extra, 0..) |value, index| {
        for (primary) |seen| {
            if (std.mem.eql(u8, seen, value)) continue :outer;
        }
        for (extra[0..index]) |seen| {
            if (std.mem.eql(u8, seen, value)) continue :outer;
        }
        if (written != 0) try writer.writeAll(", ");
        try writeQuotedString(writer, value);
        written += 1;
    }
    try writer.writeAll("]");
}

fn writeQuotedString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    try writeEscapedStringContents(writer, value);
    try writer.writeAll("\"");
}

fn writeEscapedStringContents(writer: anytype, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0 => try writer.writeAll("\\0"),
        else => try writer.writeByte(byte),
    };
}

fn writePackageName(writer: anytype, name: []const u8) !void {
    try core.writeKiraIdentifier(writer, name, "Package");
}

fn kindVariant(kind: PackageKind) []const u8 {
    return switch (kind) {
        .app => "App",
        .library => "Library",
    };
}

fn linkModeVariant(mode: native.LinkMode) []const u8 {
    return switch (mode) {
        .static => "Static",
        .dynamic => "Dynamic",
    };
}

fn backendVariant(execution_mode: []const u8) []const u8 {
    if (std.mem.eql(u8, execution_mode, "vm")) return "Vm";
    if (std.mem.eql(u8, execution_mode, "llvm") or std.mem.eql(u8, execution_mode, "llvm_native")) return "Llvm";
    if (std.mem.eql(u8, execution_mode, "hybrid")) return "Hybrid";
    if (std.mem.startsWith(u8, execution_mode, "wasm")) return "Wasm";
    return "Vm";
}

fn backendEnumVariant(backend: @import("platform_config.zig").Backend) []const u8 {
    return switch (backend) {
        .vm => "Vm",
        .llvm => "Llvm",
        .hybrid => "Hybrid",
    };
}

fn phaseVariant(phase: @import("tests_config.zig").TestPhase) []const u8 {
    return switch (phase) {
        .check => "Check",
        .run => "Run",
        .both => "Both",
    };
}

fn buildTargetVariant(build_target: []const u8) []const u8 {
    if (std.mem.eql(u8, build_target, "host")) return "Host";
    if (std.mem.startsWith(u8, build_target, "wasm")) return "Wasm";
    return "Host";
}

test "writes a round-trippable package.kira" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const manifest = ProjectManifest{
        .name = "DemoApp",
        .version = "0.1.0",
        .kira_version = "0.8.0",
        .kind = .app,
        .execution_mode = "hybrid",
        .build_target = "host",
        .assets = &.{ "assets", "assets\\quoted\"name\n" },
        .dependencies = &.{
            .{ .name = "Foundation", .source = .{ .registry = .{ .version = "0.1.0" } } },
            .{ .name = "Remote", .source = .{ .git = .{ .url = "https://example.com/remote.git", .rev = "abc123" } } },
        },
        .inline_native_libraries = &.{.{
            .name = "demo",
            .link_mode = .static,
            .abi = .c,
            .headers = .{ .include_dirs = &.{"include"}, .frameworks = &.{"Metal"}, .system_libs = &.{"m"} },
            .autobinding = .{
                .module_name = "demo",
                .output_path = "ignored.kira",
                .bindings = .{ .profile = .directx12 },
            },
            .build = .{
                .sources = &.{"NativeLibs/demo.c"},
                .include_dirs = &.{ "include", "src/native" },
                .defines = &.{"DEMO_BUILD=1"},
            },
            .targets = &.{ .{
                .selector = .{ .architecture = "x86_64", .operating_system = "linux", .abi = "gnu" },
                .static_lib = "../.kira-build/native/x86_64-linux-gnu/libdemo.a",
                .compiler_flags = &.{"-pthread"},
                .link = .{ .frameworks = &.{"AppKit"}, .system_libs = &.{"X11"} },
            }, .{
                .selector = .{ .architecture = "aarch64", .operating_system = "macos", .abi = "none" },
                .dynamic_lib = "",
            } },
        }},
    };

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeProjectManifestAsDeclaration(&output.writer, manifest);

    const text = output.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "Package DemoApp {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "let kira = \"0.8.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "profile: AutobindProfile.DirectX12") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "executionMode: Backend.Hybrid") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Dependency { name: \"Foundation\", version: \"0.1.0\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Dependency { name: \"Remote\", git: \"https://example.com/remote.git\", rev: \"abc123\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "NativeTarget { triple: \"x86_64-linux-gnu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"assets\\\\quoted\\\"name\\n\"") != null);

    // Reload it through the declaration loader for a true round trip.
    const loader = @import("declaration_loader.zig");
    const result = try loader.loadProjectManifestFromDeclaration(allocator, text, "package.kira");
    if (!result.ok()) {
        std.debug.print("generated declaration:\n{s}\n", .{text});
        for (result.diagnostics) |diagnostic| std.debug.print("{s}: {s}\n", .{ diagnostic.code orelse "diagnostic", diagnostic.message });
    }
    try std.testing.expect(result.ok());
    try std.testing.expectEqualStrings("DemoApp", result.manifest.name);
    try std.testing.expectEqualStrings("0.8.0", result.manifest.kira_version);
    try std.testing.expectEqualStrings("hybrid", result.manifest.execution_mode);
    try std.testing.expectEqual(@as(usize, 2), result.manifest.assets.len);
    try std.testing.expectEqualStrings("assets\\quoted\"name\n", result.manifest.assets[1]);
    try std.testing.expectEqual(@as(usize, 2), result.manifest.dependencies.len);
    const git_dep = result.manifest.dependencies[1].source.git;
    try std.testing.expectEqualStrings("https://example.com/remote.git", git_dep.url);
    try std.testing.expectEqualStrings("abc123", git_dep.rev.?);
    try std.testing.expect(std.mem.indexOf(u8, text, "includeDirs: [\"include\", \"src/native\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "defines: [\"DEMO_BUILD=1\"]") != null);
    const headers = result.manifest.inline_native_libraries[0].headers;
    try std.testing.expectEqualStrings("Metal", headers.frameworks[0]);
    try std.testing.expectEqualStrings("m", headers.system_libs[0]);
    const build = result.manifest.inline_native_libraries[0].build;
    try std.testing.expectEqual(@as(usize, 2), build.include_dirs.len);
    try std.testing.expectEqualStrings("src/native", build.include_dirs[1]);
    try std.testing.expectEqualStrings("DEMO_BUILD=1", build.defines[0]);
    try std.testing.expectEqual(native.AutobindingProfile.directx12, result.manifest.inline_native_libraries[0].autobinding.?.bindings.profile);
    const target = result.manifest.inline_native_libraries[0].targets[0];
    try std.testing.expectEqualStrings("linux", target.selector.operating_system);
    try std.testing.expectEqualStrings("-pthread", target.compiler_flags[0]);
    try std.testing.expectEqualStrings("AppKit", target.link.frameworks[0]);
    try std.testing.expectEqualStrings("X11", target.link.system_libs[0]);
    try std.testing.expectEqualStrings("../.kira-build/native/x86_64-linux-gnu/libdemo.a", target.static_lib.?);
    try std.testing.expect(target.dynamic_lib == null);
    const inproc_target = result.manifest.inline_native_libraries[0].targets[1];
    try std.testing.expectEqualStrings("", inproc_target.dynamic_lib.?);
    try std.testing.expect(inproc_target.static_lib == null);
}

test "migration sanitizes legacy package names into declaration identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = ProjectManifest{ .name = "backend-policy-app", .version = "0.1.0" };

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeProjectManifestAsDeclaration(&output.writer, manifest);

    const text = output.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "Package backend_policy_app {"));
    const loader = @import("declaration_loader.zig");
    const result = try loader.loadProjectManifestFromDeclaration(allocator, text, "package.kira");
    try std.testing.expect(result.ok());
    try std.testing.expectEqualStrings("backend_policy_app", result.manifest.name);
}
