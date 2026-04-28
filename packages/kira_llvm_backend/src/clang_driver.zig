const std = @import("std");
const builtin = @import("builtin");
const kira_toolchain = @import("kira_toolchain");

pub fn appendHostClangDriverArgs(
    allocator: std.mem.Allocator,
    argv: *std.array_list.Managed([]const u8),
) !void {
    const target = try hostClangTargetTriple(allocator);
    try argv.appendSlice(&.{ "-target", target });

    if (builtin.os.tag == .macos) {
        const sdk_path = try macOSSdkPath(allocator);
        try argv.appendSlice(&.{ "-isysroot", sdk_path });
    }
}

pub fn hostClangTargetTriple(allocator: std.mem.Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => allocator.dupe(u8, if (builtin.abi == .gnu) "x86_64-windows-gnu" else "x86_64-windows-msvc"),
            else => error.UnsupportedTarget,
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => allocator.dupe(u8, "arm64-apple-macosx"),
            .x86_64 => allocator.dupe(u8, "x86_64-apple-macosx"),
            else => error.UnsupportedTarget,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => allocator.dupe(u8, "x86_64-linux-gnu"),
            else => error.UnsupportedTarget,
        },
        else => error.UnsupportedTarget,
    };
}

pub fn macOSSdkPath(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag != .macos) return error.UnsupportedTarget;

    if (kira_toolchain.envVarOwned(allocator, "SDKROOT")) |sdkroot| {
        if (sdkroot.len != 0 and directoryExists(sdkroot)) return sdkroot;
        allocator.free(sdkroot);
    } else |_| {}

    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(allocator, io_impl.io(), .{
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) {
        const sdk_path = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (sdk_path.len != 0 and directoryExists(sdk_path)) {
            return allocator.dupe(u8, sdk_path);
        }
    }

    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    return error.MacOSSdkUnavailable;
}

fn directoryExists(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch
        std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}

fn inheritedProcessEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        .wasi, .emscripten, .freestanding, .other => .empty,
        else => .{ .block = .{ .slice = currentPosixEnvironBlock() } },
    };
}

fn currentPosixEnvironBlock() [:null]const ?[*:0]const u8 {
    if (!builtin.link_libc) return &.{};

    const environ = std.c.environ;
    var len: usize = 0;
    while (environ[len] != null) : (len += 1) {}
    return environ[0..len :null];
}
