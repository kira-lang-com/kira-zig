//! vm_target — the in-process VM `DebugTarget`. Drives a live `kira_vm_runtime`
//! `Vm` through its debug seam (`vm_debug.DebugController`: INT3-style software
//! breakpoints + a single-step flag) and adapts the runtime's raw stop events to
//! the backend-agnostic `debug_info`/`target` contract the session speaks.
//!
//! ## Why a worker thread
//!
//! The VM interpreter is a synchronous Zig recursion and its stop hook is a
//! *synchronous* callback: `on_stop(ctx, event) -> ResumeAction` runs on the
//! interpreter's own stack and must return a resume decision without unwinding.
//! The `DebugTarget` contract, by contrast, is sequential: `start`/`cont`/`step`
//! each run the program until the next stop and *return* a `StopReason` to the
//! caller. The only faithful way to convert the re-entrant callback into that
//! run-and-return API — with an in-process VM that has no OS-level stop mechanism
//! — is to run the interpreter on a worker thread and hand control back and forth
//! with a strict two-semaphore ping-pong. Exactly one of {driver, VM} thread is
//! ever runnable at a time (each blocks on a semaphore the other posts), so the
//! VM's single-threaded heap/caches are never touched concurrently; the semaphore
//! post/wait pairs also establish the happens-before edges that make the shared
//! `pending_stop`/`finished`/`active_action` fields safe without atomics.
//!
//! Stepping (`into`/`over`/`out`/`instruction`) is driven by the shared
//! `step.StepController` fed one instruction stop at a time, so line-stepping
//! behaves identically to the native and hybrid targets (the parity guarantee).
//!
//! Breakpoints resolve `file:line` to a concrete interpreter pc via `LineResolver`
//! + `PreparedFunction.sourceLocAt`, then arm through the controller. Backtraces
//! walk `Vm.debugFrames()` and resolve each frame's live pc back to a source
//! position. `readMemory` is `Unsupported`: the VM has no flat address space.
//!
//! Locals/`evaluate` live in `vm_target_locals.zig`; see the note there and the
//! `frameValue` seam below for the one runtime API still required to render live
//! variable values.

const std = @import("std");
const bytecode = @import("kira_bytecode");
const abi = @import("kira_runtime_abi");
const vm_rt = @import("kira_vm_runtime");
const di = @import("debug_info.zig");
const target_mod = @import("target.zig");
const line_resolver = @import("line_resolver.zig");
const step_mod = @import("step.zig");
const breakpoint = @import("breakpoint.zig");
const locals_mod = @import("vm_target_locals.zig");
const sync = @import("sync.zig");

const Vm = vm_rt.Vm;
const Hooks = vm_rt.Hooks;
const DebugController = vm_rt.DebugController;
const StopEvent = vm_rt.StopEvent;
const ResumeAction = vm_rt.ResumeAction;
const PreparedModule = vm_rt.PreparedModule;
const LineResolver = line_resolver.LineResolver;
const StepController = step_mod.StepController;
const BreakpointTable = breakpoint.BreakpointTable;
const StepKind = target_mod.StepKind;
const StopReason = di.StopReason;

/// One armed breakpoint's cross-registry mapping: the public id handed to the
/// session (from `bp_table`), the controller-internal id used to disarm, and the
/// resolved (function_id, pc) used to attribute an incoming stop event back to it.
const ArmedBreakpoint = struct {
    public_id: u32,
    internal_id: usize,
    function_id: u32,
    pc: usize,
};

pub const VmTarget = struct {
    allocator: std.mem.Allocator,
    vm: *Vm,
    module: *const bytecode.Module,
    /// Program output sink handed to the interpreter (runs on the worker thread).
    writer: *std.Io.Writer,
    hooks: Hooks,

    controller: DebugController,
    resolver: LineResolver,
    bp_table: BreakpointTable,
    armed: std.ArrayListUnmanaged(ArmedBreakpoint) = .empty,
    /// Decoded module the run uses; cached so breakpoint arming patches the very
    /// instruction stream the interpreter dispatches (identical pointer identity
    /// to what `runMainWithHooks -> preparedFor` reuses).
    prepared: ?*const PreparedModule = null,

    // --- Worker-thread handshake -------------------------------------------
    thread: ?std.Thread = null,
    started: bool = false,
    finished: bool = false,
    run_error: ?anyerror = null,
    /// The stop the worker parked on, valid while the driver is running.
    pending_stop: ?StopEvent = null,
    /// What the parked `on_stop` callback returns on the next resume. Set by the
    /// driver before each `resumeVm`.
    active_action: ResumeAction = .resume_run,
    /// driver -> VM: "run / resume now". VM -> driver: "stopped / finished".
    to_vm: sync.Semaphore = .{},
    to_driver: sync.Semaphore = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        vm: *Vm,
        module: *const bytecode.Module,
        writer: *std.Io.Writer,
        hooks: Hooks,
    ) VmTarget {
        return .{
            .allocator = allocator,
            .vm = vm,
            .module = module,
            .writer = writer,
            .hooks = hooks,
            // ctx is fixed up in `start()` once the struct has a stable address.
            .controller = DebugController.init(onStopCb, null),
            .resolver = LineResolver.init(allocator),
            .bp_table = BreakpointTable.init(allocator),
        };
    }

    /// A `DebugTarget` view over this VM target. The `VmTarget` must not be moved
    /// after `start()` (the worker thread and the controller capture `&self`).
    pub fn target(self: *VmTarget) target_mod.DebugTarget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- Lifecycle ----------------------------------------------------------

    /// Attach the controller and spawn the worker parked at program entry. The
    /// session can then continue freely or enable stepping before any instruction
    /// executes, matching the native target's start contract.
    pub fn start(self: *VmTarget) anyerror!StopReason {
        if (self.started) {
            if (self.finished) return self.exitedReason();
            return .paused;
        }
        self.controller.ctx = self;
        self.vm.debug = &self.controller;
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        self.started = true;
        return .entry;
    }

    /// Run freely until the next armed breakpoint (or program end / trap).
    pub fn cont(self: *VmTarget) anyerror!StopReason {
        if (!self.started) _ = try self.start();
        if (self.finished) return self.exitedReason();
        self.controller.single_step = false;
        self.active_action = .resume_run;
        self.resumeVm();
        if (self.finished) return self.exitedReason();
        return self.stopReasonFor(self.pending_stop.?);
    }

    /// Advance by one source line / instruction per `kind`, driving the shared
    /// `StepController` across as many instruction stops as it takes.
    pub fn step(self: *VmTarget, kind: StepKind) anyerror!StopReason {
        if (!self.started) _ = try self.start();
        if (self.finished) return self.exitedReason();

        const origin_depth = self.frameDepth();
        const origin_pos = self.topPosition();
        var controller = StepController.begin(kind, origin_depth, origin_pos);

        self.controller.single_step = true;
        self.active_action = .single_step;
        while (true) {
            self.resumeVm();
            if (self.finished) return self.exitedReason();
            const event = self.pending_stop.?;
            // A breakpoint reached mid-step takes precedence over the step.
            if (event.kind == .breakpoint) {
                self.controller.single_step = false;
                return self.stopReasonFor(event);
            }
            switch (controller.onInstruction(self.frameDepth(), self.topPosition())) {
                .stop => {
                    self.controller.single_step = false;
                    return .step;
                },
                // Keep the single-step flag set (active_action already .single_step).
                .keep_stepping => {},
            }
        }
    }

    /// Detach: resume the (possibly parked) worker to completion with breakpoints
    /// disarmed so nothing stops it, join it, then free everything. Because the VM
    /// has no kill/abort, detaching runs the remaining program; a target parked in
    /// a non-terminating program will therefore block here (documented tradeoff).
    pub fn deinit(self: *VmTarget) void {
        if (self.started) {
            for (self.armed.items) |armed| self.controller.clear(armed.internal_id);
            self.controller.single_step = false;
            self.active_action = .resume_run;
            while (!self.finished) {
                self.to_vm.post();
                self.to_driver.wait();
            }
            self.thread.?.join();
        }
        self.vm.debug = null;
        self.controller.deinit(self.allocator);
        self.resolver.deinit();
        self.bp_table.deinit();
        self.armed.deinit(self.allocator);
    }

    // --- Breakpoints --------------------------------------------------------

    pub fn setBreakpoint(self: *VmTarget, spec: di.BreakpointSpec) anyerror!u32 {
        return switch (spec) {
            .line => |l| self.setLineBreakpoint(spec, l.file, l.line),
            .function => |name| self.setFunctionBreakpoint(spec, name),
            // No flat address space and no VM data-watch engine here yet.
            .address, .watch => target_mod.TargetError.Unsupported,
        };
    }

    fn setLineBreakpoint(self: *VmTarget, spec: di.BreakpointSpec, file: []const u8, line: u32) anyerror!u32 {
        const prepared = try self.ensurePrepared();
        const files = prepared.sourceFiles();
        for (prepared.functions, 0..) |*function, fi| {
            for (0..function.code.len) |pc| {
                const loc = function.sourceLocAt(pc) orelse continue;
                if (loc.file_id >= files.len) continue;
                const path = files[loc.file_id];
                if (!fileMatches(path, file)) continue;
                const pos = self.resolver.resolve(.{ .file = path, .start = loc.start, .end = loc.end }) catch continue;
                if (pos.line != line) continue;
                return self.armAt(spec, &prepared.functions[fi], pc);
            }
        }
        return target_mod.TargetError.NotFound;
    }

    fn setFunctionBreakpoint(self: *VmTarget, spec: di.BreakpointSpec, name: []const u8) anyerror!u32 {
        const prepared = try self.ensurePrepared();
        for (prepared.functions, 0..) |*function, fi| {
            if (std.mem.eql(u8, function.decl.name, name)) {
                return self.armAt(spec, &prepared.functions[fi], 0);
            }
        }
        return target_mod.TargetError.NotFound;
    }

    fn armAt(self: *VmTarget, spec: di.BreakpointSpec, function: *const vm_rt.PreparedFunction, pc: usize) anyerror!u32 {
        const internal_id = try self.controller.arm(self.allocator, function, pc);
        errdefer self.controller.clear(internal_id);
        const public_id = try self.bp_table.add(spec, null);
        self.bp_table.markResolved(public_id, @intCast(pc));
        try self.armed.append(self.allocator, .{
            .public_id = public_id,
            .internal_id = internal_id,
            .function_id = function.decl.id,
            .pc = pc,
        });
        return public_id;
    }

    pub fn clearBreakpoint(self: *VmTarget, id: u32) anyerror!void {
        for (self.armed.items, 0..) |armed, i| {
            if (armed.public_id != id) continue;
            self.controller.clear(armed.internal_id);
            self.bp_table.remove(id) catch {};
            _ = self.armed.swapRemove(i);
            return;
        }
        return target_mod.TargetError.NotFound;
    }

    // --- Backtrace ----------------------------------------------------------

    pub fn backtrace(self: *VmTarget, allocator: std.mem.Allocator) anyerror![]di.Frame {
        const frames = self.vm.debugFrames();
        const out = try allocator.alloc(di.Frame, frames.len);
        errdefer allocator.free(out);
        // `debugFrames()` is outermost-first; the backtrace convention is
        // innermost-first (frame #0 = the currently-executing call), so walk it
        // in reverse. `frameDecl` uses the same inversion.
        for (0..frames.len) |i| {
            const vf = frames[frames.len - 1 - i];
            const pc = vf.pc.*;
            out[i] = .{
                .index = @intCast(i),
                .backend = .vm,
                .function_id = vf.function_id,
                .function_name = vf.name,
                .position = self.resolvePosition(vf.function_id, pc),
                .program_counter = @intCast(pc),
            };
        }
        return out;
    }

    // --- Frame introspection helpers (also used by vm_target_locals.zig) -----

    /// The interpreter call-frame decl for `frame_index` (into `debugFrames()`),
    /// or null when out of range / the module has no matching function.
    pub fn frameDecl(self: *VmTarget, frame_index: u32) ?*const bytecode.Function {
        const frames = self.vm.debugFrames();
        if (frame_index >= frames.len) return null;
        // Innermost-first indexing, matching `backtrace`.
        const vf = frames[frames.len - 1 - frame_index];
        const prepared = self.preparedOrNull() orelse return null;
        const idx = prepared.indexOfId(vf.function_id) orelse return null;
        return prepared.functions[idx].decl;
    }

    /// Read the live value of local `slot` in frame `frame_index`, or null when it
    /// cannot be read.
    ///
    /// BLOCKER SEAM: the vm-engine `vm_debug.VmFrame` exposes only
    /// `{ function_id, name, pc }` — it does NOT carry the frame's register/local
    /// value/`owned` storage (those live as `runPrepared` stack locals). Until the
    /// runtime exposes them (e.g. `VmFrame.values: []const Value` +
    /// `owned: []const bool`, or a `Vm.debugFrameSlot(frame_index, slot)`
    /// accessor), live locals cannot be rendered, so this returns null and
    /// `locals`/`evaluate` degrade honestly rather than fabricating values. This
    /// is a wiring seam, not a stub: once the accessor lands, read it here and the
    /// value-view/evaluator paths light up unchanged.
    pub fn frameValue(self: *VmTarget, frame_index: u32, slot: u32) ?abi.Value {
        const frames = self.vm.debugFrames();
        if (frame_index >= frames.len) return null;
        // Innermost-first indexing, matching `backtrace`/`frameDecl`.
        const vf = frames[frames.len - 1 - frame_index];
        if (slot >= vf.locals.len) return null;
        return vf.locals[slot];
    }

    fn frameDepth(self: *VmTarget) u32 {
        return @intCast(self.vm.debugFrames().len);
    }

    fn topPosition(self: *VmTarget) ?di.SourcePosition {
        const frames = self.vm.debugFrames();
        if (frames.len == 0) return null;
        const top = frames[frames.len - 1];
        return self.resolvePosition(top.function_id, top.pc.*);
    }

    /// Resolve `(function_id, pc)` to a 1-based source position, or null when no
    /// debug info covers it (synthesized ops, missing source file).
    pub fn resolvePosition(self: *VmTarget, function_id: u32, pc: usize) ?di.SourcePosition {
        const prepared = self.preparedOrNull() orelse return null;
        const idx = prepared.indexOfId(function_id) orelse return null;
        const loc = prepared.functions[idx].sourceLocAt(pc) orelse return null;
        const files = prepared.sourceFiles();
        if (loc.file_id >= files.len) return null;
        return self.resolver.resolve(.{
            .file = files[loc.file_id],
            .start = loc.start,
            .end = loc.end,
        }) catch null;
    }

    // --- Internals ----------------------------------------------------------

    fn ensurePrepared(self: *VmTarget) !*const PreparedModule {
        if (self.prepared) |p| return p;
        const p = try self.vm.preparedFor(self.module);
        self.prepared = p;
        return p;
    }

    fn preparedOrNull(self: *VmTarget) ?*const PreparedModule {
        if (self.prepared) |p| return p;
        const p = self.vm.preparedFor(self.module) catch return null;
        self.prepared = p;
        return p;
    }

    /// Hand the VM one run/resume turn and block until it stops or finishes.
    fn resumeVm(self: *VmTarget) void {
        self.pending_stop = null;
        self.to_vm.post();
        self.to_driver.wait();
    }

    fn stopReasonFor(self: *VmTarget, event: StopEvent) StopReason {
        if (event.kind == .breakpoint) {
            for (self.armed.items) |armed| {
                if (armed.function_id == event.function_id and armed.pc == event.pc) {
                    self.bp_table.recordHit(armed.public_id);
                    return .{ .breakpoint = armed.public_id };
                }
            }
            // A sentinel with no owning registry entry: report a plain pause
            // rather than inventing a breakpoint id.
            return .paused;
        }
        return .step;
    }

    fn exitedReason(self: *VmTarget) StopReason {
        if (self.run_error != null) {
            return .{ .trapped = self.vm.lastError() orelse "vm run failed" };
        }
        return .{ .exited = 0 };
    }
};

/// True when a compiled source path matches a user-supplied breakpoint file. The
/// user may pass a bare/relative name while the module stores an absolute path
/// (or vice versa), so accept an exact match or either being a path suffix of the
/// other on a segment boundary.
fn fileMatches(path: []const u8, requested: []const u8) bool {
    if (std.mem.eql(u8, path, requested)) return true;
    return suffixOnBoundary(path, requested) or suffixOnBoundary(requested, path);
}

fn suffixOnBoundary(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    if (!std.mem.endsWith(u8, haystack, needle)) return false;
    if (needle.len == haystack.len) return true;
    return haystack[haystack.len - needle.len - 1] == '/';
}

/// The controller's `on_stop` callback — runs on the worker thread. Records the
/// stop, wakes the driver, and blocks until the driver resumes, returning the
/// resume decision the driver chose.
fn onStopCb(ctx: ?*anyopaque, event: StopEvent) ResumeAction {
    const self: *VmTarget = @ptrCast(@alignCast(ctx.?));
    self.pending_stop = event;
    self.to_driver.post();
    self.to_vm.wait();
    return self.active_action;
}

/// Worker-thread entrypoint: wait for the first resume, run the program to
/// completion (capturing any error), then report the terminal stop.
fn workerMain(self: *VmTarget) void {
    self.to_vm.wait();
    self.vm.runMainWithHooks(self.module, self.writer, self.hooks) catch |err| {
        self.run_error = err;
    };
    self.finished = true;
    self.to_driver.post();
}

fn castSelf(ctx: *anyopaque) *VmTarget {
    return @ptrCast(@alignCast(ctx));
}

const vtable = target_mod.DebugTarget.VTable{
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

fn vtStart(ctx: *anyopaque) anyerror!StopReason {
    return castSelf(ctx).start();
}
fn vtCont(ctx: *anyopaque) anyerror!StopReason {
    return castSelf(ctx).cont();
}
fn vtStep(ctx: *anyopaque, kind: StepKind) anyerror!StopReason {
    return castSelf(ctx).step(kind);
}
fn vtSetBreakpoint(ctx: *anyopaque, spec: di.BreakpointSpec) anyerror!u32 {
    return castSelf(ctx).setBreakpoint(spec);
}
fn vtClearBreakpoint(ctx: *anyopaque, id: u32) anyerror!void {
    return castSelf(ctx).clearBreakpoint(id);
}
fn vtBacktrace(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]di.Frame {
    return castSelf(ctx).backtrace(allocator);
}
fn vtLocals(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32) anyerror![]di.LocalView {
    return locals_mod.locals(castSelf(ctx), allocator, frame_index);
}
fn vtEvaluate(ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) anyerror![]const u8 {
    return locals_mod.evaluate(castSelf(ctx), allocator, frame_index, expr);
}
fn vtReadMemory(ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void {
    _ = ctx;
    _ = addr;
    _ = buf;
    // The VM value model has no flat, byte-addressable memory to read.
    return target_mod.TargetError.Unsupported;
}
fn vtDeinit(ctx: *anyopaque) void {
    castSelf(ctx).deinit();
}

test "fileMatches accepts exact and boundary suffixes, rejects partial segments" {
    try std.testing.expect(fileMatches("/a/b/main.kira", "/a/b/main.kira"));
    try std.testing.expect(fileMatches("/a/b/main.kira", "main.kira"));
    try std.testing.expect(fileMatches("/a/b/main.kira", "b/main.kira"));
    try std.testing.expect(fileMatches("main.kira", "/a/b/main.kira"));
    // "in.kira" is a byte suffix of "main.kira" but not on a path boundary.
    try std.testing.expect(!fileMatches("/a/b/main.kira", "in.kira"));
    try std.testing.expect(!fileMatches("/a/b/main.kira", "other.kira"));
}
