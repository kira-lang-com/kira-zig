//! Behavioral tests for `DebugSession` (Core Law #5 split: session.zig stays under
//! the size cap; the test double and cases live here). A scriptable fake
//! `DebugTarget` drives the session in isolation — no VM, no native process — so
//! the orchestration (arm/disarm, start-vs-continue, conditional auto-continue,
//! step delegation, id translation, and the DAP handler) is observable directly.
const std = @import("std");

const di = @import("debug_info.zig");
const target_mod = @import("target.zig");
const msg = @import("protocol/dap_messages.zig");
const session_mod = @import("session.zig");

const DebugTarget = target_mod.DebugTarget;
const StepKind = target_mod.StepKind;
const LocalView = di.LocalView;
const StopReason = di.StopReason;
const BreakpointSpec = di.BreakpointSpec;
const Frame = di.Frame;
const DebugSession = session_mod.DebugSession;

const testing = std.testing;

/// A scriptable `DebugTarget` for tests. It records arm/clear/step/continue calls
/// and returns pre-set stops, so session orchestration is observable without a VM.
const FakeTarget = struct {
    next_handle: u32 = 100,
    armed: [8]u32 = undefined,
    armed_len: usize = 0,
    cleared: [8]u32 = undefined,
    cleared_len: usize = 0,
    start_calls: u32 = 0,
    cont_calls: u32 = 0,
    last_step: ?StepKind = null,

    start_stop: StopReason = .entry,
    cont_stop: StopReason = .{ .exited = 0 },
    step_stop: StopReason = .step,
    locals_data: []const LocalView = &.{},

    const vt = DebugTarget.VTable{
        .start = fStart,
        .cont = fCont,
        .step = fStep,
        .setBreakpoint = fSet,
        .clearBreakpoint = fClear,
        .backtrace = fBacktrace,
        .locals = fLocals,
        .evaluate = fEvaluate,
        .readMemory = fReadMemory,
        .deinit = fDeinit,
    };

    fn debugTarget(self: *FakeTarget) DebugTarget {
        return .{ .ptr = self, .vtable = &vt };
    }

    fn as(ctx: *anyopaque) *FakeTarget {
        return @ptrCast(@alignCast(ctx));
    }

    fn fStart(ctx: *anyopaque) anyerror!StopReason {
        const self = as(ctx);
        self.start_calls += 1;
        return self.start_stop;
    }
    fn fCont(ctx: *anyopaque) anyerror!StopReason {
        const self = as(ctx);
        self.cont_calls += 1;
        return self.cont_stop;
    }
    fn fStep(ctx: *anyopaque, kind: StepKind) anyerror!StopReason {
        const self = as(ctx);
        self.last_step = kind;
        return self.step_stop;
    }
    fn fSet(ctx: *anyopaque, spec: BreakpointSpec) anyerror!u32 {
        _ = spec;
        const self = as(ctx);
        const h = self.next_handle;
        self.next_handle += 1;
        self.armed[self.armed_len] = h;
        self.armed_len += 1;
        return h;
    }
    fn fClear(ctx: *anyopaque, id: u32) anyerror!void {
        const self = as(ctx);
        self.cleared[self.cleared_len] = id;
        self.cleared_len += 1;
    }
    fn fBacktrace(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]Frame {
        _ = ctx;
        const frames = try allocator.alloc(Frame, 1);
        frames[0] = .{ .index = 0, .backend = .vm, .function_id = 0, .function_name = "main" };
        return frames;
    }
    fn fLocals(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32) anyerror![]LocalView {
        _ = frame_index;
        const self = as(ctx);
        return allocator.dupe(LocalView, self.locals_data);
    }
    fn fEvaluate(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) anyerror![]const u8 {
        _ = ctx;
        _ = frame_index;
        return allocator.dupe(u8, expr);
    }
    fn fReadMemory(ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void {
        _ = ctx;
        _ = addr;
        _ = buf;
        return error.Unsupported;
    }
    fn fDeinit(ctx: *anyopaque) void {
        _ = ctx;
    }
};

test "setBreakpoint stores the entry and arms it on the target" {
    var fake = FakeTarget{};
    var session = DebugSession.init(testing.allocator, fake.debugTarget());
    defer session.deinit();

    const id = try session.setBreakpoint(.{ .line = .{ .file = "main.kira", .line = 10 } }, null);
    try testing.expectEqual(@as(u32, 1), id);

    // Table recorded the entry and stamped the target's handle as its location.
    const entry = session.table.get(id).?;
    try testing.expectEqual(@as(u64, 100), entry.resolved_location.?);

    // Target was armed exactly once, with the handle it handed back.
    try testing.expectEqual(@as(usize, 1), fake.armed_len);
    try testing.expectEqual(@as(u32, 100), fake.armed[0]);
}

test "removeBreakpoint disarms the target and drops the entry" {
    var fake = FakeTarget{};
    var session = DebugSession.init(testing.allocator, fake.debugTarget());
    defer session.deinit();

    const id = try session.setBreakpoint(.{ .line = .{ .file = "m.kira", .line = 3 } }, null);
    try session.removeBreakpoint(id);

    try testing.expectEqual(@as(usize, 1), fake.cleared_len);
    try testing.expectEqual(@as(u32, 100), fake.cleared[0]);
    try testing.expect(session.table.get(id) == null);
    try testing.expectError(error.NotFound, session.removeBreakpoint(id));
}

test "run starts the target and returns the stop under the session id" {
    var fake = FakeTarget{};
    fake.start_stop = .{ .breakpoint = 100 };
    var session = DebugSession.init(testing.allocator, fake.debugTarget());
    defer session.deinit();

    const id = try session.setBreakpoint(.{ .line = .{ .file = "main.kira", .line = 4 } }, null);
    const stop = try session.run();

    try testing.expect(stop == .breakpoint);
    try testing.expectEqual(id, stop.breakpoint); // handle 100 -> session id 1
    try testing.expectEqual(@as(u32, 1), fake.start_calls);
    try testing.expectEqual(@as(u32, 0), fake.cont_calls);

    // The hit was counted on the owning entry.
    try testing.expectEqual(@as(u32, 1), session.table.get(id).?.hit_count);
}

test "run auto-continues a breakpoint whose condition is false" {
    var locals_arr = [_]LocalView{.{ .name = "i", .value = "3", .slot = 0 }};
    var fake = FakeTarget{};
    fake.locals_data = &locals_arr;
    fake.start_stop = .{ .breakpoint = 100 };
    fake.cont_stop = .{ .exited = 7 };
    var session = DebugSession.init(testing.allocator, fake.debugTarget());
    defer session.deinit();

    // i == 5 is false (i is 3): the session must not surface the breakpoint; it
    // continues, and the program exits.
    const id = try session.setBreakpoint(.{ .line = .{ .file = "main.kira", .line = 4 } }, "i == 5");
    const stop = try session.run();

    try testing.expect(stop == .exited);
    try testing.expectEqual(@as(i32, 7), stop.exited);
    try testing.expect(fake.cont_calls >= 1);
    // The location was still reached once (hit counted) even though we did not stop.
    try testing.expectEqual(@as(u32, 1), session.table.get(id).?.hit_count);
}

test "run stops on a breakpoint whose condition is true" {
    var locals_arr = [_]LocalView{.{ .name = "i", .value = "3", .slot = 0 }};
    var fake = FakeTarget{};
    fake.locals_data = &locals_arr;
    fake.start_stop = .{ .breakpoint = 100 };
    var session = DebugSession.init(testing.allocator, fake.debugTarget());
    defer session.deinit();

    const id = try session.setBreakpoint(.{ .line = .{ .file = "main.kira", .line = 4 } }, "i == 3");
    const stop = try session.run();

    try testing.expect(stop == .breakpoint);
    try testing.expectEqual(id, stop.breakpoint);
    try testing.expectEqual(@as(u32, 0), fake.cont_calls); // stopped, never continued
}

test "step delegates to the target and records the kind" {
    var fake = FakeTarget{};
    fake.step_stop = .step;
    var session = DebugSession.init(testing.allocator, fake.debugTarget());
    defer session.deinit();

    const stop = try session.step(.over);
    try testing.expect(stop == .step);
    try testing.expectEqual(StepKind.over, fake.last_step.?);
}

test "evaluate renders an expression over the frame's locals" {
    var locals_arr = [_]LocalView{
        .{ .name = "i", .value = "3", .slot = 0 },
        .{ .name = "n", .value = "20", .slot = 1 },
    };
    var fake = FakeTarget{};
    fake.locals_data = &locals_arr;
    var session = DebugSession.init(testing.allocator, fake.debugTarget());
    defer session.deinit();

    const rendered = try session.evaluate(0, "n - i");
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("17", rendered);
}

test "DapHandler delegates setBreakpoints, initialize, and continue to the session" {
    var fake = FakeTarget{};
    fake.start_stop = .{ .breakpoint = 100 };
    var session = DebugSession.init(testing.allocator, fake.debugTarget());
    defer session.deinit();

    const h = session.handler();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const caps = h.initialize();
    try testing.expect(caps.supportsConditionalBreakpoints);

    const inputs = [_]msg.SourceBreakpointInput{.{ .line = 10, .condition = "n > 0" }};
    const verified = try h.setBreakpoints(a, "main.kira", inputs[0..]);
    try testing.expectEqual(@as(usize, 1), verified.len);
    try testing.expect(verified[0].verified);
    try testing.expectEqualStrings("n > 0", session.table.get(verified[0].id).?.condition.?);

    // continue runs the target; the breakpoint's handle resolves to the same id.
    const stop = try h.cont();
    try testing.expect(stop == .breakpoint);
    try testing.expectEqual(verified[0].id, stop.breakpoint);
}

test "DapHandler setBreakpoints replaces the prior set for a file" {
    var fake = FakeTarget{};
    var session = DebugSession.init(testing.allocator, fake.debugTarget());
    defer session.deinit();

    const h = session.handler();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = [_]msg.SourceBreakpointInput{ .{ .line = 3 }, .{ .line = 9 } };
    _ = try h.setBreakpoints(a, "main.kira", first[0..]);
    try testing.expectEqual(@as(usize, 2), session.table.list().len);

    // A second call for the same file replaces, not appends.
    const second = [_]msg.SourceBreakpointInput{.{ .line = 5 }};
    const v2 = try h.setBreakpoints(a, "main.kira", second[0..]);
    try testing.expectEqual(@as(usize, 1), v2.len);
    try testing.expectEqual(@as(usize, 1), session.table.list().len);
    // Both prior breakpoints were disarmed on the target.
    try testing.expectEqual(@as(usize, 2), fake.cleared_len);
}
