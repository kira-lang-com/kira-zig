const std = @import("std");
const hybrid_runtime = @import("kira_hybrid_runtime");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len != 2) return error.InvalidArguments;

    const manifest = try hybrid_runtime.loadHybridModule(allocator, args[1]);
    var runtime = try hybrid_runtime.HybridRuntime.init(allocator, manifest);
    defer runtime.deinit();
    try runtime.run();
}
