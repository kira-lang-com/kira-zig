const std = @import("std");
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
    try writer.print("Package {s} {{\n", .{packageName(manifest.name)});
    try writer.print("    let version = \"{s}\"\n", .{manifest.version});
    try writer.print("    let kind = PackageKind.{s}\n", .{kindVariant(manifest.kind)});
    if (manifest.module_root) |root| {
        try writer.print("    let moduleRoot = \"{s}\"\n", .{root});
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

    if (manifest.dependencies.len > 0) {
        try writer.writeAll("    let dependencies = [\n");
        for (manifest.dependencies) |dep| {
            try writer.print("        Dependency {{ name: \"{s}\"", .{dep.name});
            switch (dep.source) {
                .registry => |r| try writer.print(", version: \"{s}\"", .{r.version}),
                .path => |p| try writer.print(", path: \"{s}\"", .{p.path}),
                .git => |g| try writer.print(", version: \"{s}\"", .{g.url}),
            }
            try writer.writeAll(" }\n");
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
    try writer.print("            name: \"{s}\",\n", .{lib.name});
    try writer.print("            linkMode: LinkMode.{s},\n", .{linkModeVariant(lib.link_mode)});
    try writeHeaders(writer, lib.headers);
    if (lib.build.sources.len > 0) {
        try writer.writeAll("            sources: ");
        try writeStringArray(writer, lib.build.sources);
        try writer.writeAll(",\n");
    }
    if (lib.autobinding) |auto| {
        try writeAutobind(writer, auto);
    }
    try writer.writeAll("        }");
}

fn writeHeaders(writer: anytype, headers: native.HeaderSpec) !void {
    if (headers.entrypoint == null and headers.include_dirs.len == 0 and headers.defines.len == 0) return;
    try writer.writeAll("            headers: Headers {");
    var first = true;
    if (headers.entrypoint) |entry| {
        try writer.print(" entrypoint: \"{s}\"", .{entry});
        first = false;
    }
    if (headers.include_dirs.len > 0) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll(" includeDirs: ");
        try writeStringArray(writer, headers.include_dirs);
        first = false;
    }
    if (headers.defines.len > 0) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll(" defines: ");
        try writeStringArray(writer, headers.defines);
    }
    try writer.writeAll(" },\n");
}

fn writeAutobind(writer: anytype, auto: native.AutobindingSpec) !void {
    try writer.print("            autobind: Autobind {{ module: \"{s}\"", .{auto.module_name});
    if (auto.bindings.mode == .all_public) {
        try writer.writeAll(", mode: AutobindMode.AllPublic");
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

fn writeStringArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeAll("[");
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("\"{s}\"", .{value});
    }
    try writer.writeAll("]");
}

fn packageName(name: []const u8) []const u8 {
    if (name.len == 0) return "Package";
    return name;
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
        .kind = .app,
        .execution_mode = "hybrid",
        .build_target = "host",
        .dependencies = &.{
            .{ .name = "Foundation", .source = .{ .registry = .{ .version = "0.1.0" } } },
        },
    };

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeProjectManifestAsDeclaration(&output.writer, manifest);

    const text = output.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "Package DemoApp {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "executionMode: Backend.Hybrid") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Dependency { name: \"Foundation\", version: \"0.1.0\" }") != null);

    // Reload it through the declaration loader for a true round trip.
    const loader = @import("declaration_loader.zig");
    const result = try loader.loadProjectManifestFromDeclaration(allocator, text, "package.kira");
    try std.testing.expect(result.ok());
    try std.testing.expectEqualStrings("DemoApp", result.manifest.name);
    try std.testing.expectEqualStrings("hybrid", result.manifest.execution_mode);
    try std.testing.expectEqual(@as(usize, 1), result.manifest.dependencies.len);
}
