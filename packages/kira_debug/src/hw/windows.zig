//! `HwBreakpointController` implementation for Windows on x86_64 and arm64,
//! driven through `GetThreadContext`/`SetThreadContext` with the
//! `CONTEXT_DEBUG_REGISTERS` flag.
//!
//! Two architectures, two hardware debug models, one controller:
//!
//!   * **x86_64** — the classic CPU debug registers. `Dr0`-`Dr3` hold linear
//!     addresses; `Dr7` enables each slot (local-enable bit pairs) and encodes
//!     its R/W condition + length (2+2 bits per slot); `Dr6` reports which slot
//!     fired (`B0`-`B3`) and single-step (`BS`, bit 14). Single-instruction
//!     stepping toggles the `TF` (trap) flag in `EFlags` (bit 8): the CPU raises
//!     `EXCEPTION_SINGLE_STEP` after the next instruction retires.
//!
//!   * **arm64** — the ARM debug architecture register banks exposed by
//!     `ARM64_NT_CONTEXT`: `Bvr[n]`/`Bcr[n]` are hardware *instruction*
//!     breakpoints (value + control), `Wvr[n]`/`Wcr[n]` are *data* watchpoints.
//!     Single-step sets the `SS` bit (bit 21) of `Cpsr`.
//!
//! Delivery of the debug exception uses one of the two Windows mechanisms named
//! in the task:
//!
//!   (a) **Cross-process debug loop** — `DebugActiveProcess(pid)` then a
//!       `WaitForDebugEventEx`/`ContinueDebugEvent` loop. On an
//!       `EXCEPTION_DEBUG_EVENT` the stopped thread's context is read to classify
//!       the stop (`Dr6` on x86, the reported address on arm64). This is the path
//!       implemented below because it lets us arm/disarm registers on a genuinely
//!       stopped thread and works for a separate inferior process.
//!
//!   (b) **In-process vectored handler** — `AddVectoredExceptionHandler` catches
//!       `EXCEPTION_SINGLE_STEP`/`EXCEPTION_BREAKPOINT` for self-debugging,
//!       offered as `installVectoredHandler`; the register programming (`commit`)
//!       is shared with the debug-loop path.
//!
//! Guarding: every Win32 call sits behind `if (comptime is_target)` so this file
//! AST-checks and *links* on non-Windows hosts (the `kernel32` externs in
//! `windows_platform.zig` are never referenced there) while `select()` in
//! `controller.zig` only ever routes here on Windows. Off-target, every
//! operation degrades to `HwError.Unsupported`. Encoding lives in
//! `windows_regs.zig`; OS-ABI layout + externs in `windows_platform.zig`.

const std = @import("std");
const di = @import("../debug_info.zig");
const ctrl = @import("controller.zig");
const regs = @import("windows_regs.zig");
const plat = @import("windows_platform.zig");

const HwStop = ctrl.HwStop;
const HwError = ctrl.HwError;
const HwBreakpointController = ctrl.HwBreakpointController;

const is_target = plat.is_target;
const is_x86 = plat.is_x86;
const is_arm64 = plat.is_arm64;
const win = plat; // kernel32 externs + constants live in the platform module
const x64 = plat.x64;
const a64 = plat.a64;
const ContextBuf = plat.ContextBuf;

const slot_count = regs.slot_count;
const watch_flag = regs.watch_flag;
const Dr7Slot = regs.Dr7Slot;

/// Per-slot arming state. On x86 all four map to DR0-DR3 (shared exec+watch);
/// on arm64 `slots` is the BVR exec bank and `wslots` the WVR watch bank.
const SlotState = struct {
    active: bool = false,
    addr: u64 = 0,
    is_exec: bool = true,
    kind: di.WatchKind = .write,
    bytes: u16 = 1,
};

pub const WindowsController = struct {
    pid: u32 = 0,
    attached: bool = false,
    proc: ?*anyopaque = null,
    /// Handle of the thread whose context we program. Refreshed to the thread
    /// that most recently stopped in the debug loop.
    thread: ?plat.HANDLE = null,
    /// Thread id of the most recent debug event, needed to acknowledge it via
    /// `ContinueDebugEvent`.
    last_tid: u32 = 0,
    /// x86: DR0-DR3 shared pool. arm64: BVR exec bank.
    slots: [slot_count]SlotState = [_]SlotState{.{}} ** slot_count,
    /// arm64 only: WVR watch bank. Unused on x86.
    wslots: [slot_count]SlotState = [_]SlotState{.{}} ** slot_count,

    pub fn init() WindowsController {
        return .{};
    }

    /// Type-erased controller the native target drives.
    pub fn controller(self: *WindowsController) HwBreakpointController {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = HwBreakpointController.VTable{
        .capabilities = capabilitiesImpl,
        .attach = attachImpl,
        .armExec = armExecImpl,
        .armWatch = armWatchImpl,
        .disarm = disarmImpl,
        .cont = contImpl,
        .singleStep = singleStepImpl,
        .readRegister = readRegisterImpl,
        .readMemory = readMemoryImpl,
        .writeMemory = writeMemoryImpl,
        .deinit = deinitImpl,
    };

    fn cast(ptr: *anyopaque) *WindowsController {
        return @ptrCast(@alignCast(ptr));
    }

    // -- context programming --------------------------------------------------

    fn getContext(self: *WindowsController, out: *ContextBuf) HwError!void {
        if (comptime is_target) {
            const th = self.thread orelse return HwError.NotStopped;
            out.setU32(plat.off_flags, plat.ctx_flags);
            if (win.GetThreadContext(th, &out.bytes) == 0) return HwError.Unsupported;
            return;
        }
        return HwError.Unsupported;
    }

    fn setContext(self: *WindowsController, buf: *ContextBuf) HwError!void {
        if (comptime is_target) {
            const th = self.thread orelse return HwError.NotStopped;
            buf.setU32(plat.off_flags, plat.ctx_flags);
            if (win.SetThreadContext(th, &buf.bytes) == 0) return HwError.Unsupported;
            return;
        }
        return HwError.Unsupported;
    }

    /// Rebuild the debug registers from slot state and commit them to the
    /// stopped thread.
    fn commit(self: *WindowsController) HwError!void {
        if (comptime is_x86) {
            var ctx = ContextBuf{};
            try self.getContext(&ctx);
            var cfgs: [slot_count]Dr7Slot = [_]Dr7Slot{.{}} ** slot_count;
            var n: u8 = 0;
            while (n < slot_count) : (n += 1) {
                const s = self.slots[n];
                ctx.setU64(x64.drOffset(n), if (s.active) s.addr else 0);
                if (!s.active) continue;
                cfgs[n] = .{
                    .enabled = true,
                    .rw = if (s.is_exec) .exec else regs.rwForWatch(s.kind),
                    .len = if (s.is_exec) .one else try regs.lenForBytes(s.bytes),
                };
            }
            ctx.setU64(x64.off_dr7, regs.packDr7(cfgs));
            ctx.setU64(x64.off_dr6, 0); // clear stale status
            try self.setContext(&ctx);
            return;
        } else if (comptime is_arm64) {
            var ctx = ContextBuf{};
            try self.getContext(&ctx);
            var n: u8 = 0;
            while (n < slot_count) : (n += 1) {
                const e = self.slots[n];
                ctx.setU64(a64.off_bvr + @as(usize, n) * 8, if (e.active) e.addr else 0);
                ctx.setU32(a64.off_bcr + @as(usize, n) * 4, regs.packBcr(e.active));
                if (n >= a64.watch_regs) continue; // hardware exposes only Wvr0/Wvr1
                const w = self.wslots[n];
                ctx.setU64(a64.off_wvr + @as(usize, n) * 8, if (w.active) w.addr else 0);
                ctx.setU32(a64.off_wcr + @as(usize, n) * 4, if (w.active) try regs.packWcr(true, w.kind, w.bytes) else 0);
            }
            try self.setContext(&ctx);
            return;
        }
        return HwError.Unsupported;
    }

    fn freeIn(pool: []SlotState) HwError!u8 {
        for (pool, 0..) |s, i| {
            if (!s.active) return @intCast(i);
        }
        return HwError.SlotsExhausted;
    }

    // -- vtable impls ---------------------------------------------------------

    fn capabilitiesImpl(ptr: *anyopaque) di.HwCapabilities {
        _ = ptr;
        return .{
            .max_exec_breakpoints = slot_count,
            // x86 shares DR0-DR3 (up to four watch); arm64 exposes Wvr0/Wvr1.
            .max_watchpoints = if (is_arm64) a64.watch_regs else slot_count,
            .max_watch_bytes = 8,
            .single_step = true,
            .software_only = false,
        };
    }

    fn attachImpl(ptr: *anyopaque, pid: i32) anyerror!void {
        const self = cast(ptr);
        if (comptime is_target) {
            self.pid = @intCast(pid);
            if (win.DebugActiveProcess(self.pid) == 0) {
                return switch (win.GetLastError()) {
                    win.ERROR_ACCESS_DENIED => HwError.PermissionDenied,
                    else => HwError.Unsupported,
                };
            }
            self.proc = win.OpenProcess(win.PROCESS_VM_OPERATION | win.PROCESS_VM_READ | win.PROCESS_VM_WRITE, 0, self.pid);
            self.attached = true;
            // Drain to the first breakpoint the loader raises so a thread is
            // stopped and its context is safe to program.
            _ = try self.waitStop();
            return;
        }
        return HwError.Unsupported;
    }

    fn armExecImpl(ptr: *anyopaque, addr: u64) anyerror!u8 {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        const slot = try freeIn(&self.slots);
        self.slots[slot] = .{ .active = true, .addr = addr, .is_exec = true };
        try self.commit();
        return slot;
    }

    fn armWatchImpl(ptr: *anyopaque, addr: u64, len: u16, kind: di.WatchKind) anyerror!u8 {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        if (comptime is_arm64) {
            // arm64 watch uses the dedicated WVR bank (only WVR0/WVR1 exist).
            _ = try regs.basForBytes(len);
            var slot: u8 = 0;
            while (slot < a64.watch_regs) : (slot += 1) {
                if (!self.wslots[slot].active) break;
            } else return HwError.SlotsExhausted;
            self.wslots[slot] = .{ .active = true, .addr = addr, .is_exec = false, .kind = kind, .bytes = len };
            try self.commit();
            return watch_flag | slot;
        }
        // x86: watch shares the DR0-DR3 pool with exec.
        _ = try regs.lenForBytes(len);
        const slot = try freeIn(&self.slots);
        self.slots[slot] = .{ .active = true, .addr = addr, .is_exec = false, .kind = kind, .bytes = len };
        try self.commit();
        return slot;
    }

    fn disarmImpl(ptr: *anyopaque, slot: u8) anyerror!void {
        const self = cast(ptr);
        if ((slot & watch_flag) != 0) {
            const idx = slot & ~watch_flag;
            if (idx >= slot_count) return HwError.Unsupported;
            self.wslots[idx] = .{};
        } else {
            if (slot >= slot_count) return HwError.Unsupported;
            self.slots[slot] = .{};
        }
        try self.commit();
    }

    fn contImpl(ptr: *anyopaque) anyerror!HwStop {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        if (comptime is_target) {
            try self.setStepFlag(false);
            return self.resumeAndWait();
        }
        return HwError.Unsupported;
    }

    fn singleStepImpl(ptr: *anyopaque) anyerror!HwStop {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        if (comptime is_target) {
            try self.setStepFlag(true);
            return self.resumeAndWait();
        }
        return HwError.Unsupported;
    }

    /// Read a general register by ABI index — a context-field read from the
    /// leading integer-register area of the CONTEXT (8 bytes per register).
    fn readRegisterImpl(ptr: *anyopaque, index: u16) anyerror!u64 {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        var ctx = ContextBuf{};
        try self.getContext(&ctx);
        return ctx.getU64(plat.off_int_regs + @as(usize, index) * 8);
    }

    fn readMemoryImpl(ptr: *anyopaque, addr: u64, buf: []u8) anyerror!void {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        if (comptime is_target) {
            var read: usize = 0;
            if (win.ReadProcessMemory(self.proc, @ptrFromInt(@as(usize, @intCast(addr))), buf.ptr, buf.len, &read) == 0 or read != buf.len) {
                return HwError.Unsupported;
            }
            return;
        }
        return HwError.Unsupported;
    }

    fn writeMemoryImpl(ptr: *anyopaque, addr: u64, bytes: []const u8) anyerror!void {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        if (comptime is_target) {
            var wrote: usize = 0;
            if (win.WriteProcessMemory(self.proc, @ptrFromInt(@as(usize, @intCast(addr))), bytes.ptr, bytes.len, &wrote) == 0 or wrote != bytes.len) {
                return HwError.Unsupported;
            }
            return;
        }
        return HwError.Unsupported;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (comptime is_target) {
            if (self.thread) |th| _ = win.CloseHandle(th);
            if (self.proc) |p| _ = win.CloseHandle(@ptrCast(p));
            if (self.attached) _ = win.DebugActiveProcessStop(self.pid);
        }
        self.thread = null;
        self.proc = null;
        self.attached = false;
    }

    // -- stop harvesting ------------------------------------------------------

    fn setStepFlag(self: *WindowsController, enable: bool) HwError!void {
        if (comptime is_x86) {
            var ctx = ContextBuf{};
            try self.getContext(&ctx);
            const ef = ctx.getU32(x64.off_eflags);
            ctx.setU32(x64.off_eflags, if (enable) ef | x64.eflags_tf else ef & ~x64.eflags_tf);
            try self.setContext(&ctx);
            return;
        } else if (comptime is_arm64) {
            var ctx = ContextBuf{};
            try self.getContext(&ctx);
            const cp = ctx.getU32(a64.off_cpsr);
            ctx.setU32(a64.off_cpsr, if (enable) cp | a64.cpsr_ss else cp & ~a64.cpsr_ss);
            try self.setContext(&ctx);
            return;
        }
        return HwError.Unsupported;
    }

    fn resumeAndWait(self: *WindowsController) HwError!HwStop {
        if (comptime is_target) {
            if (self.thread) |th| _ = win.CloseHandle(th);
            self.thread = null;
            if (win.ContinueDebugEvent(self.pid, self.last_tid, win.DBG_CONTINUE) == 0) return HwError.Unsupported;
            return self.waitStop();
        }
        return HwError.Unsupported;
    }

    fn waitStop(self: *WindowsController) HwError!HwStop {
        if (comptime is_target) {
            var ev: [plat.dbg.size]u8 align(8) = [_]u8{0} ** plat.dbg.size;
            if (win.WaitForDebugEventEx(&ev, win.INFINITE) == 0) return HwError.Unsupported;
            const code = std.mem.readInt(u32, ev[plat.dbg.off_code..][0..4], .little);
            const tid = std.mem.readInt(u32, ev[plat.dbg.off_thread..][0..4], .little);
            self.last_tid = tid;
            if (code == plat.EXIT_PROCESS_DEBUG_EVENT) {
                const rc = std.mem.readInt(u32, ev[plat.dbg.off_exit_code..][0..4], .little);
                self.attached = false;
                return HwStop{ .exited = @bitCast(rc) };
            }
            // Refresh the stopped-thread handle so the caller can program it.
            self.thread = win.OpenThread(win.THREAD_ACCESS, 0, tid);
            if (code != plat.EXCEPTION_DEBUG_EVENT) {
                // Non-exception event (thread/dll create, output-string, etc.):
                // acknowledge and keep waiting for a real stop.
                if (win.ContinueDebugEvent(self.pid, tid, win.DBG_CONTINUE) == 0) return HwError.Unsupported;
                return self.waitStop();
            }
            const exc = std.mem.readInt(u32, ev[plat.dbg.off_exc_code..][0..4], .little);
            const exc_addr = std.mem.readInt(u64, ev[plat.dbg.off_exc_addr..][0..8], .little);
            return self.classify(exc, exc_addr);
        }
        return HwError.Unsupported;
    }

    /// Classify a debug exception into a `HwStop` using the stopped thread's
    /// debug-status registers (x86 `Dr6`) or the faulting address (arm64).
    fn classify(self: *WindowsController, exc: u32, exc_addr: u64) HwError!HwStop {
        if (comptime is_x86) {
            // x86 uses Dr6 (not the faulting address) to identify the slot.
            var ctx = ContextBuf{};
            try self.getContext(&ctx);
            const dr6 = ctx.getU64(x64.off_dr6);
            ctx.setU64(x64.off_dr6, 0);
            try self.setContext(&ctx);
            var n: u8 = 0;
            while (n < slot_count) : (n += 1) {
                if ((dr6 & (@as(u64, 1) << @intCast(n))) == 0) continue;
                const s = self.slots[n];
                if (!s.active) continue;
                if (s.is_exec) return HwStop{ .exec = n };
                return HwStop{ .watch = .{ .slot = n, .addr = s.addr } };
            }
            if (exc == plat.EXCEPTION_SINGLE_STEP or (dr6 & (@as(u64, 1) << 14)) != 0) return HwStop.step;
            return HwStop{ .signal = exc };
        } else if (comptime is_arm64) {
            // arm64 reports the faulting address; match it against armed slots.
            var n: u8 = 0;
            while (n < slot_count) : (n += 1) {
                if (self.slots[n].active and self.slots[n].addr == exc_addr) return HwStop{ .exec = n };
            }
            n = 0;
            while (n < a64.watch_regs) : (n += 1) {
                const w = self.wslots[n];
                if (w.active and exc_addr >= w.addr and exc_addr < w.addr + w.bytes) {
                    return HwStop{ .watch = .{ .slot = watch_flag | n, .addr = w.addr } };
                }
            }
            if (exc == plat.EXCEPTION_SINGLE_STEP) return HwStop.step;
            return HwStop{ .signal = exc };
        } else {
            return HwStop{ .signal = exc };
        }
    }
};

/// Install an in-process vectored exception handler (delivery path (b)) for
/// self-debugging hosts. Returns the opaque handle Windows assigns, or
/// `Unsupported` off-target. Register programming (`commit`) is shared with the
/// debug-loop path; the handler only needs to translate the OS exception.
pub fn installVectoredHandler(handler: *const anyopaque) HwError!*anyopaque {
    if (comptime is_target) {
        return win.AddVectoredExceptionHandler(1, handler) orelse HwError.Unsupported;
    }
    return HwError.Unsupported;
}

// -- tests --------------------------------------------------------------------

test {
    // Pull the encoding + platform modules' tests into this file's test set.
    std.testing.refAllDecls(@This());
    _ = regs;
    _ = plat;
}

test "capabilities advertise four exec slots, single-step, hardware-backed" {
    var c = WindowsController.init();
    const caps = c.controller().capabilities();
    try std.testing.expectEqual(@as(u8, 4), caps.max_exec_breakpoints);
    try std.testing.expectEqual(@as(u16, 8), caps.max_watch_bytes);
    try std.testing.expect(caps.single_step);
    try std.testing.expect(!caps.software_only);
}

test "off-target operations degrade to NotStopped instead of pretending" {
    if (is_target) return error.SkipZigTest;
    var c = WindowsController.init();
    const hw = c.controller();
    // Not attached: arming reports NotStopped rather than smoke-succeeding.
    try std.testing.expectError(HwError.NotStopped, hw.armExec(0x4000));
    try std.testing.expectError(HwError.NotStopped, hw.armWatch(0x4000, 8, .write));
    hw.deinit();
}
