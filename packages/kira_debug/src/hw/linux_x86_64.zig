//! `HwBreakpointController` implementation for Linux x86_64 using the CPU debug
//! registers DR0-DR3 (address slots) + DR7 (control) + DR6 (status).
//!
//! Two delivery paths exist on Linux for hardware breakpoints/watchpoints:
//!
//!   (a) **Cross-process via `ptrace`** — the debugger is a separate process
//!       that `PTRACE_ATTACH`es to (or seizes) the inferior, then pokes the
//!       per-thread debug-register area of `struct user` with `PTRACE_POKEUSER`
//!       at `offsetof(struct user, u_debugreg)`. DR0-DR3 hold linear addresses,
//!       DR7 enables slots and encodes each slot's R/W condition + length, DR6
//!       reports which slot fired. A hit raises `SIGTRAP`, harvested with
//!       `waitpid`; instruction stepping uses `PTRACE_SINGLESTEP`. This is the
//!       path implemented fully below.
//!
//!   (b) **Self-process via `perf_event_open`** — a process can watch itself by
//!       opening a `PERF_TYPE_BREAKPOINT` event (`bp_type` one of
//!       `HW_BREAKPOINT_X/R/W`, with `bp_addr`/`bp_len`) and receiving `SIGIO`
//!       (or reading the fd) when it fires. This avoids a second process but
//!       cannot single-step and is a different control model, so it is stubbed
//!       here with a clear `Unsupported` (see `armSelfPerf`). Wiring it is a
//!       follow-up; keeping this file self-contained and <600 lines takes
//!       priority.
//!
//! DR7 packing is defined locally (see `dr7`) rather than shared with the
//! aarch64 sibling because the x86 encoding (2-bit enable pairs + 4-bit
//! condition fields) has nothing in common with ARM's WCR/WVR layout; only the
//! *concept* — one control word gating N address slots — is shared.
//!
//! On non-Linux/non-x86_64 targets every operation returns `HwError.Unsupported`
//! so the file still AST-checks and links; `select()` in `controller.zig` never
//! routes here off-target, but the guard keeps a stray reference honest.

const std = @import("std");
const builtin = @import("builtin");
const di = @import("../debug_info.zig");
const ctrl = @import("controller.zig");

const HwStop = ctrl.HwStop;
const HwError = ctrl.HwError;
const HwBreakpointController = ctrl.HwBreakpointController;

const is_target = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;
const linux = std.os.linux;

/// Number of address debug registers (DR0-DR3).
pub const slot_count: u8 = 4;

/// `offsetof(struct user, u_debugreg)` on x86_64 Linux. `struct user` places the
/// 8-entry `u_debugreg[]` array at byte 848; DRn lives at `debugreg_offset+n*8`.
/// This constant is stable ABI (used by gdb, strace, lldb) and is the address we
/// hand to `PTRACE_PEEKUSER`/`PTRACE_POKEUSER`.
pub const debugreg_offset: usize = 848;

fn drOffset(index: u8) usize {
    return debugreg_offset + @as(usize, index) * 8;
}

// -- DR7 control-word encoding ------------------------------------------------

/// R/W condition field (2 bits per slot in DR7, at bit `16 + 4*n`).
///   00 execute, 01 write, 10 I/O (unused here), 11 read *or* write.
/// x86 has no read-only breakpoint, so `read` is encoded as `read_write`.
const Rw = enum(u2) { exec = 0b00, write = 0b01, read_write = 0b11 };

/// Length field (2 bits per slot in DR7, at bit `18 + 4*n`).
///   00 = 1 byte, 01 = 2 bytes, 11 = 4 bytes, 10 = 8 bytes. Note the swap of
/// 4/8 relative to the numeric value — this is the architectural encoding.
const Len = enum(u2) { one = 0b00, two = 0b01, four = 0b11, eight = 0b10 };

/// One slot's DR7 contribution.
pub const Dr7Slot = struct {
    enabled: bool = false,
    rw: Rw = .exec,
    len: Len = .one,
};

/// Local-enable bit for slot `n` lives at DR7 bit `2*n` (bit `2*n+1` is the
/// global-enable we leave clear — per-thread local is what ptrace wants).
fn localEnableBit(n: u8) u64 {
    return @as(u64, 1) << @intCast(2 * @as(u6, @intCast(n)));
}

/// Bit position of slot `n`'s R/W condition field in DR7.
fn condShift(n: u8) u6 {
    return @intCast(16 + 4 * @as(u6, @intCast(n)));
}

/// Pack four slot configs into a DR7 value. Bit 10 (reserved, must-be-1) is set
/// to match hardware expectations.
pub fn packDr7(slots: [slot_count]Dr7Slot) u64 {
    var v: u64 = 1 << 10; // reserved bit, architecturally read-as-one
    var n: u8 = 0;
    while (n < slot_count) : (n += 1) {
        const s = slots[n];
        if (!s.enabled) continue;
        v |= localEnableBit(n);
        const cond: u64 = (@as(u64, @intFromEnum(s.rw)) | (@as(u64, @intFromEnum(s.len)) << 2));
        v |= cond << condShift(n);
    }
    return v;
}

/// Map a requested watch length in bytes to the DR7 `Len` code, rejecting sizes
/// the hardware cannot express.
fn lenForBytes(bytes: u16) HwError!Len {
    return switch (bytes) {
        1 => .one,
        2 => .two,
        4 => .four,
        8 => .eight,
        else => HwError.Unsupported,
    };
}

/// Map a `WatchKind` to the DR7 `Rw` code. `read` degrades to `read_write`
/// because x86 debug registers cannot trap reads without also trapping writes.
fn rwForWatch(kind: di.WatchKind) Rw {
    return switch (kind) {
        .write => .write,
        .read, .read_write => .read_write,
    };
}

// -- Controller ---------------------------------------------------------------

const SlotState = struct {
    addr: u64 = 0,
    cfg: Dr7Slot = .{},
};

pub const LinuxX86Controller = struct {
    pid: linux.pid_t = -1,
    attached: bool = false,
    slots: [slot_count]SlotState = [_]SlotState{.{}} ** slot_count,

    pub fn init() LinuxX86Controller {
        return .{};
    }

    /// Build the type-erased controller the native target drives.
    pub fn controller(self: *LinuxX86Controller) HwBreakpointController {
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

    fn cast(ptr: *anyopaque) *LinuxX86Controller {
        return @ptrCast(@alignCast(ptr));
    }

    // -- ptrace primitives ----------------------------------------------------

    fn checkErrno(rc: usize) HwError!void {
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .PERM, .ACCES => return HwError.PermissionDenied,
            .SRCH => return HwError.NotStopped,
            else => return HwError.Unsupported,
        }
    }

    fn pokeUser(self: *LinuxX86Controller, offset: usize, value: u64) HwError!void {
        if (!is_target) return HwError.Unsupported;
        const rc = linux.ptrace(linux.PTRACE.POKEUSER, self.pid, offset, @intCast(value), 0);
        try checkErrno(rc);
    }

    fn peekUser(self: *LinuxX86Controller, offset: usize) HwError!u64 {
        if (!is_target) return HwError.Unsupported;
        var out: u64 = 0;
        const rc = linux.ptrace(linux.PTRACE.PEEKUSER, self.pid, offset, @intFromPtr(&out), 0);
        try checkErrno(rc);
        return out;
    }

    fn peekData(self: *LinuxX86Controller, addr: u64) HwError!u64 {
        if (!is_target) return HwError.Unsupported;
        var out: u64 = 0;
        const rc = linux.ptrace(linux.PTRACE.PEEKDATA, self.pid, @intCast(addr), @intFromPtr(&out), 0);
        try checkErrno(rc);
        return out;
    }

    fn pokeData(self: *LinuxX86Controller, addr: u64, value: u64) HwError!void {
        if (!is_target) return HwError.Unsupported;
        const rc = linux.ptrace(linux.PTRACE.POKEDATA, self.pid, @intCast(addr), @intCast(value), 0);
        try checkErrno(rc);
    }

    /// Recompute DR7 from current slot state and write it to the inferior.
    fn commitDr7(self: *LinuxX86Controller) HwError!void {
        var cfgs: [slot_count]Dr7Slot = undefined;
        var n: u8 = 0;
        while (n < slot_count) : (n += 1) cfgs[n] = self.slots[n].cfg;
        try self.pokeUser(drOffset(7), packDr7(cfgs));
    }

    fn freeSlot(self: *LinuxX86Controller) HwError!u8 {
        var n: u8 = 0;
        while (n < slot_count) : (n += 1) {
            if (!self.slots[n].cfg.enabled) return n;
        }
        return HwError.SlotsExhausted;
    }

    // -- vtable impls ---------------------------------------------------------

    fn capabilitiesImpl(ptr: *anyopaque) di.HwCapabilities {
        _ = ptr;
        return .{
            .max_exec_breakpoints = slot_count,
            .max_watchpoints = slot_count,
            .max_watch_bytes = 8,
            .single_step = true,
            .software_only = false,
        };
    }

    fn attachImpl(ptr: *anyopaque, pid: i32) anyerror!void {
        const self = cast(ptr);
        if (!is_target) return HwError.Unsupported;
        self.pid = pid;
        const rc = linux.ptrace(linux.PTRACE.ATTACH, pid, 0, 0, 0);
        try checkErrno(rc);
        // Consume the stop that ATTACH's SIGSTOP produces so the inferior is
        // known-stopped and its debug registers are safe to poke.
        var status: u32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        self.attached = true;
    }

    fn armExecImpl(ptr: *anyopaque, addr: u64) anyerror!u8 {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        const slot = try self.freeSlot();
        try self.pokeUser(drOffset(slot), addr);
        self.slots[slot] = .{ .addr = addr, .cfg = .{ .enabled = true, .rw = .exec, .len = .one } };
        try self.commitDr7();
        return slot;
    }

    fn armWatchImpl(ptr: *anyopaque, addr: u64, len: u16, kind: di.WatchKind) anyerror!u8 {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        const len_code = try lenForBytes(len);
        const slot = try self.freeSlot();
        try self.pokeUser(drOffset(slot), addr);
        self.slots[slot] = .{
            .addr = addr,
            .cfg = .{ .enabled = true, .rw = rwForWatch(kind), .len = len_code },
        };
        try self.commitDr7();
        return slot;
    }

    fn disarmImpl(ptr: *anyopaque, slot: u8) anyerror!void {
        const self = cast(ptr);
        if (slot >= slot_count) return HwError.Unsupported;
        self.slots[slot] = .{};
        try self.pokeUser(drOffset(slot), 0);
        try self.commitDr7();
    }

    fn contImpl(ptr: *anyopaque) anyerror!HwStop {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        if (!is_target) return HwError.Unsupported;
        const rc = linux.ptrace(linux.PTRACE.CONT, self.pid, 0, 0, 0);
        try checkErrno(rc);
        return self.wait(false);
    }

    fn singleStepImpl(ptr: *anyopaque) anyerror!HwStop {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        if (!is_target) return HwError.Unsupported;
        const rc = linux.ptrace(linux.PTRACE.SINGLESTEP, self.pid, 0, 0, 0);
        try checkErrno(rc);
        return self.wait(true);
    }

    /// Interpret `index` as a general-register slot: byte offset `index*8` into
    /// the leading `user_regs_struct` of `struct user`, read via `PEEKUSER`.
    fn readRegisterImpl(ptr: *anyopaque, index: u16) anyerror!u64 {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        return self.peekUser(@as(usize, index) * 8);
    }

    fn readMemoryImpl(ptr: *anyopaque, addr: u64, buf: []u8) anyerror!void {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        var done: usize = 0;
        while (done < buf.len) {
            const word_addr = addr + done;
            const word = try self.peekData(word_addr);
            const bytes = std.mem.asBytes(&word);
            const take = @min(@as(usize, 8), buf.len - done);
            @memcpy(buf[done .. done + take], bytes[0..take]);
            done += take;
        }
    }

    fn writeMemoryImpl(ptr: *anyopaque, addr: u64, bytes: []const u8) anyerror!void {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        var done: usize = 0;
        while (done < bytes.len) {
            const word_addr = addr + done;
            const take = @min(@as(usize, 8), bytes.len - done);
            var word: u64 = if (take < 8) try self.peekData(word_addr) else 0;
            const dst = std.mem.asBytes(&word);
            @memcpy(dst[0..take], bytes[done .. done + take]);
            try self.pokeData(word_addr, word);
            done += take;
        }
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (is_target and self.attached) {
            _ = linux.ptrace(linux.PTRACE.DETACH, self.pid, 0, 0, 0);
        }
        self.attached = false;
    }

    // -- stop harvesting ------------------------------------------------------

    fn wait(self: *LinuxX86Controller, stepping: bool) HwError!HwStop {
        if (!is_target) return HwError.Unsupported;
        var status: u32 = 0;
        _ = linux.waitpid(self.pid, &status, 0);
        if (linux.W.IFEXITED(status)) {
            self.attached = false;
            return HwStop{ .exited = linux.W.EXITSTATUS(status) };
        }
        if (linux.W.IFSIGNALED(status)) {
            self.attached = false;
            return HwStop{ .signal = @intFromEnum(linux.W.TERMSIG(status)) };
        }
        if (!linux.W.IFSTOPPED(status)) {
            return HwStop{ .signal = 0 };
        }
        const sig = linux.W.STOPSIG(status);
        if (sig != .TRAP) {
            return HwStop{ .signal = @intFromEnum(sig) };
        }
        // A debug exception: DR6 bits 0-3 (B0-B3) mark which slot fired; bit 14
        // (BS) marks a single-step. Read, classify, then clear DR6.
        const dr6 = try self.peekUser(drOffset(6));
        try self.pokeUser(drOffset(6), 0);
        var n: u8 = 0;
        while (n < slot_count) : (n += 1) {
            if ((dr6 & (@as(u64, 1) << @intCast(n))) == 0) continue;
            const s = self.slots[n];
            if (!s.cfg.enabled) continue;
            if (s.cfg.rw == .exec) return HwStop{ .exec = n };
            return HwStop{ .watch = .{ .slot = n, .addr = s.addr } };
        }
        if (stepping or (dr6 & (@as(u64, 1) << 14)) != 0) return HwStop.step;
        return HwStop{ .signal = @intFromEnum(sig) };
    }
};

/// The self-process `perf_event_open` path (see file header, path (b)) is not
/// yet wired. Callers wanting in-process hardware watchpoints get a clear
/// `Unsupported` rather than a silent no-op.
pub fn armSelfPerf(addr: u64, len: u16, kind: di.WatchKind) HwError!void {
    _ = addr;
    _ = len;
    _ = kind;
    return HwError.Unsupported;
}

// -- tests --------------------------------------------------------------------

test "packDr7 encodes an exec slot 0" {
    var slots = [_]Dr7Slot{.{}} ** slot_count;
    slots[0] = .{ .enabled = true, .rw = .exec, .len = .one };
    const v = packDr7(slots);
    try std.testing.expectEqual(@as(u64, 1), v & 0b1); // L0 set
    try std.testing.expectEqual(@as(u64, 0), (v >> 16) & 0b1111); // exec/1-byte
    try std.testing.expectEqual(@as(u64, 1), (v >> 10) & 1); // reserved bit
}

test "packDr7 encodes a write watch in slot 2, 4 bytes" {
    var slots = [_]Dr7Slot{.{}} ** slot_count;
    slots[2] = .{ .enabled = true, .rw = .write, .len = .four };
    const v = packDr7(slots);
    try std.testing.expectEqual(@as(u64, 1), (v >> 4) & 1); // L2 at bit 2*2=4
    const cond = (v >> (16 + 4 * 2)) & 0b1111;
    try std.testing.expectEqual(@as(u64, 0b1101), cond); // len=11(4B)<<2 | rw=01(write)
}

test "packDr7 encodes a read_write 8-byte watch in slot 3" {
    var slots = [_]Dr7Slot{.{}} ** slot_count;
    slots[3] = .{ .enabled = true, .rw = .read_write, .len = .eight };
    const v = packDr7(slots);
    try std.testing.expectEqual(@as(u64, 1), (v >> 6) & 1); // L3 at bit 2*3=6
    const cond = (v >> (16 + 4 * 3)) & 0b1111;
    try std.testing.expectEqual(@as(u64, 0b1011), cond); // len=10(8B)<<2 | rw=11(rw)
}

test "packDr7 disabled slots contribute nothing but reserved bit" {
    const slots = [_]Dr7Slot{.{}} ** slot_count;
    try std.testing.expectEqual(@as(u64, 1 << 10), packDr7(slots));
}

test "lenForBytes rejects unsupported widths" {
    try std.testing.expectError(HwError.Unsupported, lenForBytes(3));
    try std.testing.expectError(HwError.Unsupported, lenForBytes(16));
    try std.testing.expectEqual(Len.eight, try lenForBytes(8));
}

test "rwForWatch degrades read to read_write" {
    try std.testing.expectEqual(Rw.read_write, rwForWatch(.read));
    try std.testing.expectEqual(Rw.write, rwForWatch(.write));
    try std.testing.expectEqual(Rw.read_write, rwForWatch(.read_write));
}

test "drOffset lands on the u_debugreg array" {
    try std.testing.expectEqual(@as(usize, 848), drOffset(0));
    try std.testing.expectEqual(@as(usize, 904), drOffset(7));
    try std.testing.expectEqual(@as(usize, 896), drOffset(6));
}

test "capabilities advertise four hardware slots" {
    var c = LinuxX86Controller.init();
    const caps = c.controller().capabilities();
    try std.testing.expectEqual(@as(u8, 4), caps.max_exec_breakpoints);
    try std.testing.expectEqual(@as(u8, 4), caps.max_watchpoints);
    try std.testing.expectEqual(@as(u16, 8), caps.max_watch_bytes);
    try std.testing.expect(caps.single_step);
    try std.testing.expect(!caps.software_only);
}
