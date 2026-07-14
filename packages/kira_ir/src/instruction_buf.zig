const std = @import("std");
const ir = @import("ir.zig");
const source = @import("kira_source");

/// Drop-in replacement for `std.array_list.Managed(ir.Instruction)` used by the
/// HIR->low-IR lowerer. Every appended instruction is stamped with the source
/// span the lowerer is currently on, building a parallel `locations` array in
/// lock-step with `list`. This is the root of the debugger's source line table:
/// the lowerer already tracks `current_span` per statement/expression, and this
/// buffer captures it at each emit point without touching the ~226 append sites.
///
/// A span of `{ .start = 0, .end = 0 }` means "no known location" (matches the
/// existing convention for synthesized nodes); downstream line-table builders
/// skip those. `span_src` points at the lowerer's `current_span` field so the
/// most recently entered statement/expression wins at append time.
pub const InstructionBuf = struct {
    list: std.array_list.Managed(ir.Instruction),
    locs: std.array_list.Managed(source.Span),
    span_src: *const ?source.Span,

    /// A shared null span source for synthesized/generated instruction streams
    /// that have no lowerer (callbacks, async state-machine rewrites). Passing
    /// `&null_span` yields empty locations for those instructions.
    pub const null_span: ?source.Span = null;

    pub fn init(allocator: std.mem.Allocator, span_src: *const ?source.Span) InstructionBuf {
        return .{
            .list = std.array_list.Managed(ir.Instruction).init(allocator),
            .locs = std.array_list.Managed(source.Span).init(allocator),
            .span_src = span_src,
        };
    }

    pub fn deinit(self: *InstructionBuf) void {
        self.list.deinit();
        self.locs.deinit();
    }

    /// Mirrors `ArrayList.append`. Also records the current span so
    /// `locs.items[i]` is the location of `list.items[i]`.
    pub fn append(self: *InstructionBuf, instruction: ir.Instruction) !void {
        try self.list.append(instruction);
        try self.locs.append(self.span_src.* orelse .{ .start = 0, .end = 0 });
    }

    /// Transfers ownership of the instruction slice (mirrors `toOwnedSlice`).
    /// Callers building an `ir.Function` should pair this with
    /// `toOwnedLocations` so the two arrays stay index-aligned.
    pub fn toOwnedInstructions(self: *InstructionBuf) ![]ir.Instruction {
        return self.list.toOwnedSlice();
    }

    pub fn toOwnedLocations(self: *InstructionBuf) ![]const source.Span {
        return self.locs.toOwnedSlice();
    }
};

test "append records the current span index-aligned with the instruction" {
    var current: ?source.Span = null;
    var buf = InstructionBuf.init(std.testing.allocator, &current);
    defer buf.deinit();

    // No known location yet -> synthesized {0,0} sentinel.
    try buf.append(.{ .ret = .{ .src = null } });

    // Enter a statement span, then emit -> that span is captured.
    current = .{ .start = 12, .end = 34 };
    try buf.append(.{ .ret = .{ .src = null } });

    try std.testing.expectEqual(@as(usize, 2), buf.list.items.len);
    try std.testing.expectEqual(@as(usize, 2), buf.locs.items.len);
    try std.testing.expectEqual(@as(usize, 0), buf.locs.items[0].start);
    try std.testing.expectEqual(@as(usize, 0), buf.locs.items[0].end);
    try std.testing.expectEqual(@as(usize, 12), buf.locs.items[1].start);
    try std.testing.expectEqual(@as(usize, 34), buf.locs.items[1].end);
}
