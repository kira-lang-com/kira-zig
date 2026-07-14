//! VM debug seam: the step/breakpoint engine the `DebugTarget` VM backend
//! (kira_debug's vm_target.zig) drives. Kept entirely inside kira_vm_runtime so
//! the runtime never imports the higher `kira_debug` layer (which imports us);
//! vm_target.zig imports these types and adapts them to the shared
//! `kira_debug/debug_info.zig` contract.
//!
//! Two cooperating mechanisms, both zero-cost when no controller is attached
//! (the interpreter gates every use behind a single `vm.debug` null check, the
//! same idiom `trace.zig` uses):
//!
//!   1. INT3-style software breakpoints. `arm()` patches a prepared function's
//!      private `code` copy with a sentinel `call_runtime` whose function id is
//!      `breakpoint_sentinel` and saves the original instruction. The dispatch
//!      loop routes the sentinel (already on its cold "index out of range" path)
//!      to `onBreakpointHit`, which restores the original, reports the stop, and
//!      lets the interpreter re-dispatch the ORIGINAL instruction. The breakpoint
//!      is re-armed one instruction later so it keeps firing (e.g. inside a loop)
//!      without immediately re-triggering on the same pc.
//!
//!   2. Software single-step. A `single_step` flag makes the interpreter call
//!      `beforeInstruction` ahead of every dispatched instruction; when set it
//!      reports a `.step` stop. The flag is off during free execution, so a
//!      running-but-attached session pays only the null check plus one
//!      not-taken branch per instruction.

const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const vm_prepare = @import("vm_prepare.zig");

const PreparedFunction = vm_prepare.PreparedFunction;

/// Sentinel `call_runtime.function_id` used to mark an armed breakpoint. Chosen
/// distinct from `vm_prepare.no_function_index` (maxInt) and
/// `vm_prepare.trap_label_index` (maxInt-1); no real prepared-function index can
/// reach it, so the dispatch loop's existing `>= functions.len` guard already
/// isolates it on a cold path.
pub const breakpoint_sentinel: u32 = std.math.maxInt(u32) - 2;

/// Why the interpreter handed control to the debugger.
pub const StopKind = enum { breakpoint, step };

/// A reported stop. `pc` indexes the stopped function's prepared `code`;
/// `function_id` is the bytecode function id (shared with the hybrid manifest).
pub const StopEvent = struct {
    function_id: u32,
    pc: usize,
    kind: StopKind,
};

/// What the interpreter should do after a stop is reported.
pub const ResumeAction = enum {
    /// Run freely until the next armed breakpoint.
    resume_run,
    /// Stop again before the next dispatched instruction.
    single_step,
};

/// The callback the debugger installs. `ctx` is the debugger's session pointer
/// (opaque to the runtime). Returning is the resume decision.
pub const StopFn = *const fn (ctx: ?*anyopaque, event: StopEvent) ResumeAction;

/// One live interpreter call frame, recorded so backtraces are walkable — the
/// bytecode interpreter otherwise keeps frames only as native Zig recursion.
/// `pc` aliases the interpreter's live program-counter local, so a reader sees
/// the frame's current instruction cursor without the frame being stopped.
pub const VmFrame = struct {
    function_id: u32,
    name: []const u8,
    pc: *const usize,
    /// The frame's live local slots (index = local id), for the variables view.
    /// Aliases the interpreter's per-call `locals` slice, valid while the frame
    /// is on the stack. Read-only for the debugger — never move/drop a slot (the
    /// interpreter owns their affine lifetimes). Empty for frames pushed before
    /// this field existed / with no locals.
    locals: []const runtime_abi.Value = &.{},
};

/// A single armed software breakpoint. `code` aliases the owning prepared
/// function's private instruction copy (mutable elements even through a
/// `*const PreparedFunction`, since the slice points at heap memory), so
/// patching `code[pc]` mutates exactly the stream the interpreter dispatches.
pub const Breakpoint = struct {
    code: []bytecode.Instruction,
    pc: usize,
    function_id: u32,
    saved: bytecode.Instruction,
    armed: bool,
};

/// The instruction patched over a breakpoint site.
pub fn sentinelInstruction() bytecode.Instruction {
    return .{ .call_runtime = .{ .function_id = breakpoint_sentinel, .args = &.{}, .dst = null } };
}

pub const DebugController = struct {
    on_stop: StopFn,
    ctx: ?*anyopaque = null,
    /// When true, `beforeInstruction` reports a `.step` stop before each
    /// dispatched instruction. Toggled by the resume decision.
    single_step: bool = false,
    /// Breakpoint id scheduled to be re-armed before the next dispatched
    /// instruction (set when a breakpoint fires; the original at that pc must
    /// execute once first, or the site would immediately re-trap).
    rearm_after: ?usize = null,
    breakpoints: std.ArrayListUnmanaged(Breakpoint) = .empty,

    pub fn init(on_stop: StopFn, ctx: ?*anyopaque) DebugController {
        return .{ .on_stop = on_stop, .ctx = ctx };
    }

    /// Restores every still-armed breakpoint (leaving the prepared code as the
    /// interpreter expects) and frees the breakpoint table. Does not free the
    /// prepared module — that is the VM's.
    pub fn deinit(self: *DebugController, allocator: std.mem.Allocator) void {
        for (self.breakpoints.items) |*bp| {
            if (bp.armed) {
                bp.code[bp.pc] = bp.saved;
                bp.armed = false;
            }
        }
        self.breakpoints.deinit(allocator);
    }

    /// Arms an INT3 breakpoint at `pc` of `function`, returning its id. The id is
    /// stable for the controller's lifetime and is what `clear` takes.
    pub fn arm(
        self: *DebugController,
        allocator: std.mem.Allocator,
        function: *const PreparedFunction,
        pc: usize,
    ) !usize {
        const id = self.breakpoints.items.len;
        try self.breakpoints.append(allocator, .{
            .code = function.code,
            .pc = pc,
            .function_id = function.decl.id,
            .saved = function.code[pc],
            .armed = true,
        });
        function.code[pc] = sentinelInstruction();
        return id;
    }

    /// Disarms and forgets the breakpoint with id `id` (restores the original
    /// instruction if still armed). Ids of other breakpoints are unaffected.
    pub fn clear(self: *DebugController, id: usize) void {
        if (id >= self.breakpoints.items.len) return;
        const bp = &self.breakpoints.items[id];
        if (bp.armed) {
            bp.code[bp.pc] = bp.saved;
            bp.armed = false;
        }
    }

    /// Re-patch a previously-fired breakpoint back into the code stream.
    fn rearm(self: *DebugController, id: usize) void {
        const bp = &self.breakpoints.items[id];
        if (bp.armed) return;
        bp.saved = bp.code[bp.pc];
        bp.code[bp.pc] = sentinelInstruction();
        bp.armed = true;
    }

    /// Called by the dispatch loop when it executes an armed breakpoint sentinel.
    /// Restores the original instruction (so the interpreter can re-dispatch it),
    /// reports the stop, and schedules a re-arm one instruction later.
    pub fn onBreakpointHit(self: *DebugController, function: *const PreparedFunction, pc: usize) void {
        for (self.breakpoints.items, 0..) |*bp, id| {
            if (!bp.armed or bp.code.ptr != function.code.ptr or bp.pc != pc) continue;
            bp.code[pc] = bp.saved;
            bp.armed = false;
            const action = self.on_stop(self.ctx, .{ .function_id = function.decl.id, .pc = pc, .kind = .breakpoint });
            self.single_step = (action == .single_step);
            self.rearm_after = id;
            return;
        }
        // Sentinel with no matching armed breakpoint: a stale patch. Restore a
        // void ret so execution cannot loop on it, and report a step stop so the
        // session is not silently lost.
        function.code[pc] = .{ .ret = .{ .src = null } };
    }

    /// Called by the dispatch loop before each dispatched instruction while a
    /// controller is attached. Handles a pending breakpoint re-arm and, when
    /// single-stepping, reports a `.step` stop.
    pub fn beforeInstruction(self: *DebugController, function: *const PreparedFunction, pc: usize) void {
        if (self.rearm_after) |id| {
            self.rearm(id);
            self.rearm_after = null;
        }
        if (!self.single_step) return;
        const action = self.on_stop(self.ctx, .{ .function_id = function.decl.id, .pc = pc, .kind = .step });
        self.single_step = (action == .single_step);
    }
};
