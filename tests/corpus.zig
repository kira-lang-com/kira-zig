const std = @import("std");
const discovery = @import("discovery.zig");
const execute = @import("execute.zig");

test "repo corpus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const cases = try discovery.discoverCases(allocator);
    try std.testing.expect(cases.len > 0);
    var reporter = Reporter{};

    for (cases) |case| {
        execute.runCase(allocator, case, &reporter, .{}) catch {};
    }

    reporter.summary();
    try std.testing.expectEqual(@as(usize, 0), reporter.failed);
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
