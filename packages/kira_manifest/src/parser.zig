const std = @import("std");
const native = @import("kira_native_lib_definition");
const ProjectManifest = @import("project_manifest.zig").ProjectManifest;
const PackageManifest = @import("package_manifest.zig").PackageManifest;
const NativeLibManifest = @import("native_lib_manifest.zig").NativeLibManifest;

pub fn parseProjectManifest(allocator: std.mem.Allocator, text: []const u8) !ProjectManifest {
    var name: []const u8 = "";
    var version: []const u8 = "0.1.0";
    var execution_mode: []const u8 = "vm";
    var build_target: []const u8 = "host";
    var packages = std.array_list.Managed([]const u8).init(allocator);
    var section: []const u8 = "";

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trimComment(raw_line);
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = line[1 .. line.len - 1];
            continue;
        }

        if (std.mem.eql(u8, section, "project")) {
            if (assignString(line, "name")) |value| name = try allocator.dupe(u8, value);
            if (assignString(line, "version")) |value| version = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, section, "defaults")) {
            if (assignString(line, "execution_mode")) |value| execution_mode = try allocator.dupe(u8, value);
            if (assignString(line, "build_target")) |value| build_target = try allocator.dupe(u8, value);
        } else if (std.mem.startsWith(u8, line, "packages")) {
            const values = try parseStringArray(allocator, line);
            for (values) |value| try packages.append(value);
        }
    }

    return .{
        .name = name,
        .version = version,
        .packages = try packages.toOwnedSlice(),
        .execution_mode = execution_mode,
        .build_target = build_target,
    };
}

pub fn parsePackageManifest(allocator: std.mem.Allocator, text: []const u8) !PackageManifest {
    var name: []const u8 = "";
    var version: []const u8 = "0.1.0";
    var dependencies = std.array_list.Managed([]const u8).init(allocator);
    var native_libs = std.array_list.Managed([]const u8).init(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trimComment(raw_line);
        if (line.len == 0) continue;
        if (assignString(line, "name")) |value| name = try allocator.dupe(u8, value);
        if (assignString(line, "version")) |value| version = try allocator.dupe(u8, value);
        if (std.mem.startsWith(u8, line, "dependencies")) {
            for (try parseStringArray(allocator, line)) |value| try dependencies.append(value);
        }
        if (std.mem.startsWith(u8, line, "native_libs")) {
            for (try parseStringArray(allocator, line)) |value| try native_libs.append(value);
        }
    }

    return .{
        .name = name,
        .version = version,
        .dependencies = try dependencies.toOwnedSlice(),
        .native_libs = try native_libs.toOwnedSlice(),
    };
}

pub fn parseNativeLibManifest(allocator: std.mem.Allocator, text: []const u8) !NativeLibManifest {
    var section: []const u8 = "";
    var target_name: ?[]const u8 = null;

    var library_name: []const u8 = "";
    var link_mode: native.LinkMode = .static;
    var abi: native.LibraryAbi = .c;
    var headers = native.LinkExtras{};
    var targets = std.array_list.Managed(native.TargetSpec).init(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trimComment(raw_line);
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
            if (assignString(line, "name")) |value| library_name = try allocator.dupe(u8, value);
            if (assignString(line, "link_mode")) |value| link_mode = parseLinkMode(value);
            if (assignString(line, "abi")) |value| abi = parseAbi(value);
        } else if (std.mem.eql(u8, section, "headers")) {
            if (std.mem.startsWith(u8, line, "include_dirs")) headers.include_dirs = try parseStringArray(allocator, line);
            if (std.mem.startsWith(u8, line, "defines")) headers.defines = try parseStringArray(allocator, line);
            if (std.mem.startsWith(u8, line, "frameworks")) headers.frameworks = try parseStringArray(allocator, line);
            if (std.mem.startsWith(u8, line, "system_libs")) headers.system_libs = try parseStringArray(allocator, line);
        } else if (target_name != null and targets.items.len > 0) {
            var current = &targets.items[targets.items.len - 1];
            if (assignString(line, "static_lib")) |value| current.static_lib = try allocator.dupe(u8, value);
            if (assignString(line, "dynamic_lib")) |value| current.dynamic_lib = try allocator.dupe(u8, value);
            if (std.mem.startsWith(u8, line, "frameworks")) current.link.frameworks = try parseStringArray(allocator, line);
            if (std.mem.startsWith(u8, line, "system_libs")) current.link.system_libs = try parseStringArray(allocator, line);
            if (std.mem.startsWith(u8, line, "include_dirs")) current.link.include_dirs = try parseStringArray(allocator, line);
            if (std.mem.startsWith(u8, line, "defines")) current.link.defines = try parseStringArray(allocator, line);
        }
    }

    return .{
        .library = .{
            .name = library_name,
            .link_mode = link_mode,
            .abi = abi,
            .headers = headers,
            .targets = try targets.toOwnedSlice(),
        },
    };
}

fn trimComment(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return "";
    return trimmed;
}

fn assignString(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    const equal_index = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return unquote(std.mem.trim(u8, line[equal_index + 1 ..], " \t"));
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn parseStringArray(allocator: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    const start = std.mem.indexOfScalar(u8, line, '[') orelse return error.InvalidManifest;
    const end = std.mem.lastIndexOfScalar(u8, line, ']') orelse return error.InvalidManifest;
    var items = std.array_list.Managed([]const u8).init(allocator);
    var parts = std.mem.splitScalar(u8, line[start + 1 .. end], ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try items.append(try allocator.dupe(u8, unquote(trimmed)));
    }
    return items.toOwnedSlice();
}

fn parseLinkMode(value: []const u8) native.LinkMode {
    if (std.mem.eql(u8, value, "dynamic")) return .dynamic;
    return .static;
}

fn parseAbi(value: []const u8) native.LibraryAbi {
    _ = value;
    return .c;
}

test "parses native library manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const manifest = try parseNativeLibManifest(arena.allocator(),
        \\[library]
        \\name = "glfw"
        \\link_mode = "static"
        \\abi = "c"
        \\
        \\[headers]
        \\include_dirs = ["include"]
        \\defines = ["GLFW_INCLUDE_NONE"]
        \\
        \\[target.x86_64-linux-gnu]
        \\static_lib = "vendor/glfw/linux/x86_64/libglfw3.a"
        \\frameworks = ["X11"]
    );

    try std.testing.expectEqualStrings("glfw", manifest.library.name);
    try std.testing.expectEqual(@as(usize, 1), manifest.library.targets.len);
    try std.testing.expectEqualStrings("vendor/glfw/linux/x86_64/libglfw3.a", manifest.library.targets[0].static_lib.?);
}
