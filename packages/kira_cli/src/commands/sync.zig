const std = @import("std");
const package_support = @import("package_support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);
    const location = try package_support.loadManifestLocation(allocator, parsed.input_path);
    try package_support.syncAndRender(allocator, location.root_path, stdout, stderr, .{
        .offline = parsed.offline,
        .locked = parsed.locked,
    });
}

const ParsedArgs = struct {
    offline: bool = false,
    locked: bool = false,
    input_path: ?[]const u8 = null,
};

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var result = ParsedArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--offline")) {
            result.offline = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--locked")) {
            result.locked = true;
            continue;
        }
        if (result.input_path != null) return error.InvalidArguments;
        result.input_path = arg;
    }
    return result;
}
