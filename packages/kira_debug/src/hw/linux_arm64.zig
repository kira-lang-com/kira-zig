//! `HwBreakpointController` for **Linux / aarch64**, driven over `ptrace`.
//!
//! ARMv8 debug registers are exposed to a tracer as two regsets:
//!   * `NT_ARM_HW_BREAK` — the DBGBVR/DBGBCR pairs (execution breakpoints)
//!   * `NT_ARM_HW_WATCH` — the DBGWVR/DBGWCR pairs (data watchpoints)
//! Each is read/written whole via `PTRACE_GETREGSET`/`PTRACE_SETREGSET` using a
//! `struct user_hwdebug_state` payload. Debug exceptions surface to the tracer as
//! `SIGTRAP` reported by `waitpid`; the `si_code`/`si_addr` from `PTRACE_GETSIGINFO`
//! plus the stopped `PC` tell us which slot fired. Single-stepping is
//! `PTRACE_SINGLESTEP`. Memory is peeked/poked word-by-word.
//!
//! Header citations (Linux, arch/arm64):
//!   * `NT_ARM_HW_BREAK`/`NT_ARM_HW_WATCH`  — include/uapi/linux/elf.h
//!   * `struct user_hwdebug_state`          — arch/arm64/include/uapi/asm/ptrace.h
//!   * ctrl-reg encode (len<<5|type<<3|priv<<1|en) — arch/arm64/include/asm/hw_breakpoint.h
//!                                                    arch/arm64/kernel/hw_breakpoint.c:encode_ctrl_reg
//!   * `TRAP_HWBKPT`/`TRAP_TRACE`/`TRAP_BRKPT` — include/uapi/asm-generic/siginfo.h
//!
//! On non-linux-aarch64 hosts this file still *compiles* (every symbol used lives
//! unconditionally in `std.os.linux`); the syscalls would simply fault if invoked.
//! `controller.zig`'s target dispatch only ever hands out this impl on the real
//! target, so the guard is structural, not a runtime branch here.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const di = @import("../debug_info.zig");
const ctrl_mod = @import("controller.zig");
const HwBreakpointController = ctrl_mod.HwBreakpointController;
const HwStop = ctrl_mod.HwStop;
const HwError = ctrl_mod.HwError;

const native_endian = builtin.cpu.arch.endian();

// ---------------------------------------------------------------------------
// Kernel constants + structs (cited above)
// ---------------------------------------------------------------------------

/// General-purpose register set (`struct user_pt_regs`) — used to read `PC`.
const NT_PRSTATUS: usize = 1;
/// DBGBVR/DBGBCR execution-breakpoint regset.
const NT_ARM_HW_BREAK: usize = 0x403;
/// DBGWVR/DBGWCR data-watchpoint regset.
const NT_ARM_HW_WATCH: usize = 0x404;

/// `si_code` values carried by a `SIGTRAP` (asm-generic/siginfo.h).
const TRAP_BRKPT: i32 = 1; // process breakpoint (BRK software trap)
const TRAP_TRACE: i32 = 2; // process trace trap (single-step)
const TRAP_HWBKPT: i32 = 4; // hardware breakpoint/watchpoint

/// Privilege field (PMC/PAC) values — arch/arm64/include/asm/hw_breakpoint.h.
const AARCH64_BREAKPOINT_EL0: u2 = 2;

/// `type`/LSC field values.
const ARM_BREAKPOINT_EXECUTE: u2 = 0;
const ARM_BREAKPOINT_LOAD: u2 = 1;
const ARM_BREAKPOINT_STORE: u2 = 2;

/// A 4-byte A64 instruction match: BAS low nibble set.
const ARM_BREAKPOINT_LEN_4: u8 = 0xf;

/// Kernel caps arm64 debug slots at 16 per class.
const MAX_HW: usize = 16;

/// Best-effort defaults when the tracee has not been probed yet. Real counts are
/// read from `dbg_info` of the regset at attach time and override these.
const DEFAULT_MAX_EXEC: u8 = 6;
const DEFAULT_MAX_WATCH: u8 = 4;
const MAX_WATCH_BYTES: u16 = 8;

/// High bit distinguishes a watchpoint slot id from an exec slot id in the single
/// `u8` slot namespace the `HwBreakpointController` vtable exposes (`disarm(slot)`
/// takes one integer for both classes; `armExec`/`armWatch` return ids from it and
/// `HwStop.exec`/`HwStop.watch.slot` report the same encoded id).
const WATCH_FLAG: u8 = 0x80;

/// One DBGBVR+DBGBCR (or DBGWVR+DBGWCR) pair as laid out in the regset.
/// `arch/arm64/include/uapi/asm/ptrace.h`.
const HwDebugReg = extern struct {
    addr: u64 = 0,
    ctrl: u32 = 0,
    pad: u32 = 0,
};

/// `struct user_hwdebug_state` — payload for the HW_BREAK/HW_WATCH regsets.
/// `dbg_info` low byte is the register count; bits [8:13] the debug arch version.
const UserHwDebugState = extern struct {
    dbg_info: u32 = 0,
    pad: u32 = 0,
    dbg_regs: [MAX_HW]HwDebugReg = [_]HwDebugReg{.{}} ** MAX_HW,
};

/// `struct user_pt_regs` — 31 GPRs then sp/pc/pstate.
const UserPtRegs = extern struct {
    regs: [31]u64 = [_]u64{0} ** 31,
    sp: u64 = 0,
    pc: u64 = 0,
    pstate: u64 = 0,
};

/// Register indices used by `readRegister`: 0..30 GPRs, 31 sp, 32 pc, 33 pstate.
const REG_SP: u16 = 31;
const REG_PC: u16 = 32;
const REG_PSTATE: u16 = 33;

/// Encoded DBGBCR/DBGWCR control word.
/// `val = (len << 5) | (type << 3) | (privilege << 1) | enabled`
/// (arch/arm64/kernel/hw_breakpoint.c:encode_ctrl_reg).
const DbgCtrl = packed struct(u32) {
    enabled: bool = false,
    privilege: u2 = 0,
    load_store: u2 = 0,
    length: u8 = 0,
    _reserved: u19 = 0,

    fn word(self: DbgCtrl) u32 {
        return @bitCast(self);
    }

    /// Enabled EL0 execution breakpoint over a 4-byte A64 instruction.
    fn exec() DbgCtrl {
        return .{
            .enabled = true,
            .privilege = AARCH64_BREAKPOINT_EL0,
            .load_store = ARM_BREAKPOINT_EXECUTE,
            .length = ARM_BREAKPOINT_LEN_4,
        };
    }

    /// Enabled EL0 watchpoint with byte-address-select `bas` and access `ls`.
    fn watch(bas: u8, ls: u2) DbgCtrl {
        return .{
            .enabled = true,
            .privilege = AARCH64_BREAKPOINT_EL0,
            .load_store = ls,
            .length = bas,
        };
    }
};

fn lscForKind(kind: di.WatchKind) u2 {
    return switch (kind) {
        .read => ARM_BREAKPOINT_LOAD,
        .write => ARM_BREAKPOINT_STORE,
        .read_write => ARM_BREAKPOINT_LOAD | ARM_BREAKPOINT_STORE,
    };
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

pub const LinuxArm64Controller = struct {
    pid: linux.pid_t = 0,
    attached: bool = false,
    max_exec: u8 = DEFAULT_MAX_EXEC,
    max_watch: u8 = DEFAULT_MAX_WATCH,

    exec_active: [MAX_HW]bool = [_]bool{false} ** MAX_HW,
    exec_addr: [MAX_HW]u64 = [_]u64{0} ** MAX_HW,

    watch_active: [MAX_HW]bool = [_]bool{false} ** MAX_HW,
    /// Doubleword-aligned base actually programmed into DBGWVR.
    watch_base: [MAX_HW]u64 = [_]u64{0} ** MAX_HW,
    /// The caller's requested address, for `si_addr` matching on a stop.
    watch_req: [MAX_HW]u64 = [_]u64{0} ** MAX_HW,
    watch_len: [MAX_HW]u16 = [_]u16{0} ** MAX_HW,
    /// Access encoding (LSC) captured at arm time, replayed on each `flush`.
    watch_kind: [MAX_HW]u2 = [_]u2{ARM_BREAKPOINT_LOAD | ARM_BREAKPOINT_STORE} ** MAX_HW,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn controller(self: *Self) HwBreakpointController {
        return .{ .ptr = self, .vtable = &vtable };
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

    fn from(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    // --- capability -------------------------------------------------------

    fn vtCapabilities(ctx: *anyopaque) di.HwCapabilities {
        const self = from(ctx);
        return .{
            .max_exec_breakpoints = self.max_exec,
            .max_watchpoints = self.max_watch,
            .max_watch_bytes = MAX_WATCH_BYTES,
            .single_step = true,
            .software_only = false,
        };
    }

    // --- attach -----------------------------------------------------------

    fn vtAttach(ctx: *anyopaque, pid: i32) anyerror!void {
        const self = from(ctx);
        self.pid = pid;
        self.attached = true;
        // If the tracee dies, take it with us rather than leaking a stopped
        // process. Best-effort — an older kernel without the option is fine.
        _ = ptraceRaw(linux.PTRACE.SETOPTIONS, pid, 0, linux.PTRACE.O.EXITKILL);
        // Probe the true slot counts from each regset's dbg_info. On failure we
        // keep the conservative arm64 defaults.
        if (self.readDebugState(NT_ARM_HW_BREAK)) |st| {
            const n: u8 = @truncate(st.dbg_info & 0xff);
            if (n > 0) self.max_exec = @min(n, @as(u8, @intCast(MAX_HW)));
        } else |_| {}
        if (self.readDebugState(NT_ARM_HW_WATCH)) |st| {
            const n: u8 = @truncate(st.dbg_info & 0xff);
            if (n > 0) self.max_watch = @min(n, @as(u8, @intCast(MAX_HW)));
        } else |_| {}
        // Start from a clean slate: forget any stale arming.
        self.exec_active = [_]bool{false} ** MAX_HW;
        self.watch_active = [_]bool{false} ** MAX_HW;
        try self.flush(.exec);
        try self.flush(.watch);
    }

    // --- arming -----------------------------------------------------------

    fn vtArmExec(ctx: *anyopaque, addr: u64) anyerror!u8 {
        const self = from(ctx);
        if (!self.attached) return HwError.NotStopped;
        var i: usize = 0;
        while (i < self.max_exec) : (i += 1) {
            if (!self.exec_active[i]) {
                self.exec_active[i] = true;
                self.exec_addr[i] = addr;
                try self.flush(.exec);
                return @intCast(i);
            }
        }
        return HwError.SlotsExhausted;
    }

    fn vtArmWatch(ctx: *anyopaque, addr: u64, len: u16, kind: di.WatchKind) anyerror!u8 {
        const self = from(ctx);
        if (!self.attached) return HwError.NotStopped;
        var i: usize = 0;
        while (i < self.max_watch) : (i += 1) {
            if (!self.watch_active[i]) {
                self.watch_active[i] = true;
                self.watch_base[i] = addr & ~@as(u64, 7);
                self.watch_req[i] = addr;
                self.watch_len[i] = len;
                self.watch_kind[i] = lscForKind(kind);
                try self.flush(.watch);
                return WATCH_FLAG | @as(u8, @intCast(i));
            }
        }
        return HwError.SlotsExhausted;
    }

    fn vtDisarm(ctx: *anyopaque, slot: u8) anyerror!void {
        const self = from(ctx);
        if (slot & WATCH_FLAG != 0) {
            const i = slot & ~WATCH_FLAG;
            if (i >= MAX_HW) return HwError.Unsupported;
            self.watch_active[i] = false;
            try self.flush(.watch);
        } else {
            if (slot >= MAX_HW) return HwError.Unsupported;
            self.exec_active[slot] = false;
            try self.flush(.exec);
        }
    }

    // --- execution --------------------------------------------------------

    fn vtCont(ctx: *anyopaque) anyerror!HwStop {
        const self = from(ctx);
        if (!self.attached) return HwError.NotStopped;
        _ = try ptraceChecked(linux.PTRACE.CONT, self.pid, 0, 0);
        return self.waitStop();
    }

    fn vtSingleStep(ctx: *anyopaque) anyerror!HwStop {
        const self = from(ctx);
        if (!self.attached) return HwError.NotStopped;
        _ = try ptraceChecked(linux.PTRACE.SINGLESTEP, self.pid, 0, 0);
        return self.waitStop();
    }

    // --- register / memory ------------------------------------------------

    fn vtReadRegister(ctx: *anyopaque, index: u16) anyerror!u64 {
        const self = from(ctx);
        if (!self.attached) return HwError.NotStopped;
        const regs = try self.readGpr();
        return switch (index) {
            REG_SP => regs.sp,
            REG_PC => regs.pc,
            REG_PSTATE => regs.pstate,
            else => if (index < 31) regs.regs[index] else HwError.Unsupported,
        };
    }

    fn vtReadMemory(ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void {
        const self = from(ctx);
        if (!self.attached) return HwError.NotStopped;
        var off: usize = 0;
        while (off < buf.len) {
            const word = try self.peekWord(addr + off);
            const n = @min(@sizeOf(u64), buf.len - off);
            @memcpy(buf[off .. off + n], std.mem.asBytes(&word)[0..n]);
            off += n;
        }
    }

    fn vtWriteMemory(ctx: *anyopaque, addr: u64, bytes: []const u8) anyerror!void {
        const self = from(ctx);
        if (!self.attached) return HwError.NotStopped;
        var off: usize = 0;
        while (off < bytes.len) {
            const n = @min(@sizeOf(u64), bytes.len - off);
            var word: u64 = 0;
            // Partial final word: read-modify-write so neighbouring bytes survive.
            if (n < @sizeOf(u64)) word = try self.peekWord(addr + off);
            @memcpy(std.mem.asBytes(&word)[0..n], bytes[off .. off + n]);
            try self.pokeWord(addr + off, word);
            off += n;
        }
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self = from(ctx);
        if (!self.attached) return;
        // Best-effort: clear every armed slot so a detached tracee does not keep
        // firing debug exceptions.
        self.exec_active = [_]bool{false} ** MAX_HW;
        self.watch_active = [_]bool{false} ** MAX_HW;
        self.flush(.exec) catch {};
        self.flush(.watch) catch {};
        self.attached = false;
    }

    // --- internals --------------------------------------------------------

    const RegClass = enum { exec, watch };

    /// Rebuild and push the whole regset for a class from our slot arrays.
    fn flush(self: *Self, class: RegClass) HwError!void {
        var st = UserHwDebugState{};
        switch (class) {
            .exec => {
                var i: usize = 0;
                while (i < MAX_HW) : (i += 1) {
                    if (self.exec_active[i]) {
                        st.dbg_regs[i].addr = self.exec_addr[i];
                        st.dbg_regs[i].ctrl = DbgCtrl.exec().word();
                    }
                }
                try self.writeDebugState(NT_ARM_HW_BREAK, &st);
            },
            .watch => {
                var i: usize = 0;
                while (i < MAX_HW) : (i += 1) {
                    if (self.watch_active[i]) {
                        st.dbg_regs[i].addr = self.watch_base[i];
                        st.dbg_regs[i].ctrl = self.watchCtrl(i).word();
                    }
                }
                try self.writeDebugState(NT_ARM_HW_WATCH, &st);
            },
        }
    }

    /// Byte-address-select mask + access encoding for a watch slot. The mask
    /// selects the requested bytes within the doubleword the watchpoint covers.
    /// A watch straddling two doublewords is clamped to the first; the caller
    /// (higher layer) may allocate a second slot for the remainder.
    fn watchCtrl(self: *Self, i: usize) DbgCtrl {
        const offset: u4 = @intCast(self.watch_req[i] & 7);
        var len: u16 = self.watch_len[i];
        if (len == 0) len = 1;
        if (len > 8) len = 8;
        const span: u16 = @min(len, @as(u16, 8) - offset);
        const bits: u16 = (@as(u16, 1) << @as(u4, @intCast(span))) - 1;
        const bas: u8 = @truncate(bits << offset);
        return DbgCtrl.watch(bas, self.watch_kind[i]);
    }

    fn readDebugState(self: *Self, note: usize) HwError!UserHwDebugState {
        var st = UserHwDebugState{};
        var iov = posix.iovec{ .base = @ptrCast(&st), .len = @sizeOf(UserHwDebugState) };
        _ = try ptraceChecked(linux.PTRACE.GETREGSET, self.pid, note, @intFromPtr(&iov));
        return st;
    }

    fn writeDebugState(self: *Self, note: usize, st: *UserHwDebugState) HwError!void {
        var iov = posix.iovec{ .base = @ptrCast(st), .len = @sizeOf(UserHwDebugState) };
        _ = try ptraceChecked(linux.PTRACE.SETREGSET, self.pid, note, @intFromPtr(&iov));
    }

    fn readGpr(self: *Self) HwError!UserPtRegs {
        var regs = UserPtRegs{};
        var iov = posix.iovec{ .base = @ptrCast(&regs), .len = @sizeOf(UserPtRegs) };
        _ = try ptraceChecked(linux.PTRACE.GETREGSET, self.pid, NT_PRSTATUS, @intFromPtr(&iov));
        return regs;
    }

    fn peekWord(self: *Self, addr: u64) HwError!u64 {
        var word: u64 = 0;
        // Raw PTRACE_PEEKDATA writes the fetched word to *data and returns 0/-errno.
        _ = try ptraceChecked(linux.PTRACE.PEEKDATA, self.pid, @intCast(addr), @intFromPtr(&word));
        return word;
    }

    fn pokeWord(self: *Self, addr: u64, word: u64) HwError!void {
        _ = try ptraceChecked(linux.PTRACE.POKEDATA, self.pid, @intCast(addr), @intCast(word));
    }

    fn waitStop(self: *Self) HwError!HwStop {
        var status: u32 = 0;
        const wrc = linux.waitpid(self.pid, &status, 0);
        if (linux.errno(wrc) != .SUCCESS) return HwError.Unsupported;
        if (linux.W.IFEXITED(status)) return .{ .exited = linux.W.EXITSTATUS(status) };
        if (linux.W.IFSIGNALED(status)) return .{ .signal = @intFromEnum(linux.W.TERMSIG(status)) };
        if (linux.W.IFSTOPPED(status)) {
            const sig = linux.W.STOPSIG(status);
            if (sig == .TRAP) return self.classifyTrap();
            return .{ .signal = @intFromEnum(sig) };
        }
        return .{ .signal = 0 };
    }

    /// Decide which slot (if any) a SIGTRAP belongs to. Matching the stopped PC
    /// against armed exec slots is authoritative for execution breakpoints;
    /// `si_addr` locates a watchpoint hit; `si_code == TRAP_TRACE` is a step.
    fn classifyTrap(self: *Self) HwError!HwStop {
        // Exec: PC lands exactly on the armed instruction address.
        if (self.readGpr()) |regs| {
            var i: usize = 0;
            while (i < MAX_HW) : (i += 1) {
                if (self.exec_active[i] and self.exec_addr[i] == regs.pc) {
                    return .{ .exec = @intCast(i) };
                }
            }
        } else |_| {}

        // Watch / step: consult siginfo.
        var si: [128]u8 = [_]u8{0} ** 128;
        const have_si = blk: {
            _ = ptraceChecked(linux.PTRACE.GETSIGINFO, self.pid, 0, @intFromPtr(&si)) catch break :blk false;
            break :blk true;
        };
        if (have_si) {
            const code = std.mem.readInt(i32, si[8..12], native_endian);
            // 64-bit siginfo places the fault address at offset 16.
            const fault = std.mem.readInt(u64, si[16..24], native_endian);
            if (code == TRAP_HWBKPT) {
                var i: usize = 0;
                while (i < MAX_HW) : (i += 1) {
                    if (self.watch_active[i]) {
                        const base = self.watch_base[i];
                        if (fault >= base and fault < base + 8) {
                            return .{ .watch = .{ .slot = WATCH_FLAG | @as(u8, @intCast(i)), .addr = fault } };
                        }
                    }
                }
            }
            if (code == TRAP_TRACE) return .step;
        }
        // A TRAP we do not own (software BRK, unmatched hw event): report the raw
        // signal so the session surfaces it rather than pretending a slot fired.
        return .{ .signal = @intFromEnum(linux.SIG.TRAP) };
    }
};

// ---------------------------------------------------------------------------
// ptrace helpers
// ---------------------------------------------------------------------------

fn ptraceRaw(req: u32, pid: linux.pid_t, addr: usize, data: usize) usize {
    return linux.ptrace(req, pid, addr, data, 0);
}

/// Run a ptrace request and translate the errno into a `HwError`.
fn ptraceChecked(req: u32, pid: linux.pid_t, addr: usize, data: usize) HwError!usize {
    const rc = linux.ptrace(req, pid, addr, data, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .PERM, .ACCES => HwError.PermissionDenied,
        .SRCH => HwError.NotStopped,
        .INVAL, .IO, .FAULT => HwError.Unsupported,
        else => HwError.Unsupported,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "DbgCtrl exec packs to the arm64 EL0 4-byte encoding (0x1e5)" {
    // (len 0xf << 5) | (type 0 << 3) | (priv 2 << 1) | en 1 = 0x1e5.
    try std.testing.expectEqual(@as(u32, 0x1e5), DbgCtrl.exec().word());
}

test "DbgCtrl watch packs BAS + LSC + priv + enable" {
    // 8-byte write watch: BAS 0xff, LSC store(2), priv EL0(2), enabled.
    // (0xff << 5) | (2 << 3) | (2 << 1) | 1 = 0x1ff5.
    const c = DbgCtrl.watch(0xff, ARM_BREAKPOINT_STORE);
    try std.testing.expectEqual(@as(u32, 0x1ff5), c.word());

    // read+write over one byte at offset 0: BAS 0x01, LSC 0b11.
    const c1 = DbgCtrl.watch(0x01, ARM_BREAKPOINT_LOAD | ARM_BREAKPOINT_STORE);
    // (0x01 << 5) | (3 << 3) | (2 << 1) | 1 = 0x20 | 0x18 | 4 | 1 = 0x3d.
    try std.testing.expectEqual(@as(u32, 0x3d), c1.word());
}

test "DbgCtrl bitfields round-trip through @bitCast" {
    const original = DbgCtrl{ .enabled = true, .privilege = 2, .load_store = 1, .length = 0x0f };
    const word = original.word();
    const back: DbgCtrl = @bitCast(word);
    try std.testing.expectEqual(original.enabled, back.enabled);
    try std.testing.expectEqual(original.privilege, back.privilege);
    try std.testing.expectEqual(original.load_store, back.load_store);
    try std.testing.expectEqual(original.length, back.length);
    try std.testing.expectEqual(@as(u19, 0), back._reserved);
}

test "regset struct sizes match the kernel uapi layout" {
    // struct user_hwdebug_state: u32 dbg_info + u32 pad + 16 * (u64 + u32 + u32).
    try std.testing.expectEqual(@as(usize, 8 + MAX_HW * 16), @sizeOf(UserHwDebugState));
    // struct user_pt_regs: 31 GPRs + sp + pc + pstate = 34 * u64.
    try std.testing.expectEqual(@as(usize, 34 * @sizeOf(u64)), @sizeOf(UserPtRegs));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(HwDebugReg));
}

test "capabilities advertise hardware arm64 defaults before attach" {
    var c = LinuxArm64Controller.init();
    const caps = c.controller().capabilities();
    try std.testing.expectEqual(@as(u8, DEFAULT_MAX_EXEC), caps.max_exec_breakpoints);
    try std.testing.expectEqual(@as(u8, DEFAULT_MAX_WATCH), caps.max_watchpoints);
    try std.testing.expectEqual(@as(u16, 8), caps.max_watch_bytes);
    try std.testing.expect(caps.single_step);
    try std.testing.expect(!caps.software_only);
}

test "slot id namespace keeps exec and watch disjoint" {
    // Exec ids never set the watch flag; watch ids always do.
    try std.testing.expect((0 & WATCH_FLAG) == 0);
    try std.testing.expect(((WATCH_FLAG | @as(u8, 3)) & WATCH_FLAG) != 0);
    try std.testing.expectEqual(@as(u8, 3), (WATCH_FLAG | @as(u8, 3)) & ~WATCH_FLAG);
}
