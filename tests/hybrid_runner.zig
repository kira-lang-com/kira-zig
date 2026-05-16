const std = @import("std");
const hybrid_runtime = @import("kira_hybrid_runtime");
const runtime_abi = @import("kira_runtime_abi");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const raw_args = try init.args.toSlice(allocator);
    const args = try allocator.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, index| args[index] = arg;
    if (args.len != 2) return error.InvalidArguments;

    if (std.c.getenv("KIRA_TRACE_EXECUTION")) |value| {
        runtime_abi.setExecutionTraceEnabled(value[0] != 0 and value[0] != '0');
    }

    const manifest = try hybrid_runtime.loadHybridModule(allocator, args[1]);
    var runtime = try hybrid_runtime.HybridRuntime.init(allocator, manifest);
    defer runtime.deinit();
    try runtime.run();
}
