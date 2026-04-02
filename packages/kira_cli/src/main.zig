const std = @import("std");
const app = @import("app.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    const exit_code = try app.run(allocator, args);
    std.process.exit(exit_code);
}
