const std = @import("std");
const native = @import("kira_native_lib_definition");
const NativeLibManifest = @import("native_lib_manifest.zig").NativeLibManifest;
const toml = @import("toml_text.zig");

/// Parser for per-library NativeLibs manifests (`NativeLibs/*.toml`). Extracted
/// from `parser.zig` (Core Law #5); the shared TOML text primitives live in
/// `toml_text.zig`.
pub fn parseNativeLibManifest(allocator: std.mem.Allocator, text: []const u8) !NativeLibManifest {
    var section: []const u8 = "";
    var target_name: ?[]const u8 = null;

    var library_name: []const u8 = "";
    var link_mode: native.LinkMode = .static;
    var abi: native.LibraryAbi = .c;
    var headers = native.HeaderSpec{};
    var autobinding_module_name: ?[]const u8 = null;
    var autobinding_output_path: ?[]const u8 = null;
    var autobinding_headers: []const []const u8 = &.{};
    var autobinding_bindings = native.AutobindingBindings{};
    var build = native.BuildRecipe{};
    var targets = std.array_list.Managed(native.TargetSpec).init(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = toml.trimComment(raw_line);
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = line[1 .. line.len - 1];
            if (std.mem.startsWith(u8, section, "target.")) {
                target_name = section["target.".len..];
                const selector = try native.TargetSelector.parse(allocator, target_name.?);
                try targets.append(.{ .selector = selector });
            } else {
                target_name = null;
            }
            continue;
        }

        if (std.mem.eql(u8, section, "library")) {
            if (toml.assignString(line, "name")) |value| library_name = try allocator.dupe(u8, value);
            if (toml.assignString(line, "link_mode")) |value| link_mode = parseLinkMode(value);
            if (toml.assignString(line, "abi")) |value| abi = parseAbi(value);
        } else if (std.mem.eql(u8, section, "headers")) {
            if (toml.assignString(line, "entrypoint")) |value| headers.entrypoint = try allocator.dupe(u8, value);
            if (std.mem.startsWith(u8, line, "include_dirs")) headers.include_dirs = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "defines")) headers.defines = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "frameworks")) headers.frameworks = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "system_libs")) headers.system_libs = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
        } else if (std.mem.eql(u8, section, "autobinding")) {
            if (toml.assignString(line, "module")) |value| autobinding_module_name = try allocator.dupe(u8, value);
            if (toml.assignString(line, "output")) |value| autobinding_output_path = try allocator.dupe(u8, value);
            if (std.mem.startsWith(u8, line, "headers")) autobinding_headers = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
        } else if (std.mem.eql(u8, section, "bindings")) {
            if (toml.assignString(line, "mode")) |value| {
                autobinding_bindings.mode = if (std.mem.eql(u8, value, "all_public")) .all_public else .listed;
            }
            if (toml.assignString(line, "profile")) |value| autobinding_bindings.profile = parseAutobindingProfile(value);
            if (std.mem.startsWith(u8, line, "functions")) autobinding_bindings.functions = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "structs")) autobinding_bindings.structs = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "callbacks")) autobinding_bindings.callbacks = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
        } else if (std.mem.eql(u8, section, "build")) {
            if (std.mem.startsWith(u8, line, "sources")) build.sources = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "include_dirs")) build.include_dirs = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "defines")) build.defines = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
        } else if (target_name != null and targets.items.len > 0) {
            var current = &targets.items[targets.items.len - 1];
            if (toml.assignString(line, "static_lib")) |value| current.static_lib = try allocator.dupe(u8, value);
            if (toml.assignString(line, "dynamic_lib")) |value| current.dynamic_lib = try allocator.dupe(u8, value);
            if (std.mem.startsWith(u8, line, "compiler_flags")) current.compiler_flags = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "linker_flags")) current.link.linker_flags = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "frameworks")) current.link.frameworks = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "system_libs")) current.link.system_libs = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "include_dirs")) current.link.include_dirs = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
            if (std.mem.startsWith(u8, line, "defines")) current.link.defines = try toml.parseStringArray(allocator, (try toml.splitKeyValue(line)).value);
        }
    }

    return .{
        .library = .{
            .name = library_name,
            .link_mode = link_mode,
            .abi = abi,
            .headers = headers,
            .autobinding = if (autobinding_module_name != null and autobinding_output_path != null) .{
                .module_name = autobinding_module_name.?,
                .output_path = autobinding_output_path.?,
                .headers = autobinding_headers,
                .bindings = autobinding_bindings,
            } else null,
            .build = build,
            .targets = try targets.toOwnedSlice(),
        },
    };
}

fn parseLinkMode(value: []const u8) native.LinkMode {
    if (std.mem.eql(u8, value, "dynamic")) return .dynamic;
    return .static;
}

fn parseAbi(value: []const u8) native.LibraryAbi {
    _ = value;
    return .c;
}

fn parseAutobindingProfile(value: []const u8) native.AutobindingProfile {
    if (std.mem.eql(u8, value, "vulkan")) return .vulkan;
    if (std.mem.eql(u8, value, "directx12")) return .directx12;
    return .generic;
}

test "parses native library manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const manifest = try parseNativeLibManifest(arena.allocator(),
        \\[library]
        \\name = "sokol_gfx"
        \\link_mode = "static"
        \\abi = "c"
        \\
        \\[headers]
        \\entrypoint = "vendor/sokol/sokol_gfx.h"
        \\include_dirs = ["vendor/sokol"]
        \\defines = ["SOKOL_DUMMY_BACKEND"]
        \\
        \\[autobinding]
        \\module = "sokol_gfx"
        \\output = "sokol_gfx.kira"
        \\headers = ["vendor/sokol/sokol_gfx.h"]
        \\
        \\[bindings]
        \\profile = "vulkan"
        \\functions = ["sg_setup"]
        \\structs = ["sg_desc"]
        \\
        \\[build]
        \\sources = ["vendor/sokol/sokol_gfx_impl.c"]
        \\defines = ["SOKOL_IMPL", "SOKOL_DUMMY_BACKEND"]
        \\
        \\[target.x86_64-linux-gnu]
        \\static_lib = ".kira-build/native/sokol_gfx/x86_64-linux-gnu/libsokol_gfx.a"
        \\frameworks = ["X11"]
    );

    try std.testing.expectEqualStrings("sokol_gfx", manifest.library.name);
    try std.testing.expectEqualStrings("vendor/sokol/sokol_gfx.h", manifest.library.headers.entrypoint.?);
    try std.testing.expectEqualStrings("sokol_gfx", manifest.library.autobinding.?.module_name);
    try std.testing.expectEqualStrings("vendor/sokol/sokol_gfx_impl.c", manifest.library.build.sources[0]);
    try std.testing.expectEqual(native.AutobindingProfile.vulkan, manifest.library.autobinding.?.bindings.profile);
    try std.testing.expectEqualStrings("sg_setup", manifest.library.autobinding.?.bindings.functions[0]);
    try std.testing.expectEqual(@as(usize, 1), manifest.library.targets.len);
    try std.testing.expectEqualStrings(".kira-build/native/sokol_gfx/x86_64-linux-gnu/libsokol_gfx.a", manifest.library.targets[0].static_lib.?);
}

test "parses native library target compiler and linker flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const manifest = try parseNativeLibManifest(arena.allocator(),
        \\[library]
        \\name = "webgpu_shim"
        \\link_mode = "static"
        \\abi = "c"
        \\
        \\[build]
        \\sources = ["src/webgpu_shim.c"]
        \\
        \\[target.wasm32-emscripten-unknown]
        \\static_lib = ".kira-build/native/webgpu_shim/wasm32-emscripten-unknown/libwebgpu_shim.a"
        \\compiler_flags = ["--use-port=emdawnwebgpu"]
        \\linker_flags = ["--use-port=emdawnwebgpu", "-sASYNCIFY"]
    );

    try std.testing.expectEqual(@as(usize, 1), manifest.library.targets.len);
    const target = manifest.library.targets[0];
    try std.testing.expectEqualStrings("wasm32", target.selector.architecture);
    try std.testing.expectEqualStrings("emscripten", target.selector.operating_system);
    try std.testing.expectEqualStrings("unknown", target.selector.abi);
    try std.testing.expectEqual(@as(usize, 1), target.compiler_flags.len);
    try std.testing.expectEqualStrings("--use-port=emdawnwebgpu", target.compiler_flags[0]);
    try std.testing.expectEqual(@as(usize, 2), target.link.linker_flags.len);
    try std.testing.expectEqualStrings("--use-port=emdawnwebgpu", target.link.linker_flags[0]);
    try std.testing.expectEqualStrings("-sASYNCIFY", target.link.linker_flags[1]);
}
