const std = @import("std");
const cmd_run = @import("commands/run.zig");
const cmd_build = @import("commands/build.zig");
const cmd_check = @import("commands/check.zig");
const cmd_tokens = @import("commands/tokens.zig");
const cmd_ast = @import("commands/ast.zig");
const cmd_new = @import("commands/new.zig");
const cmd_sync = @import("commands/sync.zig");
const cmd_add = @import("commands/add.zig");
const cmd_remove = @import("commands/remove.zig");
const cmd_update = @import("commands/update.zig");
const cmd_package = @import("commands/package.zig");
const cmd_fetch_llvm = @import("commands/fetch_llvm.zig");
const cmd_shader = @import("commands/shader.zig");
const support = @import("support.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout.interface.flush() catch {};
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr.interface.flush() catch {};

    return runWithWriters(allocator, args, &stdout.interface, &stderr.interface);
}

pub fn runWithWriters(allocator: std.mem.Allocator, args: []const []const u8, out: anytype, err: anytype) !u8 {
    if (args.len < 2) {
        try printUsage(out);
        return 0;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        try printUsage(out);
        return 0;
    }
    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        try out.print("{s} {s}\n", .{ support.binaryName(), support.versionString() });
        return 0;
    }

    if (std.mem.eql(u8, command, "run")) return executeCommand(allocator, command, args[2..], out, err, cmd_run.execute);
    if (std.mem.eql(u8, command, "fetch-llvm")) return executeCommand(allocator, command, args[2..], out, err, cmd_fetch_llvm.execute);
    if (std.mem.eql(u8, command, "tokens")) return executeCommand(allocator, command, args[2..], out, err, cmd_tokens.execute);
    if (std.mem.eql(u8, command, "ast")) return executeCommand(allocator, command, args[2..], out, err, cmd_ast.execute);
    if (std.mem.eql(u8, command, "check")) return executeCommand(allocator, command, args[2..], out, err, cmd_check.execute);
    if (std.mem.eql(u8, command, "build")) return executeCommand(allocator, command, args[2..], out, err, cmd_build.execute);
    if (std.mem.eql(u8, command, "shader")) return executeCommand(allocator, command, args[2..], out, err, cmd_shader.execute);
    if (std.mem.eql(u8, command, "new")) return executeCommand(allocator, command, args[2..], out, err, cmd_new.execute);
    if (std.mem.eql(u8, command, "sync")) return executeCommand(allocator, command, args[2..], out, err, cmd_sync.execute);
    if (std.mem.eql(u8, command, "add")) return executeCommand(allocator, command, args[2..], out, err, cmd_add.execute);
    if (std.mem.eql(u8, command, "remove")) return executeCommand(allocator, command, args[2..], out, err, cmd_remove.execute);
    if (std.mem.eql(u8, command, "update")) return executeCommand(allocator, command, args[2..], out, err, cmd_update.execute);
    if (std.mem.eql(u8, command, "package")) return executeCommand(allocator, command, args[2..], out, err, cmd_package.execute);

    try err.print("unknown command: {s}\n\n", .{command});
    try printUsage(err);
    return 1;
}

fn executeCommand(allocator: std.mem.Allocator, _: []const u8, args: []const []const u8, out: anytype, err: anytype, comptime execute: anytype) !u8 {
    execute(allocator, args, out, err) catch |run_err| {
        if (run_err == error.CommandFailed or run_err == error.InvalidArguments) {
            if (run_err == error.InvalidArguments) try printUsage(err);
            return 1;
        }
        if (run_err == error.ProjectEntrypointNotFound) {
            try err.writeAll("error[KPROJECT001]: project entrypoint not found\n");
            try err.writeAll("  This project root does not contain `app/main.kira`, so it cannot be checked, built, or run as an application entrypoint yet.\n");
            try err.writeAll("  help: Point the command at an application package or source file with an @Main entrypoint. Library-root checking is not supported yet.\n");
            return 1;
        }
        if (run_err == error.UnsupportedTarget) {
            try err.writeAll("error[KBUILD002]: unsupported host target\n");
            try err.print(
                "  The current host target `{s}` is not supported by this project or one of its native libraries.\n",
                .{support.currentHostTargetTriple()},
            );
            try err.writeAll("  help: Add a matching [target.<triple>] section to the relevant NativeLibs manifest, or build on a supported host.\n");
            return 1;
        }
        if (run_err == error.NativeRunFailed) {
            try err.writeAll("error[KRUN001]: native executable failed\n");
            try err.writeAll("  Kira built the native executable, but it exited unsuccessfully while running.\n");
            try err.writeAll("  help: Re-run the generated executable directly to inspect the application/runtime failure.\n");
            return 1;
        }

        try support.logInternalCompilerError(err, @errorName(run_err));
        try support.renderInternalCompilerError(err, @errorName(run_err));
        return 1;
    };
    return 0;
}

fn printUsage(writer: anytype) !void {
    try writer.print(
        \\{s} <command> [args]
        \\  run [--backend vm|llvm|hybrid] [--offline] [--locked] [<project-dir|kira.toml|project.toml>]
        \\  build [--backend vm|llvm|hybrid] [--offline] [--locked] [<project-dir|kira.toml|project.toml>]
        \\  shader check <file.ksl>
        \\  shader ast <file.ksl>
        \\  shader build [<file.ksl>|Shaders] [--out-dir <dir>]
        \\  check [--offline] [--locked] [<project-dir|kira.toml|project.toml>]
        \\  tokens [<project-dir|kira.toml|project.toml>]
        \\  ast [<project-dir|kira.toml|project.toml>]
        \\  sync [--offline] [--locked] [<project-dir|kira.toml|project.toml>]
        \\  add <Package>
        \\  add --git <url> --rev <commit> <Package>
        \\  remove <Package>
        \\  update [<project-dir|kira.toml|project.toml>]
        \\  package pack [<project-dir|kira.toml|project.toml>]
        \\  package inspect <archive-path|project-dir>
        \\  new [--lib] <Name> <destination>
        \\  fetch-llvm
        \\  help
        \\  version
        \\  project layout: <root>/kira.toml or <root>/project.toml with entrypoint at <root>/app/main.kira
        \\  default project input: current directory
        \\  entrypoint syntax: @Main [@Runtime|@Native] function entry() {{ ... }}
        \\
        \\install:
        \\  zig build install-kirac
        \\  installs the active Kira toolchain under ~/.kira/toolchains/<channel>/<version>/
        \\  installs kira-bootstrapper into zig-out/bin/
        \\  writes ~/.kira/toolchain/current.toml so kira-bootstrapper can launch the active toolchain
        \\
    , .{support.binaryName()});
}

test "invalid Kira input exits cleanly with rendered diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("DemoApp/app");
    try tmp.dir.writeFile(.{
        .sub_path = "DemoApp/project.toml",
        .data = "[project]\n" ++
            "name = \"DemoApp\"\n" ++
            "version = \"0.1.0\"\n\n" ++
            "[defaults]\n" ++
            "execution_mode = \"vm\"\n" ++
            "build_target = \"host\"\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "DemoApp/app/main.kira",
        .data = "@Main\nfunction main() { let x = ; }\n",
    });
    const path = try tmp.dir.realpathAlloc(arena.allocator(), "DemoApp");

    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.io.fixedBufferStream(&stdout_buffer);
    var stderr = std.io.fixedBufferStream(&stderr_buffer);

    const exit_code = try runWithWriters(
        arena.allocator(),
        &.{ "kirac", "check", path },
        stdout.writer(),
        stderr.writer(),
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr.getWritten(), "error[KPAR002]: expected expression") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.getWritten(), "panic") == null);
}

test "invalid hybrid input exits cleanly without renderer crash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("DemoApp/app");
    try tmp.dir.writeFile(.{
        .sub_path = "DemoApp/project.toml",
        .data = "[project]\n" ++
            "name = \"DemoApp\"\n" ++
            "version = \"0.1.0\"\n\n" ++
            "[defaults]\n" ++
            "execution_mode = \"hybrid\"\n" ++
            "build_target = \"host\"\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "DemoApp/app/main.kira",
        .data = "@Main\n" ++
            "@Native\n" ++
            "function main() {\n" ++
            "    print(\"native main\");\n" ++
            "    runtime_helper(\n" ++
            "    return;\n" ++
            "}\n" ++
            "@Runtime\n" ++
            "function runtime_helper() {\n" ++
            "    return;\n" ++
            "}\n",
    });
    const path = try tmp.dir.realpathAlloc(arena.allocator(), "DemoApp");

    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.io.fixedBufferStream(&stdout_buffer);
    var stderr = std.io.fixedBufferStream(&stderr_buffer);

    const exit_code = try runWithWriters(
        arena.allocator(),
        &.{ "kirac", "run", "--backend", "hybrid", path },
        stdout.writer(),
        stderr.writer(),
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr.getWritten(), "error[KPAR002]: expected expression") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.getWritten(), "panic") == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.getWritten(), "Segmentation fault") == null);
}

test "version prints standalone binary identity" {
    var stdout_buffer: [128]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout = std.io.fixedBufferStream(&stdout_buffer);
    var stderr = std.io.fixedBufferStream(&stderr_buffer);

    const exit_code = try runWithWriters(
        std.testing.allocator,
        &.{ "kirac", "--version" },
        stdout.writer(),
        stderr.writer(),
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("kira-bootstrapper 0.1.0\n", stdout.getWritten());
    try std.testing.expectEqualStrings("", stderr.getWritten());
}

test "run defaults to project.toml in the current directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("DemoApp/app");
    try tmp.dir.writeFile(.{
        .sub_path = "DemoApp/project.toml",
        .data = "[project]\n" ++
            "name = \"DemoApp\"\n" ++
            "version = \"0.1.0\"\n\n" ++
            "[defaults]\n" ++
            "execution_mode = \"vm\"\n" ++
            "build_target = \"host\"\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "DemoApp/app/main.kira",
        .data = "@Main\nfunction main() { let x = ; }\n",
    });

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch {};
        original_cwd.close();
    }

    var app_dir = try tmp.dir.openDir("DemoApp", .{});
    defer app_dir.close();
    try app_dir.setAsCwd();

    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.io.fixedBufferStream(&stdout_buffer);
    var stderr = std.io.fixedBufferStream(&stderr_buffer);

    const exit_code = try runWithWriters(
        arena.allocator(),
        &.{ "kirac", "run" },
        stdout.writer(),
        stderr.writer(),
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr.getWritten(), "error[KPAR002]: expected expression") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.getWritten(), "invalid Kira input") == null);
}
