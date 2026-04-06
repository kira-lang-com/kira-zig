const std = @import("std");
const cmd_run = @import("commands/run.zig");
const cmd_build = @import("commands/build.zig");
const cmd_check = @import("commands/check.zig");
const cmd_tokens = @import("commands/tokens.zig");
const cmd_ast = @import("commands/ast.zig");
const cmd_new = @import("commands/new.zig");
const cmd_fetch_llvm = @import("commands/fetch_llvm.zig");
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
    if (std.mem.eql(u8, command, "new")) return executeCommand(allocator, command, args[2..], out, err, cmd_new.execute);

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

        try support.logInternalCompilerError(err, @errorName(run_err));
        try support.renderInternalCompilerError(err, @errorName(run_err));
        return 1;
    };
    return 0;
}

fn printUsage(writer: anytype) !void {
    try writer.print(
        \\{s} <command> [args]
        \\  run [--backend vm|llvm|hybrid] <project-dir|project.toml>
        \\  build [--backend vm|llvm|hybrid] <project-dir|project.toml>
        \\  check <project-dir|project.toml>
        \\  tokens <project-dir|project.toml>
        \\  ast <project-dir|project.toml>
        \\  new <Name> <destination>
        \\  fetch-llvm
        \\  help
        \\  version
        \\  project layout: <root>/project.toml with entrypoint at <root>/app/main.kira
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
        .data =
            "[project]\n" ++
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
        .data =
            "[project]\n" ++
            "name = \"DemoApp\"\n" ++
            "version = \"0.1.0\"\n\n" ++
            "[defaults]\n" ++
            "execution_mode = \"hybrid\"\n" ++
            "build_target = \"host\"\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "DemoApp/app/main.kira",
        .data =
            "@Main\n" ++
            "@Native\n" ++
            "function main() {\n" ++
            "    print(\"native main\");\n" ++
            "    runtime_helper()\n" ++
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
    try std.testing.expect(std.mem.indexOf(u8, stderr.getWritten(), "error[KPAR001]: expected ';' after expression") != null);
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
