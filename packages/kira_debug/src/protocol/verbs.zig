//! The debug command/event vocabulary — a pure message model, no transport.
//!
//! A debug session consumes `DebugRequest`s (drive commands from a client: an IDE,
//! the REPL, or a DAP adapter) and emits `DebugEvent`s (state changes the client
//! reacts to). This file describes *what* those messages are, not how they travel:
//! a later transport (kira_live's framed TCP) frames and carries them, and
//! `dap.zig` maps them to/from the Debug Adapter Protocol wire form. Keeping the
//! vocabulary dependency-light (only the shared `debug_info`/`target` contract
//! types) lets both the session core and the adapter agree on one model without a
//! cycle through the transport.
const std = @import("std");
const di = @import("../debug_info.zig");
const tgt = @import("../target.zig");

/// Stable numeric tag for each request variant. Explicit `enum(u32)` values so a
/// transport/adapter can dispatch on a wire number (mirrors `LiveMessageKind`).
pub const RequestKind = enum(u32) {
    set_breakpoint = 1,
    remove_breakpoint = 2,
    cont = 3,
    step = 4,
    pause = 5,
    backtrace = 6,
    locals = 7,
    evaluate = 8,
    disconnect = 9,
};

/// Stable numeric tag for each event variant.
pub const EventKind = enum(u32) {
    stopped = 1,
    continued = 2,
    exited = 3,
    output = 4,
    breakpoint_resolved = 5,
};

/// Ask to plant a source-line breakpoint. `condition` is an optional expression
/// evaluated at the stop site; empty means unconditional. The session resolves the
/// (file,line) to a concrete backend location when it arms the breakpoint and
/// answers with a `breakpoint_resolved` event carrying the assigned id/location.
pub const SetBreakpoint = struct {
    file: []const u8,
    line: u32,
    condition: []const u8 = "",
};

/// Drop a previously-planted breakpoint by the id the session assigned it.
pub const RemoveBreakpoint = struct {
    id: u32,
};

/// Single-step request, carrying the granularity (`into`/`over`/`out`/instruction).
pub const Step = struct {
    kind: tgt.StepKind,
};

/// Read the locals/params of one call frame (0 = innermost/current frame).
pub const Locals = struct {
    frame: u32,
};

/// Evaluate an expression in the context of a call frame (0 = innermost). The
/// session answers out-of-band (REPL reply / DAP response), not with a DebugEvent.
pub const Evaluate = struct {
    frame: u32,
    expr: []const u8,
};

/// A command a client sends the session. Variants with no payload (`cont`,
/// `pause`, `backtrace`, `disconnect`) are void tags.
pub const DebugRequest = union(RequestKind) {
    /// Plant a conditional/unconditional source-line breakpoint.
    set_breakpoint: SetBreakpoint,
    /// Remove a breakpoint by id.
    remove_breakpoint: RemoveBreakpoint,
    /// Resume execution until the next stop.
    cont,
    /// Step by the given granularity.
    step: Step,
    /// Request the target halt at the next safe point.
    pause,
    /// Ask for the current call stack (answered out-of-band with `[]di.Frame`).
    backtrace,
    /// Ask for a frame's locals (answered out-of-band with `[]di.LocalView`).
    locals: Locals,
    /// Evaluate an expression in a frame (answered out-of-band).
    evaluate: Evaluate,
    /// End the debug session; the target detaches/continues per its policy.
    disconnect,

    /// The wire tag of this request.
    pub fn kind(self: DebugRequest) RequestKind {
        return std.meta.activeTag(self);
    }
};

/// The target stopped. `reason` is the shared `StopReason`; `thread` identifies
/// which execution context halted (0 for single-threaded/main; hybrid sessions may
/// carry distinct ids for the VM vs. native side).
pub const Stopped = struct {
    reason: di.StopReason,
    thread: u32 = 0,
};

/// The target exited with a process/return code.
pub const Exited = struct {
    code: i32,
};

/// Program/diagnostic output the client should surface (stdout/stderr/log text).
pub const Output = struct {
    text: []const u8,
};

/// A pending breakpoint was bound to a concrete source location. Emitted after a
/// `set_breakpoint` request resolves, carrying the id the session assigned and the
/// resolved position the client should mark in the gutter.
pub const BreakpointResolved = struct {
    id: u32,
    location: di.SourcePosition,
};

/// A state change the session emits to clients.
pub const DebugEvent = union(EventKind) {
    /// The target halted; carries why and on which thread.
    stopped: Stopped,
    /// The target resumed after a `cont`/`step`.
    continued,
    /// The target exited with a code.
    exited: Exited,
    /// Program or diagnostic text to display.
    output: Output,
    /// A breakpoint bound to a concrete location.
    breakpoint_resolved: BreakpointResolved,

    /// The wire tag of this event.
    pub fn kind(self: DebugEvent) EventKind {
        return std.meta.activeTag(self);
    }
};

test "DebugRequest: every variant constructs and tags correctly" {
    const set: DebugRequest = .{ .set_breakpoint = .{ .file = "main.kira", .line = 12, .condition = "x > 3" } };
    try std.testing.expectEqual(RequestKind.set_breakpoint, set.kind());
    try std.testing.expectEqualStrings("main.kira", set.set_breakpoint.file);
    try std.testing.expectEqualStrings("x > 3", set.set_breakpoint.condition);

    const rm: DebugRequest = .{ .remove_breakpoint = .{ .id = 7 } };
    try std.testing.expectEqual(RequestKind.remove_breakpoint, rm.kind());
    try std.testing.expectEqual(@as(u32, 7), rm.remove_breakpoint.id);

    const go: DebugRequest = .cont;
    try std.testing.expectEqual(RequestKind.cont, go.kind());

    const st: DebugRequest = .{ .step = .{ .kind = .over } };
    try std.testing.expectEqual(RequestKind.step, st.kind());
    try std.testing.expectEqual(tgt.StepKind.over, st.step.kind);

    const ps: DebugRequest = .pause;
    try std.testing.expectEqual(RequestKind.pause, ps.kind());

    const bt: DebugRequest = .backtrace;
    try std.testing.expectEqual(RequestKind.backtrace, bt.kind());

    const lc: DebugRequest = .{ .locals = .{ .frame = 2 } };
    try std.testing.expectEqual(RequestKind.locals, lc.kind());
    try std.testing.expectEqual(@as(u32, 2), lc.locals.frame);

    const ev: DebugRequest = .{ .evaluate = .{ .frame = 0, .expr = "self.count" } };
    try std.testing.expectEqual(RequestKind.evaluate, ev.kind());
    try std.testing.expectEqualStrings("self.count", ev.evaluate.expr);

    const dc: DebugRequest = .disconnect;
    try std.testing.expectEqual(RequestKind.disconnect, dc.kind());
}

test "DebugRequest: default condition is empty (unconditional)" {
    const set: DebugRequest = .{ .set_breakpoint = .{ .file = "a.kira", .line = 1 } };
    try std.testing.expectEqualStrings("", set.set_breakpoint.condition);
}

test "DebugEvent: every variant constructs and tags correctly" {
    const stopped: DebugEvent = .{ .stopped = .{ .reason = .{ .breakpoint = 4 } } };
    try std.testing.expectEqual(EventKind.stopped, stopped.kind());
    try std.testing.expectEqual(@as(u32, 4), stopped.stopped.reason.breakpoint);
    try std.testing.expectEqual(@as(u32, 0), stopped.stopped.thread); // default main thread

    const stopped_trap: DebugEvent = .{ .stopped = .{ .reason = .{ .trapped = "index out of bounds" }, .thread = 2 } };
    try std.testing.expectEqualStrings("index out of bounds", stopped_trap.stopped.reason.trapped);
    try std.testing.expectEqual(@as(u32, 2), stopped_trap.stopped.thread);

    const cont: DebugEvent = .continued;
    try std.testing.expectEqual(EventKind.continued, cont.kind());

    const exited: DebugEvent = .{ .exited = .{ .code = 0 } };
    try std.testing.expectEqual(EventKind.exited, exited.kind());
    try std.testing.expectEqual(@as(i32, 0), exited.exited.code);

    const output: DebugEvent = .{ .output = .{ .text = "hello\n" } };
    try std.testing.expectEqual(EventKind.output, output.kind());
    try std.testing.expectEqualStrings("hello\n", output.output.text);

    const resolved: DebugEvent = .{ .breakpoint_resolved = .{
        .id = 1,
        .location = .{ .file = "main.kira", .line = 12, .column = 5 },
    } };
    try std.testing.expectEqual(EventKind.breakpoint_resolved, resolved.kind());
    try std.testing.expectEqual(@as(u32, 1), resolved.breakpoint_resolved.id);
    try std.testing.expectEqual(@as(u32, 12), resolved.breakpoint_resolved.location.line);
}

test "wire tags are stable and distinct" {
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(RequestKind.set_breakpoint));
    try std.testing.expectEqual(@as(u32, 9), @intFromEnum(RequestKind.disconnect));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(EventKind.stopped));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(EventKind.breakpoint_resolved));
}
