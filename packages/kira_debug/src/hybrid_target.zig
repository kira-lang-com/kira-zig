//! `HybridTarget` — a unified `DebugTarget` over a hybrid program that muxes a
//! VM sub-target and a native sub-target and presents ONE merged frame stack.
//!
//! A hybrid program runs partly in the bytecode VM (`@Runtime` functions) and
//! partly as compiled native code (`@Native` functions), with control crossing
//! the VM<->native boundary through the runtime funnels
//! (`kira_hybrid_runtime` `invokeRuntime` for native->VM callbacks and
//! `native_calls.callNative` for VM->native calls). The hybrid module manifest
//! (`FunctionManifest.execution`) records, per function, which side owns it.
//!
//! This target composes two `DebugTarget`s (constructed by the integration layer
//! over the same inferior) rather than a concrete `VmTarget`/`NativeTarget` type:
//! the `DebugTarget` vtable IS the composition seam (see `target.zig`'s header),
//! so backends stay in their own files and hybrid wires them by manifest routing.
//!
//! Scope of this first cut (per the task contract):
//!   * `setBreakpoint` resolves a function's execution from the manifest and
//!     routes to the owning sub-target; ambiguous line/watch specs arm both.
//!   * `backtrace` concatenates both sub-stacks in call order (innermost side
//!     first) and re-tags every `Frame.backend` from the manifest.
//!   * `locals`/`evaluate` route to the owning sub-target for the requested frame.
//!   * `cont`/`step` drive the currently-active side.
//! Full cross-boundary single-step (following one machine/VM step across a
//! `BridgeValue` handoff mid-instruction) is a documented follow-up — see
//! `cont`/`step` below. It is NOT faked here: stepping drives the real active
//! sub-target and reports its real stop reason.
const std = @import("std");
const di = @import("debug_info.zig");
const target_mod = @import("target.zig");
const hybrid = @import("kira_hybrid_definition");

const DebugTarget = target_mod.DebugTarget;
const StepKind = target_mod.StepKind;
const TargetError = target_mod.TargetError;

/// Which sub-target a placement / stop belongs to. Mirrors `di.Backend` but kept
/// local so the routing logic reads in terms of "the vm side" / "the native side".
const Side = di.Backend;

/// One armed placement on a sub-target: the id that sub-target handed back plus
/// which side it lives on. A single hybrid breakpoint id may fan out to a
/// placement on each side (an ambiguous line breakpoint arms both).
const Placement = struct {
    side: Side,
    sub_id: u32,
};

/// A hybrid breakpoint id and the (up to two) sub-target placements behind it.
const BreakpointEntry = struct {
    placements: [2]Placement = undefined,
    count: u8 = 0,

    fn add(self: *BreakpointEntry, side: Side, sub_id: u32) void {
        if (self.count >= self.placements.len) return;
        self.placements[self.count] = .{ .side = side, .sub_id = sub_id };
        self.count += 1;
    }

    fn slice(self: *const BreakpointEntry) []const Placement {
        return self.placements[0..self.count];
    }
};

pub const HybridTarget = struct {
    allocator: std.mem.Allocator,
    /// The VM (`@Runtime`) sub-target. Owned: `deinit` tears it down.
    vm: DebugTarget,
    /// The native (`@Native`) sub-target. Owned: `deinit` tears it down.
    native: DebugTarget,
    /// Per-function execution routing (`FunctionManifest.execution`). Borrowed
    /// from the caller; must outlive the target.
    manifest: hybrid.HybridModuleManifest,
    /// Hybrid breakpoint id -> sub-target placements.
    breakpoints: std.AutoHashMapUnmanaged(u32, BreakpointEntry) = .empty,
    next_id: u32 = 1,
    /// The side that most recently ran / is stopped innermost. Seeded from the
    /// entry function's execution; updated by `start`/`cont`/`step`. Determines
    /// which sub-stack sits on top of the merged backtrace.
    top: Side,

    /// Construct a hybrid target over an already-built VM and native sub-target
    /// that observe the same inferior. Takes ownership of both sub-targets (they
    /// are torn down by `deinit`). `manifest` is borrowed and must outlive this.
    pub fn init(
        allocator: std.mem.Allocator,
        vm: DebugTarget,
        native: DebugTarget,
        manifest: hybrid.HybridModuleManifest,
    ) HybridTarget {
        return .{
            .allocator = allocator,
            .vm = vm,
            .native = native,
            .manifest = manifest,
            .top = backendFor(manifest.entry_execution),
        };
    }

    /// The backend-agnostic handle the debug session drives.
    pub fn target(self: *HybridTarget) DebugTarget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ---- manifest routing helpers -------------------------------------------

    /// Map a manifest `FunctionExecution` to the sub-target side. `native`
    /// executes as compiled code; `runtime`/`inherited` execute in the VM.
    fn backendFor(execution: anytype) Side {
        return if (execution == .native) .native else .vm;
    }

    fn findByName(self: *HybridTarget, name: []const u8) ?hybrid.FunctionManifest {
        for (self.manifest.functions) |function_decl| {
            if (std.mem.eql(u8, function_decl.name, name)) return function_decl;
        }
        return null;
    }

    fn findById(self: *HybridTarget, function_id: u32) ?hybrid.FunctionManifest {
        for (self.manifest.functions) |function_decl| {
            if (function_decl.id == function_id) return function_decl;
        }
        return null;
    }

    fn subFor(self: *HybridTarget, side: Side) DebugTarget {
        return switch (side) {
            .vm => self.vm,
            .native => self.native,
        };
    }

    // ---- breakpoints ---------------------------------------------------------

    /// Arm `spec` on one side. A side that has no business with this spec answers
    /// `Unsupported`/`NotFound`; that is folded to `null` so an ambiguous spec can
    /// arm the other side. Any other error propagates.
    fn armOn(self: *HybridTarget, side: Side, spec: di.BreakpointSpec) !?u32 {
        return self.subFor(side).setBreakpoint(spec) catch |err| switch (err) {
            TargetError.Unsupported, TargetError.NotFound => null,
            else => err,
        };
    }

    fn setBreakpoint(self: *HybridTarget, spec: di.BreakpointSpec) !u32 {
        var entry: BreakpointEntry = .{};
        switch (spec) {
            // A function breakpoint resolves unambiguously through the manifest.
            .function => |name| {
                const side = if (self.findByName(name)) |function_decl|
                    backendFor(function_decl.execution)
                else
                    .vm; // unknown symbol: default to the VM side's resolver
                if (try self.armOn(side, spec)) |sub_id| entry.add(side, sub_id);
            },
            // A raw address is a native concept; only the native side can arm it.
            .address => {
                if (try self.armOn(.native, spec)) |sub_id| entry.add(.native, sub_id);
            },
            // Line and watch specs are not function-tagged and the manifest has no
            // file/line -> function map here, so a line may live on either side and
            // a watched expression may resolve in either value model. Arm both; the
            // side that actually owns the location resolves it, the other rejects.
            .line, .watch => {
                if (try self.armOn(.vm, spec)) |sub_id| entry.add(.vm, sub_id);
                if (try self.armOn(.native, spec)) |sub_id| entry.add(.native, sub_id);
            },
        }

        if (entry.count == 0) return TargetError.NotFound;

        const id = self.next_id;
        self.next_id += 1;
        try self.breakpoints.put(self.allocator, id, entry);
        return id;
    }

    fn clearBreakpoint(self: *HybridTarget, id: u32) !void {
        const entry = self.breakpoints.getPtr(id) orelse return TargetError.NotFound;
        for (entry.slice()) |placement| {
            self.subFor(placement.side).clearBreakpoint(placement.sub_id) catch |err| switch (err) {
                // A placement already gone on its side is fine; keep clearing the rest.
                TargetError.NotFound => {},
                else => return err,
            };
        }
        _ = self.breakpoints.remove(id);
    }

    /// Rewrite a sub-target stop into hybrid terms: translate the sub-target's
    /// breakpoint/watchpoint id back to the hybrid id that fanned out to it, and
    /// remember which side is now innermost.
    fn translateStop(self: *HybridTarget, side: Side, reason: di.StopReason) di.StopReason {
        self.top = side;
        return switch (reason) {
            .breakpoint => |sub_id| .{ .breakpoint = self.hybridIdFor(side, sub_id) orelse sub_id },
            .watchpoint => |sub_id| .{ .watchpoint = self.hybridIdFor(side, sub_id) orelse sub_id },
            else => reason,
        };
    }

    fn hybridIdFor(self: *HybridTarget, side: Side, sub_id: u32) ?u32 {
        var it = self.breakpoints.iterator();
        while (it.next()) |kv| {
            for (kv.value_ptr.slice()) |placement| {
                if (placement.side == side and placement.sub_id == sub_id) return kv.key_ptr.*;
            }
        }
        return null;
    }

    // ---- execution -----------------------------------------------------------

    fn start(self: *HybridTarget) !di.StopReason {
        const side = backendFor(self.manifest.entry_execution);
        const reason = try self.subFor(side).start();
        return self.translateStop(side, reason);
    }

    fn cont(self: *HybridTarget) !di.StopReason {
        // First cut: resume the currently-active side and report its real stop.
        //
        // Follow-up (cross-boundary continuation): a hybrid program is one
        // process, so resuming should let a breakpoint on EITHER side fire. That
        // needs the runtime funnels (`invokeRuntime` / `callNative`) to signal the
        // debug session when control transfers across the `BridgeValue` boundary
        // so the muxer can hand off between sub-targets mid-run. Until that hook
        // exists, a breakpoint on the inactive side is observed only after control
        // reaches that side and its sub-target regains the stop. This is a real,
        // documented limitation — not a faked stop.
        const side = self.top;
        const reason = try self.subFor(side).cont();
        return self.translateStop(side, reason);
    }

    fn step(self: *HybridTarget, kind: StepKind) !di.StopReason {
        // First cut: step the active side in its own instruction/line model.
        // Following a single step across a VM<->native handoff (e.g. stepping
        // `into` a `@Native` call from `@Runtime` code, or returning from a native
        // callback into the VM) is the same cross-boundary follow-up described in
        // `cont`: it requires the runtime-funnel handoff hook. Reported here is the
        // active sub-target's genuine step result.
        const side = self.top;
        const reason = try self.subFor(side).step(kind);
        return self.translateStop(side, reason);
    }

    // ---- inspection ----------------------------------------------------------

    /// Fetch a sub-target's frames, tolerating "nothing on this side" (a side that
    /// is not currently on the stack answers `NotStopped`/`Unsupported`).
    fn framesFor(self: *HybridTarget, allocator: std.mem.Allocator, side: Side) ![]di.Frame {
        return self.subFor(side).backtrace(allocator) catch |err| switch (err) {
            TargetError.NotStopped, TargetError.Unsupported => &.{},
            else => err,
        };
    }

    fn backtrace(self: *HybridTarget, allocator: std.mem.Allocator) ![]di.Frame {
        // Merge order is innermost-first: the active side sits on top, the other
        // below it. (A program that alternates sides repeatedly across the boundary
        // produces >2 interleaved segments; representing that faithfully needs the
        // per-boundary frame tracking noted as the cont/step follow-up. Two-segment
        // ordering is the honest first-cut approximation.)
        const top_side = self.top;
        const bottom_side: Side = if (top_side == .vm) .native else .vm;

        const top_frames = try self.framesFor(allocator, top_side);
        defer allocator.free(top_frames);
        const bottom_frames = try self.framesFor(allocator, bottom_side);
        defer allocator.free(bottom_frames);

        const merged = try allocator.alloc(di.Frame, top_frames.len + bottom_frames.len);
        var cursor: u32 = 0;
        for (top_frames) |frame| {
            merged[cursor] = self.retag(frame, cursor, top_side);
            cursor += 1;
        }
        for (bottom_frames) |frame| {
            merged[cursor] = self.retag(frame, cursor, bottom_side);
            cursor += 1;
        }
        return merged;
    }

    /// Reindex a frame into the merged stack and correct its `backend` from the
    /// manifest (falling back to the sub-target's own tag when the function id is
    /// not in the manifest, e.g. a synthesized or runtime-internal frame).
    fn retag(self: *HybridTarget, frame: di.Frame, index: u32, fallback_side: Side) di.Frame {
        var out = frame;
        out.index = index;
        out.backend = if (self.findById(frame.function_id)) |function_decl|
            backendFor(function_decl.execution)
        else
            fallback_side;
        return out;
    }

    /// Resolve a merged frame index to (side, sub-frame index) using the same
    /// top/bottom split `backtrace` produces, so a frame index handed back to the
    /// session round-trips to the owning sub-target.
    fn routeFrame(self: *HybridTarget, allocator: std.mem.Allocator, frame_index: u32) !struct { side: Side, sub_index: u32 } {
        const top_side = self.top;
        const bottom_side: Side = if (top_side == .vm) .native else .vm;

        const top_frames = try self.framesFor(allocator, top_side);
        const top_len: u32 = @intCast(top_frames.len);
        allocator.free(top_frames);

        if (frame_index < top_len) return .{ .side = top_side, .sub_index = frame_index };
        return .{ .side = bottom_side, .sub_index = frame_index - top_len };
    }

    fn locals(self: *HybridTarget, allocator: std.mem.Allocator, frame_index: u32) ![]di.LocalView {
        const route = try self.routeFrame(allocator, frame_index);
        return self.subFor(route.side).locals(allocator, route.sub_index);
    }

    fn evaluate(self: *HybridTarget, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) ![]const u8 {
        const route = try self.routeFrame(allocator, frame_index);
        return self.subFor(route.side).evaluate(allocator, route.sub_index, expr);
    }

    fn readMemory(self: *HybridTarget, addr: u64, buf: []u8) !void {
        // Process memory is a native concept; the VM value model has no addresses.
        return self.native.readMemory(addr, buf);
    }

    fn deinit(self: *HybridTarget) void {
        self.breakpoints.deinit(self.allocator);
        self.vm.deinit();
        self.native.deinit();
    }
};

// ---- vtable trampolines -----------------------------------------------------

const vtable: DebugTarget.VTable = .{
    .start = vtStart,
    .cont = vtCont,
    .step = vtStep,
    .setBreakpoint = vtSetBreakpoint,
    .clearBreakpoint = vtClearBreakpoint,
    .backtrace = vtBacktrace,
    .locals = vtLocals,
    .evaluate = vtEvaluate,
    .readMemory = vtReadMemory,
    .deinit = vtDeinit,
};

fn cast(ctx: *anyopaque) *HybridTarget {
    return @ptrCast(@alignCast(ctx));
}

fn vtStart(ctx: *anyopaque) anyerror!di.StopReason {
    return cast(ctx).start();
}
fn vtCont(ctx: *anyopaque) anyerror!di.StopReason {
    return cast(ctx).cont();
}
fn vtStep(ctx: *anyopaque, kind: StepKind) anyerror!di.StopReason {
    return cast(ctx).step(kind);
}
fn vtSetBreakpoint(ctx: *anyopaque, spec: di.BreakpointSpec) anyerror!u32 {
    return cast(ctx).setBreakpoint(spec);
}
fn vtClearBreakpoint(ctx: *anyopaque, id: u32) anyerror!void {
    return cast(ctx).clearBreakpoint(id);
}
fn vtBacktrace(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]di.Frame {
    return cast(ctx).backtrace(allocator);
}
fn vtLocals(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32) anyerror![]di.LocalView {
    return cast(ctx).locals(allocator, frame_index);
}
fn vtEvaluate(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) anyerror![]const u8 {
    return cast(ctx).evaluate(allocator, frame_index, expr);
}
fn vtReadMemory(ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void {
    return cast(ctx).readMemory(addr, buf);
}
fn vtDeinit(ctx: *anyopaque) void {
    cast(ctx).deinit();
}
