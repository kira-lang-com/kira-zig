const std = @import("std");
const app = @import("app.zig");
const support = @import("support.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = std.process.argsAlloc(allocator) catch |err| {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&stderr_buffer);
        defer stderr.interface.flush() catch {};
        try support.logInternalCompilerError(&stderr.interface, @errorName(err));
        try support.renderInternalCompilerError(&stderr.interface, @errorName(err));
        std.process.exit(1);
    };
    const exit_code = app.run(allocator, args) catch |err| {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&stderr_buffer);
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
