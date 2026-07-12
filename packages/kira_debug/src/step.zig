//! `StepController` — the backend-agnostic step state machine. Given a `StepKind`
//! and the origin (call-stack depth + source position) captured when a step began,
//! it decides at every instruction stop whether the step is complete (`stop`) or
//! the target should keep single-stepping (`keep_stepping`).
//!
//! Deliberately pure logic: it has no dependency on the VM value model or the
//! native register file, only on the shared `SourcePosition`/`StepKind` contract.
//! Every `DebugTarget` (VM, native, hybrid) drives the *same* controller so
//! source-line stepping behaves identically across backends — that is the parity
//! guarantee. All decisions are unit-testable here without a running target.
const std = @import("std");
const di = @import("debug_info.zig");
const target = @import("target.zig");

pub const SourcePosition = di.SourcePosition;
pub const StepKind = target.StepKind;

/// Two positions are on the "same source line" when they share file and line.
/// Column is intentionally ignored — line stepping stops on line boundaries, not
/// column moves, so multiple statements on one physical line count as one step.
fn sameLine(a: SourcePosition, b: SourcePosition) bool {
    return a.line == b.line and std.mem.eql(u8, a.file, b.file);
}

/// Has the current position moved to a different source line than the origin?
///
/// Null handling is asymmetric on purpose:
/// - current `null` (no resolvable line) → `false`: a line-based step never stops
///   at an unknown location; it keeps going until it reaches a real line.
/// - current non-null, origin `null` → `true`: moving from "unknown" to a concrete
///   line is a real line change worth stopping on.
fn lineChanged(origin: ?SourcePosition, current: ?SourcePosition) bool {
    const cur = current orelse return false;
    const org = origin orelse return true;
    return !sameLine(org, cur);
}

/// Drives a single in-flight step. Construct one with `begin`, then feed every
/// instruction-level stop through `onInstruction` until it returns `.stop`.
pub const StepController = struct {
    /// Outcome of evaluating one instruction stop against the active step.
    pub const Decision = enum {
        /// The step is complete; report a `step` stop to the user.
        stop,
        /// Not there yet; issue one more backend single-step and re-evaluate.
        keep_stepping,
    };

    kind: StepKind,
    /// Call-stack depth when the step began (frame count; deeper calls increase it).
    origin_depth: u32,
    /// Source position when the step began, if one was resolvable.
    origin_position: ?SourcePosition,

    /// Begin a step of `kind` from the given origin. `origin_depth` is the current
    /// call-stack depth and `origin_position` the current source position (null if
    /// the starting instruction has no line info).
    pub fn begin(kind: StepKind, origin_depth: u32, origin_position: ?SourcePosition) StepController {
        return .{
            .kind = kind,
            .origin_depth = origin_depth,
            .origin_position = origin_position,
        };
    }

    /// Evaluate one instruction stop. `depth` is the current call-stack depth and
    /// `position` the current source position (null when unresolved). Returns
    /// whether to stop the step or keep single-stepping.
    pub fn onInstruction(self: StepController, depth: u32, position: ?SourcePosition) Decision {
        switch (self.kind) {
            // One backend instruction and we're done, regardless of line or depth.
            .instruction => return .stop,

            // Stop at the next different source line, descending into calls freely.
            .into => return if (lineChanged(self.origin_position, position)) .stop else .keep_stepping,

            // Stop at the next different source line, but only once we are back at
            // or above the origin frame. Deeper frames (a call we stepped over) are
            // run to completion — never stop inside them.
            .over => {
                if (depth > self.origin_depth) return .keep_stepping;
                return if (lineChanged(self.origin_position, position)) .stop else .keep_stepping;
            },

            // Stop as soon as we have returned out of the origin frame.
            .out => return if (depth < self.origin_depth) .stop else .keep_stepping,
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn pos(line: u32) SourcePosition {
    return .{ .file = "main.kira", .line = line, .column = 1 };
}

fn posIn(file: []const u8, line: u32) SourcePosition {
    return .{ .file = file, .line = line, .column = 1 };
}

test "instruction: stops after exactly one step, any depth or line" {
    const c = StepController.begin(.instruction, 3, pos(10));
    // Same line, same depth still stops — one instruction is one instruction.
    try testing.expectEqual(StepController.Decision.stop, c.onInstruction(3, pos(10)));
    // Deeper frame, no line info: still stops.
    try testing.expectEqual(StepController.Decision.stop, c.onInstruction(5, null));
}

test "into: keeps stepping on same line, stops when line changes at any depth" {
    const c = StepController.begin(.into, 2, pos(10));
    // Still on origin line -> keep going.
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(2, pos(10)));
    // Descended into a call, new line -> into stops (it follows calls).
    try testing.expectEqual(StepController.Decision.stop, c.onInstruction(3, pos(42)));
    // Line changed at a shallower depth too -> stop.
    try testing.expectEqual(StepController.Decision.stop, c.onInstruction(1, pos(11)));
}

test "into: unresolved current position never stops" {
    const c = StepController.begin(.into, 1, pos(5));
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(1, null));
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(4, null));
}

test "into: crossing into a different file is a line change" {
    const c = StepController.begin(.into, 1, posIn("a.kira", 7));
    // Same line number but different file -> changed.
    try testing.expectEqual(StepController.Decision.stop, c.onInstruction(1, posIn("b.kira", 7)));
}

test "over: does not stop inside a deeper call, stops on return to origin line" {
    const c = StepController.begin(.over, 2, pos(10));
    // Same line, same depth -> keep going.
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(2, pos(10)));
    // Stepped into a call (deeper) on a new line -> must NOT stop (step over).
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(3, pos(99)));
    // Even deeper still keeps stepping.
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(5, pos(120)));
    // Back at origin depth on a new line -> stop.
    try testing.expectEqual(StepController.Decision.stop, c.onInstruction(2, pos(11)));
}

test "over: recursion — deeper recursive frames on new lines never stop" {
    // Origin line calls itself recursively; over must run the whole recursion.
    const c = StepController.begin(.over, 4, pos(20));
    // Each recursive entry is deeper and on a different line — keep stepping.
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(5, pos(21)));
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(6, pos(22)));
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(7, pos(20))); // same line, deeper
    // Unwinding back through deeper frames still does not stop until <= origin.
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(6, pos(23)));
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(5, pos(24)));
    // Returned to origin depth, line advanced past the call -> stop.
    try testing.expectEqual(StepController.Decision.stop, c.onInstruction(4, pos(21)));
}

test "over: returning above origin on a new line also stops" {
    const c = StepController.begin(.over, 3, pos(10));
    // If the origin frame itself returns, depth < origin and line differs -> stop.
    try testing.expectEqual(StepController.Decision.stop, c.onInstruction(2, pos(50)));
}

test "over: at/above origin but still same line keeps stepping" {
    const c = StepController.begin(.over, 3, pos(10));
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(3, pos(10)));
}

test "out: stops only after depth drops below origin" {
    const c = StepController.begin(.out, 3, pos(10));
    // Same depth -> still inside the frame, keep going even on new lines.
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(3, pos(11)));
    // Deeper (called something) -> keep going.
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(5, pos(80)));
    // Returned one level -> below origin -> stop.
    try testing.expectEqual(StepController.Decision.stop, c.onInstruction(2, pos(40)));
}

test "out: position is irrelevant — null current still stops on depth drop" {
    const c = StepController.begin(.out, 2, pos(10));
    try testing.expectEqual(StepController.Decision.stop, c.onInstruction(1, null));
}

test "out: from origin depth 0 never underflows, just keeps stepping" {
    const c = StepController.begin(.out, 0, null);
    try testing.expectEqual(StepController.Decision.keep_stepping, c.onInstruction(0, pos(1)));
}
