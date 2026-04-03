const std = @import("std");
const kira_toolchain = @import("kira_toolchain");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    const current_path = try kira_toolchain.currentToolchainPath(allocator);
    const current_contents = std.fs.cwd().readFileAlloc(allocator, current_path, 4 * 1024) catch {
        try printMissingToolchain(current_path);
        std.process.exit(1);
    };

    const current = kira_toolchain.parseCurrentToolchainToml(allocator, current_contents) catch {
        try printBrokenToolchain(current_path);
        std.process.exit(1);
    };
    defer current.deinit(allocator);

    const executable_path = try kira_toolchain.managedPrimaryBinaryPath(
        allocator,
        current.channel,
        current.version,
        current.primary,
    );

    var child_args = try allocator.alloc([]const u8, args.len);
    child_args[0] = executable_path;
    for (args[1..], 1..) |arg, index| child_args[index] = arg;

    var child = std.process.Child.init(child_args, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch {
        try printMissingExecutable(executable_path);
        std.process.exit(1);
    };

    switch (term) {
        .Exited => |code| std.process.exit(code),
        .Signal => |signal| {
            std.debug.print("kira-bootstrapper: child terminated by signal {d}\n", .{signal});
            std.process.exit(1);
        },
        else => std.process.exit(1),
    }
}

fn printMissingToolchain(current_path: []const u8) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr.interface.flush() catch {};
    try stderr.interface.print(
        "kira-bootstrapper could not find {s}\nhelp: run `zig build install-kirac` to install a Kira toolchain and activate it\n",
        .{current_path},
    );
}

fn printBrokenToolchain(current_path: []const u8) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr.interface.flush() catch {};
    try stderr.interface.print(
        "kira-bootstrapper found an invalid toolchain manifest at {s}\nhelp: run `zig build install-kirac` to refresh the active toolchain\n",
        .{current_path},
    );
}

fn printMissingExecutable(executable_path: []const u8) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr.interface.flush() catch {};
    try stderr.interface.print(
        "kira-bootstrapper could not launch the active Kira executable at {s}\nhelp: run `zig build install-kirac` to reinstall the active toolchain\n",
        .{executable_path},
    );
}
