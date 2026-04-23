const std = @import("std");
const discovery = @import("discovery.zig");
const execute = @import("execute.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const raw_args = try init.args.toSlice(allocator);
    const args = try allocator.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, index| args[index] = arg;
    if (args.len != 2) return error.InvalidArguments;

    const cases = try discovery.discoverCases(allocator);
    if (cases.len == 0) return error.NoCorpusCases;

    var reporter = Reporter{};
    for (cases) |case| {
        execute.runCase(allocator, case, &reporter, .{
            .hybrid_runner_path = args[1],
        }) catch {};
    }

    reporter.summary();
    if (reporter.failed != 0) return error.CorpusFailures;
}

const Reporter = struct {
    passed: usize = 0,
    failed: usize = 0,

    pub fn pass(self: *Reporter, label: []const u8) void {
        self.passed += 1;
        std.debug.print("PASS {s}\n", .{label});
    }

    pub fn fail(self: *Reporter, label: []const u8, err: anyerror) void {
        self.failed += 1;
        std.debug.print("FAIL {s}: {s}\n", .{ label, @errorName(err) });
    }

    pub fn summary(self: *Reporter) void {
        std.debug.print("Corpus summary: {d} passed, {d} failed\n", .{ self.passed, self.failed });
    }
};
