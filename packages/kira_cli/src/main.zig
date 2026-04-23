const std = @import("std");
const app = @import("app.zig");
const support = @import("support.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const raw_args = init.args.toSlice(allocator) catch |err| {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(std.Options.debug_io, &stderr_buffer);
        defer stderr.interface.flush() catch {};
        try support.logInternalCompilerError(&stderr.interface, @errorName(err));
        try support.renderInternalCompilerError(&stderr.interface, @errorName(err));
        std.process.exit(1);
    };
    const args = try allocator.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, index| args[index] = arg;
    const exit_code = app.run(allocator, args) catch |err| {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(std.Options.debug_io, &stderr_buffer);
        defer stderr.interface.flush() catch {};
        try support.logInternalCompilerError(&stderr.interface, @errorName(err));
        try support.renderInternalCompilerError(&stderr.interface, @errorName(err));
        std.process.exit(1);
    };
    std.process.exit(exit_code);
}

test {
    _ = @import("app.zig");
}
