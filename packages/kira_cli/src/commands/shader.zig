const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");
const syntax = @import("kira_ksl_syntax_model");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len < 1) return error.InvalidArguments;
    const subcommand = args[0];
    if (std.mem.eql(u8, subcommand, "check")) return executeCheck(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, subcommand, "ast")) return executeAst(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, subcommand, "build")) return executeBuild(allocator, args[1..], stdout, stderr);
    return error.InvalidArguments;
}

fn executeCheck(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len != 1) return error.InvalidArguments;
    const path = args[0];
    try support.logFrontendStarted(stderr, "shader-check", path);
    const result = try build.checkShaderFile(allocator, path);
    if (result.program == null or diagnostics.hasErrors(result.diagnostics)) {
        try support.logFrontendFailed(stderr, null, path, result.diagnostics.len);
        try support.renderDiagnostics(stderr, &result.source, result.diagnostics);
        return error.CommandFailed;
    }
    try stdout.writeAll("shader check passed\n");
}

fn executeAst(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len != 1) return error.InvalidArguments;
    const path = args[0];
    try support.logFrontendStarted(stderr, "shader-ast", path);
    const result = try build.parseShaderFile(allocator, path);
    if (result.module == null or diagnostics.hasErrors(result.diagnostics)) {
        try support.logFrontendFailed(stderr, null, path, result.diagnostics.len);
        try support.renderDiagnostics(stderr, &result.source, result.diagnostics);
        return error.CommandFailed;
    }
    try syntax.ast.dumpModule(stdout, result.module.?);
}

fn executeBuild(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len > 3) return error.InvalidArguments;
    const parsed = try parseBuildArgs(args);
    const resolved = try resolveBuildInputs(allocator, parsed, stderr);
    try std.fs.cwd().makePath(resolved.output_dir);
    var artifact_sets_written: usize = 0;

    for (resolved.paths) |path| {
        try support.logFrontendStarted(stderr, "shader-build", path);
        const result = try build.buildShaderFile(allocator, path);
        if (result.program == null or diagnostics.hasErrors(result.diagnostics)) {
            try support.logFrontendFailed(stderr, null, path, result.diagnostics.len);
            try support.renderDiagnostics(stderr, &result.source, result.diagnostics);
            return error.CommandFailed;
        }

        for (result.artifacts) |artifact| {
            if (artifact.vertex_glsl) |vertex_glsl| {
                try writeTextFile(allocator, resolved.output_dir, try std.fmt.allocPrint(allocator, "{s}.vert.glsl", .{artifact.shader_name}), vertex_glsl);
            }
            if (artifact.fragment_glsl) |fragment_glsl| {
                try writeTextFile(allocator, resolved.output_dir, try std.fmt.allocPrint(allocator, "{s}.frag.glsl", .{artifact.shader_name}), fragment_glsl);
            }
            try writeTextFile(allocator, resolved.output_dir, try std.fmt.allocPrint(allocator, "{s}.reflection.json", .{artifact.shader_name}), artifact.reflection_json);
            artifact_sets_written += 1;
        }
    }

    try stdout.print("shader build wrote {d} artifact set(s) from {d} shader file(s) to {s}\n", .{ artifact_sets_written, resolved.paths.len, resolved.output_dir });
}

const BuildArgs = struct {
    path: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
};

const ResolvedBuildInputs = struct {
    paths: []const []const u8,
    output_dir: []const u8,
};

fn parseBuildArgs(args: []const []const u8) !BuildArgs {
    var output_dir: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--out-dir")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            output_dir = args[index];
            continue;
        }
        if (path != null) return error.InvalidArguments;
        path = arg;
    }
    return .{ .path = path, .output_dir = output_dir };
}

fn defaultOutputDir(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, "generated", "shaders" });
}

fn resolveBuildInputs(allocator: std.mem.Allocator, parsed: BuildArgs, stderr: anytype) !ResolvedBuildInputs {
    if (parsed.path) |path| {
        if (directoryExists(path)) {
            const discovered = try discoverShaderFilesInDir(allocator, path, false, stderr);
            const output_dir = parsed.output_dir orelse try defaultOutputDirForDirectory(allocator, path);
            return .{ .paths = discovered, .output_dir = output_dir };
        }
        const output_dir = parsed.output_dir orelse try defaultOutputDir(allocator, path);
        const single = try allocator.alloc([]const u8, 1);
        single[0] = path;
        return .{ .paths = single, .output_dir = output_dir };
    }

    if (!directoryExists("Shaders")) {
        try stderr.writeAll("shader build without an explicit path expects a Shaders/ directory in the current project root\n");
        return error.CommandFailed;
    }

    return .{
        .paths = try discoverShaderFilesInDir(allocator, "Shaders", true, stderr),
        .output_dir = parsed.output_dir orelse try allocator.dupe(u8, "generated/Shaders"),
    };
}

fn defaultOutputDirForDirectory(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "Shaders")) {
        const parent = std.fs.path.dirname(path) orelse ".";
        return std.fs.path.join(allocator, &.{ parent, "generated", "Shaders" });
    }
    return std.fs.path.join(allocator, &.{ path, "generated", "shaders" });
}

fn discoverShaderFilesInDir(allocator: std.mem.Allocator, dir_path: []const u8, enforce_pascal: bool, stderr: anytype) ![]const []const u8 {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var paths = std.array_list.Managed([]const u8).init(allocator);
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ksl")) continue;

        const stem = entry.name[0 .. entry.name.len - 4];
        if (enforce_pascal and !isPascalCase(stem)) {
            try stderr.print("shader build expected PascalCase shader entry files in Shaders/, but found {s}\n", .{entry.name});
            return error.CommandFailed;
        }

        try paths.append(try std.fs.path.join(allocator, &.{ dir_path, entry.name }));
    }

    if (paths.items.len == 0) {
        try stderr.print("shader build found no .ksl entry shaders in {s}\n", .{dir_path});
        return error.CommandFailed;
    }

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return try paths.toOwnedSlice();
}

fn isPascalCase(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(name[0] >= 'A' and name[0] <= 'Z')) return false;
    for (name) |char| {
        if (char == '_' or char == '-') return false;
    }
    return true;
}

fn directoryExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    defer dir.close();
    return true;
}

fn writeTextFile(allocator: std.mem.Allocator, output_dir: []const u8, file_name: []const u8, text: []const u8) !void {
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ output_dir, file_name });
    defer allocator.free(path);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(text);
}

test "shader check command succeeds for a valid shader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    var stdout = std.io.fixedBufferStream(&stdout_buffer);
    var stderr = std.io.fixedBufferStream(&stderr_buffer);

    try execute(arena.allocator(), &.{ "check", "examples/shaders/textured_quad.ksl" }, stdout.writer(), stderr.writer());
    try std.testing.expect(std.mem.indexOf(u8, stdout.getWritten(), "shader check passed") != null);
}

test "shader ast command prints shader declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var stdout_buffer: [2048]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    var stdout = std.io.fixedBufferStream(&stdout_buffer);
    var stderr = std.io.fixedBufferStream(&stderr_buffer);

    try execute(arena.allocator(), &.{ "ast", "examples/shaders/textured_quad.ksl" }, stdout.writer(), stderr.writer());
    try std.testing.expect(std.mem.indexOf(u8, stdout.getWritten(), "shader TexturedQuad") != null);
}

test "shader build command writes artifacts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try tmp.dir.realpathAlloc(allocator, ".");

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    var stdout = std.io.fixedBufferStream(&stdout_buffer);
    var stderr = std.io.fixedBufferStream(&stderr_buffer);

    try execute(allocator, &.{ "build", "examples/shaders/textured_quad.ksl", "--out-dir", out_dir }, stdout.writer(), stderr.writer());

    try std.testing.expect(fileExists(out_dir, "TexturedQuad.vert.glsl"));
    try std.testing.expect(fileExists(out_dir, "TexturedQuad.frag.glsl"));
    try std.testing.expect(fileExists(out_dir, "TexturedQuad.reflection.json"));
}

test "shader build discovers PascalCase entry shaders in Shaders directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("DemoApp/Shaders");
    try tmp.dir.writeFile(.{
        .sub_path = "DemoApp/Shaders/BasicTriangle.ksl",
        .data =
        \\type VertexIn { let position: Float2 }
        \\type VertexOut { @builtin(position) let clip_position: Float4 }
        \\type FragmentOut { let color: Float4 }
        \\shader BasicTriangle {
        \\    vertex {
        \\        input VertexIn
        \\        output VertexOut
        \\        function entry(input: VertexIn) -> VertexOut {
        \\            let out: VertexOut
        \\            out.clip_position = Float4(input.position, 0.0, 1.0)
        \\            return out
        \\        }
        \\    }
        \\    fragment {
        \\        input VertexOut
        \\        output FragmentOut
        \\        function entry(input: VertexOut) -> FragmentOut {
        \\            let out: FragmentOut
        \\            out.color = Float4(1.0, 0.25, 0.25, 1.0)
        \\            return out
        \\        }
        \\    }
        \\}
        ,
    });

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch {};
        original_cwd.close();
    }
    var app_dir = try tmp.dir.openDir("DemoApp", .{});
    defer app_dir.close();
    try app_dir.setAsCwd();

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    var stdout = std.io.fixedBufferStream(&stdout_buffer);
    var stderr = std.io.fixedBufferStream(&stderr_buffer);

    try execute(arena.allocator(), &.{"build"}, stdout.writer(), stderr.writer());

    try std.testing.expect(fileExists("generated/Shaders", "BasicTriangle.vert.glsl"));
    try std.testing.expect(fileExists("generated/Shaders", "BasicTriangle.frag.glsl"));
    try std.testing.expect(fileExists("generated/Shaders", "BasicTriangle.reflection.json"));
}

test "shader build rejects non-PascalCase shader entry files in Shaders directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("DemoApp/Shaders");
    try tmp.dir.writeFile(.{
        .sub_path = "DemoApp/Shaders/basic_triangle.ksl",
        .data = "shader Broken {}",
    });

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch {};
        original_cwd.close();
    }
    var app_dir = try tmp.dir.openDir("DemoApp", .{});
    defer app_dir.close();
    try app_dir.setAsCwd();

    var stdout_buffer: [128]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    var stdout = std.io.fixedBufferStream(&stdout_buffer);
    var stderr = std.io.fixedBufferStream(&stderr_buffer);

    try std.testing.expectError(error.CommandFailed, execute(arena.allocator(), &.{"build"}, stdout.writer(), stderr.writer()));
    try std.testing.expect(std.mem.indexOf(u8, stderr.getWritten(), "PascalCase") != null);
}

fn fileExists(dir_path: []const u8, file_name: []const u8) bool {
    const full_path = std.fs.path.join(std.testing.allocator, &.{ dir_path, file_name }) catch return false;
    defer std.testing.allocator.free(full_path);
    std.fs.cwd().access(full_path, .{}) catch return false;
    return true;
}
