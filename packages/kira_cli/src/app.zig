const std = @import("std");
const cmd_run = @import("commands/run.zig");
const cmd_build = @import("commands/build.zig");
const cmd_check = @import("commands/check.zig");
const cmd_tokens = @import("commands/tokens.zig");
const cmd_ast = @import("commands/ast.zig");
const cmd_new = @import("commands/new.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout.interface.flush() catch {};
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr.interface.flush() catch {};
    const out = &stdout.interface;
    const err = &stderr.interface;

    if (args.len < 2) {
        try printUsage(out);
        return 0;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "run")) {
        try cmd_run.execute(allocator, args[2..], out, err);
        return 0;
    }
    if (std.mem.eql(u8, command, "tokens")) {
        try cmd_tokens.execute(allocator, args[2..], out, err);
        return 0;
    }
    if (std.mem.eql(u8, command, "ast")) {
        try cmd_ast.execute(allocator, args[2..], out, err);
        return 0;
    }
    if (std.mem.eql(u8, command, "check")) {
        try cmd_check.execute(allocator, args[2..], out, err);
        return 0;
    }
    if (std.mem.eql(u8, command, "build")) {
        try cmd_build.execute(allocator, args[2..], out, err);
        return 0;
    }
    if (std.mem.eql(u8, command, "new")) {
        try cmd_new.execute(allocator, args[2..], out, err);
        return 0;
    }

    try err.print("unknown command: {s}\n\n", .{command});
    try printUsage(err);
    return 1;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\kira <command> [args]
        \\  run [--backend vm|llvm|hybrid] <file.kira>
        \\  tokens <file.kira>
        \\  ast <file.kira>
        \\  check <file.kira>
        \\  build [--backend vm|llvm|hybrid] <file.kira>
        \\  new <Name> <destination>
        \\  entrypoint syntax: @Main [@Runtime|@Native] function main() { ... }
        \\
    );
}
