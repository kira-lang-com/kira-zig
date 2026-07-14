//! macOS / Apple-Silicon hardware-debug controller.
//!
//! Implements `HwBreakpointController` on top of Mach: execution breakpoints and
//! data watchpoints go through the AArch64 debug registers
//! (`BVR`/`BCR` and `WVR`/`WCR`) carried in the `ARM_DEBUG_STATE64` thread state,
//! and stops are caught as `EXC_BREAKPOINT` on a Mach exception port drained with
//! `mach_msg`. Single-step drives the AArch64 software-step machinery
//! (`MDSCR_EL1.SS` + `PSTATE.SS`).
//!
//! Primary use is same-process self-debug: the debugger logic runs on one thread
//! and the inferior code on another; the debugger thread blocks in `cont()` /
//! `singleStep()` draining the exception port while the inferior thread faults
//! into it. Cross-process debugging needs `task_for_pid`, which requires the
//! `com.apple.security.cs.debugger` entitlement (or root) — `attach()` reports
//! `PermissionDenied` when the kernel refuses, rather than pretending to attach.
//!
//! This file is only *compiled* on macOS-arm64 (selected at comptime by
//! `controller.zig`). It `ast-check`s cleanly on any host: every Mach symbol is
//! reached through `std.c` field access (resolved by Sema, not AstGen), and the
//! AArch64 register layout / XNU constants live in `darwin_arm64_regs.zig` and
//! `darwin_arm64_mach.zig` — no `@cImport` of macOS headers is required.
//!
//! Register-encoding math lives in `darwin_arm64_regs.zig`; the Mach exception
//! message layout lives in `darwin_arm64_mach.zig` (Core Law #5 split).
const std = @import("std");
const di = @import("../debug_info.zig");
const controller = @import("controller.zig");
const regs = @import("darwin_arm64_regs.zig");
const mach = @import("darwin_arm64_mach.zig");

const HwBreakpointController = controller.HwBreakpointController;
const HwStop = controller.HwStop;
const HwError = controller.HwError;

const ArmThreadState64 = regs.ArmThreadState64;
const ArmDebugState64 = regs.ArmDebugState64;

// Total AArch64 debug-register slots physically available on Apple Silicon.
const MAX_EXEC: u8 = 6;
const MAX_WATCH: u8 = 4;
const MAX_WATCH_BYTES: u16 = 8;

const Slot = struct {
    used: bool = false,
    addr: u64 = 0,
    len: u16 = 0,
    kind: di.WatchKind = .write,
};

/// macOS / Apple-Silicon `HwBreakpointController` implementation.
pub const DarwinArm64 = struct {
    /// Mach task port of the inferior (self by default).
    task: std.c.mach_port_t = 0,
    /// Thread whose debug registers we program.
    thread: std.c.thread_act_t = 0,
    /// Receive right for the exception port; 0 until `attach()`.
    exc_port: std.c.mach_port_t = 0,
    attached: bool = false,
    /// A stop is buffered: `cont()`/`singleStep()` must reply to resume it.
    reply_port: std.c.mach_port_t = 0,
    reply_bits: u32 = 0,
    reply_id: i32 = 0,
    have_pending: bool = false,

    exec: [MAX_EXEC]Slot = [_]Slot{.{}} ** MAX_EXEC,
    watch: [MAX_WATCH]Slot = [_]Slot{.{}} ** MAX_WATCH,

    pub fn init() DarwinArm64 {
        return .{};
    }

    pub fn controller(self: *DarwinArm64) HwBreakpointController {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ---- Mach state helpers ------------------------------------------------

    fn getThreadState(self: *DarwinArm64, state: *ArmThreadState64) HwError!void {
        var count: std.c.mach_msg_type_number_t = regs.ARM_THREAD_STATE64_COUNT;
        const kr = std.c.thread_get_state(
            self.thread,
            regs.ARM_THREAD_STATE64,
            @ptrCast(@alignCast(state)),
            &count,
        );
        if (kr != mach.KERN_SUCCESS) return HwError.NotStopped;
    }

    fn setThreadState(self: *DarwinArm64, state: *const ArmThreadState64) HwError!void {
        const kr = std.c.thread_set_state(
            self.thread,
            regs.ARM_THREAD_STATE64,
            @ptrCast(@constCast(@alignCast(state))),
            regs.ARM_THREAD_STATE64_COUNT,
        );
        if (kr != mach.KERN_SUCCESS) return HwError.NotStopped;
    }

    fn getDebugState(self: *DarwinArm64, state: *ArmDebugState64) HwError!void {
        var count: std.c.mach_msg_type_number_t = regs.ARM_DEBUG_STATE64_COUNT;
        const kr = std.c.thread_get_state(
            self.thread,
            regs.ARM_DEBUG_STATE64,
            @ptrCast(@alignCast(state)),
            &count,
        );
        if (kr != mach.KERN_SUCCESS) return HwError.NotStopped;
    }

    fn setDebugState(self: *DarwinArm64, state: *const ArmDebugState64) HwError!void {
        const kr = std.c.thread_set_state(
            self.thread,
            regs.ARM_DEBUG_STATE64,
            @ptrCast(@constCast(@alignCast(state))),
            regs.ARM_DEBUG_STATE64_COUNT,
        );
        if (kr != mach.KERN_SUCCESS) return HwError.PermissionDenied;
    }

    /// Push the current slot tables into the thread's `ARM_DEBUG_STATE64`.
    fn flushDebugRegisters(self: *DarwinArm64) HwError!void {
        var st: ArmDebugState64 = std.mem.zeroes(ArmDebugState64);
        try self.getDebugState(&st);
        for (0..st.bvr.len) |i| {
            st.bvr[i] = 0;
            st.bcr[i] = 0;
        }
        for (0..st.wvr.len) |i| {
            st.wvr[i] = 0;
            st.wcr[i] = 0;
        }
        for (self.exec, 0..) |slot, i| {
            if (!slot.used) continue;
            st.bvr[i] = regs.alignExec(slot.addr);
            st.bcr[i] = regs.encodeExecBcr();
        }
        for (self.watch, 0..) |slot, i| {
            if (!slot.used) continue;
            st.wvr[i] = regs.alignWatch(slot.addr);
            st.wcr[i] = regs.encodeWcr(slot.addr, slot.len, slot.kind);
        }
        try self.setDebugState(&st);
    }

    // ---- attach ------------------------------------------------------------

    fn setupExceptionPort(self: *DarwinArm64) HwError!void {
        const me = std.c.mach_task_self();
        var port: std.c.mach_port_name_t = 0;
        if (std.c.mach_port_allocate(me, .RECEIVE, &port) != mach.KERN_SUCCESS)
            return HwError.PermissionDenied;
        if (std.c.mach_port_insert_right(me, port, port, .MAKE_SEND) != mach.KERN_SUCCESS)
            return HwError.PermissionDenied;
        self.exc_port = port;

        const behavior: std.c.exception_behavior_t =
            @bitCast(mach.EXCEPTION_DEFAULT | mach.MACH_EXCEPTION_CODES);
        const kr = std.c.task_set_exception_ports(
            self.task,
            @bitCast(mach.EXC_MASK_BREAKPOINT),
            port,
            behavior,
            regs.ARM_THREAD_STATE64,
        );
        if (kr != mach.KERN_SUCCESS) return HwError.PermissionDenied;
    }

    fn doAttach(self: *DarwinArm64, pid: i32) HwError!void {
        const self_pid: i32 = @intCast(std.c.getpid());
        if (pid <= 0 or pid == self_pid) {
            // Same-process self-debug: our own task, the current thread.
            self.task = std.c.mach_task_self();
            self.thread = mach.mach_thread_self();
        } else {
            // Cross-process: needs the debugger entitlement or root.
            var target: std.c.mach_port_name_t = 0;
            const kr = std.c.task_for_pid(std.c.mach_task_self(), pid, &target);
            if (kr != mach.KERN_SUCCESS) return HwError.PermissionDenied;
            self.task = target;
            self.thread = try firstThread(target);
        }
        try self.setupExceptionPort();
        self.attached = true;
    }

    fn firstThread(task: std.c.mach_port_t) HwError!std.c.thread_act_t {
        var list: std.c.mach_port_array_t = undefined;
        var count: std.c.mach_msg_type_number_t = 0;
        if (std.c.task_threads(task, &list, &count) != mach.KERN_SUCCESS)
            return HwError.PermissionDenied;
        if (count == 0) return HwError.NotStopped;
        return list[0];
    }

    // ---- arm / disarm ------------------------------------------------------

    fn armExec(self: *DarwinArm64, addr: u64) HwError!u8 {
        if (!self.attached) return HwError.NotStopped;
        const idx = freeSlot(&self.exec) orelse return HwError.SlotsExhausted;
        self.exec[idx] = .{ .used = true, .addr = addr };
        errdefer self.exec[idx] = .{};
        try self.flushDebugRegisters();
        return @intCast(idx);
    }

    fn armWatch(self: *DarwinArm64, addr: u64, len: u16, kind: di.WatchKind) HwError!u8 {
        if (!self.attached) return HwError.NotStopped;
        if (len == 0 or len > MAX_WATCH_BYTES) return HwError.Unsupported;
        const idx = freeSlot(&self.watch) orelse return HwError.SlotsExhausted;
        self.watch[idx] = .{ .used = true, .addr = addr, .len = len, .kind = kind };
        errdefer self.watch[idx] = .{};
        try self.flushDebugRegisters();
        // Watch ids are offset by MAX_EXEC so one u8 identifies either class.
        return @intCast(idx + MAX_EXEC);
    }

    fn disarm(self: *DarwinArm64, slot: u8) HwError!void {
        if (slot < MAX_EXEC) {
            if (!self.exec[slot].used) return HwError.NotStopped;
            self.exec[slot] = .{};
        } else {
            const w = slot - MAX_EXEC;
            if (w >= MAX_WATCH or !self.watch[w].used) return HwError.NotStopped;
            self.watch[w] = .{};
        }
        try self.flushDebugRegisters();
    }

    // ---- run control -------------------------------------------------------

    /// Send the pending MIG reply (clearing the caught exception so the inferior
    /// thread resumes), if one is buffered.
    fn resumeInferior(self: *DarwinArm64) HwError!void {
        if (!self.have_pending) return;
        var reply: mach.ExcReply = std.mem.zeroes(mach.ExcReply);
        reply.header.msgh_bits = self.reply_bits & mach.MACH_MSGH_BITS_REMOTE_MASK;
        reply.header.msgh_size = @sizeOf(mach.ExcReply);
        reply.header.msgh_remote_port = self.reply_port;
        reply.header.msgh_local_port = std.c.MACH.PORT.NULL;
        reply.header.msgh_id = self.reply_id + mach.MIG_REPLY_ID_OFFSET;
        reply.ret_code = mach.KERN_SUCCESS;

        const opt = std.c.mach_msg_option_t{ .SEND = .{ .MSG = true } };
        const kr = std.c.mach_msg(
            &reply.header,
            opt,
            @sizeOf(mach.ExcReply),
            0,
            std.c.MACH.PORT.NULL,
            .NONE,
            std.c.MACH.PORT.NULL,
        );
        self.have_pending = false;
        if (kr != .SUCCESS) return HwError.NotStopped;
    }

    /// Block draining the exception port until the inferior faults, decode the
    /// stop, and buffer the reply for the next resume.
    fn waitForStop(self: *DarwinArm64) HwError!HwStop {
        var req: mach.ExcRequest = std.mem.zeroes(mach.ExcRequest);
        const opt = std.c.mach_msg_option_t{ .RCV = .{ .MSG = true } };
        const kr = std.c.mach_msg(
            &req.header,
            opt,
            0,
            @sizeOf(mach.ExcRequest),
            self.exc_port,
            .NONE,
            std.c.MACH.PORT.NULL,
        );
        if (kr != .SUCCESS) return HwError.NotStopped;

        // Buffer reply routing so the next cont()/step resumes this thread.
        self.reply_port = req.header.msgh_remote_port;
        self.reply_bits = req.header.msgh_bits;
        self.reply_id = req.header.msgh_id;
        self.have_pending = true;

        return self.decodeStop(&req);
    }

    /// Map an `EXC_BREAKPOINT` message to the slot that fired. `code[1]` carries
    /// the faulting address (the PC for an exec breakpoint, the accessed data
    /// address for a watchpoint).
    fn decodeStop(self: *DarwinArm64, req: *const mach.ExcRequest) HwStop {
        if (req.exception != mach.EXC_BREAKPOINT) {
            return .{ .signal = @bitCast(req.exception) };
        }
        const fault: u64 = @bitCast(req.code[1]);

        for (self.exec, 0..) |slot, i| {
            if (slot.used and regs.alignExec(slot.addr) == regs.alignExec(fault))
                return .{ .exec = @intCast(i) };
        }
        for (self.watch, 0..) |slot, i| {
            if (!slot.used) continue;
            const base = regs.alignWatch(slot.addr);
            if (fault >= base and fault < base + MAX_WATCH_BYTES)
                return .{ .watch = .{ .slot = @intCast(i), .addr = fault } };
        }
        // A BRK / software step with no owning hardware slot.
        return .{ .signal = @bitCast(req.exception) };
    }

    fn cont(self: *DarwinArm64) HwError!HwStop {
        if (!self.attached) return HwError.NotStopped;
        try self.resumeInferior();
        return self.waitForStop();
    }

    fn singleStep(self: *DarwinArm64) HwError!HwStop {
        if (!self.attached) return HwError.NotStopped;
        // Enable AArch64 software step: MDSCR_EL1.SS + PSTATE.SS, resume, and the
        // next instruction retirement raises EXC_BREAKPOINT (a step exception).
        var dbg: ArmDebugState64 = std.mem.zeroes(ArmDebugState64);
        try self.getDebugState(&dbg);
        dbg.mdscr_el1 |= regs.MDSCR_SS_BIT;
        try self.setDebugState(&dbg);

        var th: ArmThreadState64 = std.mem.zeroes(ArmThreadState64);
        try self.getThreadState(&th);
        th.cpsr |= regs.PSTATE_SS_BIT;
        try self.setThreadState(&th);

        try self.resumeInferior();
        const stop = try self.waitForStop();

        // Clear the step enable so we do not keep stepping.
        try self.getDebugState(&dbg);
        dbg.mdscr_el1 &= ~regs.MDSCR_SS_BIT;
        try self.setDebugState(&dbg);

        return switch (stop) {
            .signal => HwStop.step,
            else => stop,
        };
    }

    // ---- inspection --------------------------------------------------------

    fn readRegister(self: *DarwinArm64, index: u16) HwError!u64 {
        if (!self.attached) return HwError.NotStopped;
        var th: ArmThreadState64 = std.mem.zeroes(ArmThreadState64);
        try self.getThreadState(&th);
        switch (index) {
            0...28 => return th.x[index],
            29 => return th.fp,
            30 => return th.lr,
            31 => return th.sp,
            32 => return th.pc,
            33 => return th.cpsr,
            else => return HwError.Unsupported,
        }
    }

    fn readMemory(self: *DarwinArm64, addr: u64, buf: []u8) HwError!void {
        if (!self.attached) return HwError.NotStopped;
        if (buf.len == 0) return;
        var data: std.c.vm_offset_t = 0;
        var data_cnt: std.c.mach_msg_type_number_t = 0;
        const kr = std.c.mach_vm_read(self.task, addr, buf.len, &data, &data_cnt);
        if (kr != mach.KERN_SUCCESS) return HwError.PermissionDenied;
        const src: [*]const u8 = @ptrFromInt(data);
        const n = @min(buf.len, @as(usize, data_cnt));
        @memcpy(buf[0..n], src[0..n]);
        _ = std.c.vm_deallocate(std.c.mach_task_self(), data, data_cnt);
    }

    fn writeMemory(self: *DarwinArm64, addr: u64, bytes: []const u8) HwError!void {
        if (!self.attached) return HwError.NotStopped;
        if (bytes.len == 0) return;
        const kr = std.c.mach_vm_write(
            self.task,
            addr,
            @intFromPtr(bytes.ptr),
            @intCast(bytes.len),
        );
        if (kr != mach.KERN_SUCCESS) return HwError.PermissionDenied;
    }

    fn deinitImpl(self: *DarwinArm64) void {
        if (self.attached) {
            // Best-effort: clear debug registers before dropping the port.
            for (&self.exec) |*s| s.* = .{};
            for (&self.watch) |*s| s.* = .{};
            self.flushDebugRegisters() catch {};
        }
        if (self.exc_port != 0) {
            _ = std.c.mach_port_deallocate(std.c.mach_task_self(), self.exc_port);
            self.exc_port = 0;
        }
        self.* = .{};
    }
};

fn freeSlot(slots: []Slot) ?usize {
    for (slots, 0..) |s, i| {
        if (!s.used) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// VTable glue.
// ---------------------------------------------------------------------------

fn cast(ctx: *anyopaque) *DarwinArm64 {
    return @ptrCast(@alignCast(ctx));
}

fn vtCapabilities(ctx: *anyopaque) di.HwCapabilities {
    _ = ctx;
    return .{
        .max_exec_breakpoints = MAX_EXEC,
        .max_watchpoints = MAX_WATCH,
        .max_watch_bytes = MAX_WATCH_BYTES,
        .single_step = true,
        .software_only = false,
    };
}

fn vtAttach(ctx: *anyopaque, pid: i32) anyerror!void {
    return cast(ctx).doAttach(pid);
}
fn vtArmExec(ctx: *anyopaque, addr: u64) anyerror!u8 {
    return cast(ctx).armExec(addr);
}
fn vtArmWatch(ctx: *anyopaque, addr: u64, len: u16, kind: di.WatchKind) anyerror!u8 {
    return cast(ctx).armWatch(addr, len, kind);
}
fn vtDisarm(ctx: *anyopaque, slot: u8) anyerror!void {
    return cast(ctx).disarm(slot);
}
fn vtCont(ctx: *anyopaque) anyerror!HwStop {
    return cast(ctx).cont();
}
fn vtSingleStep(ctx: *anyopaque) anyerror!HwStop {
    return cast(ctx).singleStep();
}
fn vtReadRegister(ctx: *anyopaque, index: u16) anyerror!u64 {
    return cast(ctx).readRegister(index);
}
fn vtReadMemory(ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void {
    return cast(ctx).readMemory(addr, buf);
}
fn vtWriteMemory(ctx: *anyopaque, addr: u64, bytes: []const u8) anyerror!void {
    return cast(ctx).writeMemory(addr, bytes);
}
fn vtDeinit(ctx: *anyopaque) void {
    cast(ctx).deinitImpl();
}

const vtable = HwBreakpointController.VTable{
    .capabilities = vtCapabilities,
    .attach = vtAttach,
    .armExec = vtArmExec,
    .armWatch = vtArmWatch,
    .disarm = vtDisarm,
    .cont = vtCont,
    .singleStep = vtSingleStep,
    .readRegister = vtReadRegister,
    .readMemory = vtReadMemory,
    .writeMemory = vtWriteMemory,
    .deinit = vtDeinit,
};

// ---------------------------------------------------------------------------
// Tests — host-independent behavior (slot allocation, capability table). The
// register-encoding math is covered in `darwin_arm64_regs.zig`.
// ---------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
    _ = regs;
    _ = mach;
}

test "capabilities advertise the Apple-Silicon slot budget" {
    var ctrl = DarwinArm64.init();
    const caps = ctrl.controller().capabilities();
    try std.testing.expectEqual(@as(u8, 6), caps.max_exec_breakpoints);
    try std.testing.expectEqual(@as(u8, 4), caps.max_watchpoints);
    try std.testing.expectEqual(@as(u16, 8), caps.max_watch_bytes);
    try std.testing.expect(caps.single_step);
    try std.testing.expect(!caps.software_only);
}

test "freeSlot finds the first open slot and reports exhaustion" {
    var slots = [_]Slot{.{}} ** 3;
    try std.testing.expectEqual(@as(?usize, 0), freeSlot(&slots));
    slots[0].used = true;
    slots[1].used = true;
    try std.testing.expectEqual(@as(?usize, 2), freeSlot(&slots));
    slots[2].used = true;
    try std.testing.expectEqual(@as(?usize, null), freeSlot(&slots));
}

test "unattached controller rejects operations honestly" {
    var ctrl = DarwinArm64.init();
    const hw = ctrl.controller();
    try std.testing.expectError(HwError.NotStopped, hw.armExec(0x1000));
    try std.testing.expectError(HwError.NotStopped, hw.cont());
    try std.testing.expectError(HwError.NotStopped, hw.readRegister(0));
}
