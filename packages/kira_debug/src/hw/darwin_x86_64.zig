//! `HwBreakpointController` for macOS on x86_64, driven through the Mach
//! debug-register facility. Execution breakpoints and data watchpoints both
//! live in the four debug address registers DR0-DR3; DR7 holds the per-register
//! enable/condition/length control fields and DR6 reports which condition fired.
//! We read/write these via `thread_get_state`/`thread_set_state` with the
//! `x86_DEBUG_STATE64` flavor, single-step through the RFLAGS trap (TF) bit, and
//! catch the resulting `EXC_BREAKPOINT` on a per-thread Mach exception port.
//!
//! Because DR0-DR3 are shared between exec breakpoints and watchpoints, slot
//! allocation is tracked across both classes (see `slots`). The file must
//! ast-check on any host, so every OS-touching entry point guards on the build
//! target and returns `HwError.Unsupported` off-target; the pure DR7/DR6 bit
//! logic is host-independent and unit-tested.
//!
//! Constant/struct citations (Intel SDM Vol.3B ch.17 "Debug, Branch Profile,
//! TSC, and Intel Resource Director Technology Features"; Apple XNU headers
//! `osfmk/mach/i386/thread_status.h`, `osfmk/mach/exception_types.h`,
//! `osfmk/mach/i386/exception.h`) are inline below.
const std = @import("std");
const builtin = @import("builtin");
const di = @import("../debug_info.zig");
const ctrl = @import("controller.zig");

const HwStop = ctrl.HwStop;
const HwError = ctrl.HwError;
const HwBreakpointController = ctrl.HwBreakpointController;

/// True only on the target this controller actually drives. Off-target the file
/// still compiles (extern decls need no linkage for ast-check) but every
/// OS-touching op refuses with `HwError.Unsupported` instead of pretending.
const supported = builtin.os.tag == .macos and builtin.cpu.arch == .x86_64;

// --- DR register field model (Intel SDM Vol.3B 17.2.4 "Debug Control Register
// (DR7)" and 17.2.3 "Debug Status Register (DR6)"). --------------------------

/// DR7 R/W field encoding (SDM Table 17-2). x86 has no read-only data break;
/// the closest is read-or-write (0b11).
const Rw = enum(u2) {
    exec = 0b00, // break on instruction execution only
    write = 0b01, // break on data writes only
    io = 0b10, // break on I/O reads/writes (needs CR4.DE)
    read_write = 0b11, // break on data reads or writes, not fetches
};

/// DR7 LEN field encoding (SDM Table 17-2). 0b10 == 8 bytes is valid only in
/// 64-bit mode, which is exactly our target.
const Len = enum(u2) {
    b1 = 0b00,
    b2 = 0b01,
    b8 = 0b10,
    b4 = 0b11,
};

const SlotClass = enum { exec, watch };

const Slot = struct {
    used: bool = false,
    class: SlotClass = .exec,
    addr: u64 = 0,
    rw: Rw = .exec,
    len: Len = .b1,
};

fn lenEncoding(bytes: u16) HwError!Len {
    return switch (bytes) {
        1 => .b1,
        2 => .b2,
        4 => .b4,
        8 => .b8,
        else => HwError.Unsupported,
    };
}

/// x86 exposes no pure-read data break, so a read watch is armed as read-or-write
/// (SDM Table 17-2: encoding 0b01 is write-only, 0b11 is read/write; there is no
/// read-only encoding). Callers that need read-only filtering must post-filter.
fn watchRw(kind: di.WatchKind) Rw {
    return switch (kind) {
        .write => .write,
        .read, .read_write => .read_write,
    };
}

/// Compose DR7 from the four slots. Bit layout (SDM 17.2.4):
///   bit 2n     = Ln (local enable for DRn) — per-thread, cleared on task switch
///   bit 2n+1   = Gn (global enable) — left 0; we use local enables
///   bits 16+4n..17+4n = R/Wn field
///   bits 18+4n..19+4n = LENn field
fn composeDr7(slots: [4]Slot) u64 {
    var dr7: u64 = 0;
    for (slots, 0..) |s, n| {
        if (!s.used) continue;
        const shift: u6 = @intCast(n);
        dr7 |= @as(u64, 1) << (shift * 2); // local enable Ln
        const cond_base: u6 = @intCast(16 + n * 4);
        dr7 |= @as(u64, @intFromEnum(s.rw)) << cond_base;
        dr7 |= @as(u64, @intFromEnum(s.len)) << (cond_base + 2);
    }
    return dr7;
}

/// DR6 status bits (SDM 17.2.3): B0-B3 (bits 0-3) flag the breakpoint condition
/// detected; BS (bit 14) flags a single-step trap. This decodes the raw status
/// against the current slot table into an `HwStop`.
fn decodeDr6(dr6: u64, slots: [4]Slot) ?HwStop {
    const bs_bit: u64 = 1 << 14;
    if (dr6 & bs_bit != 0) return HwStop.step;
    for (slots, 0..) |s, n| {
        const bn: u64 = @as(u64, 1) << @as(u6, @intCast(n));
        if (dr6 & bn == 0) continue;
        if (!s.used) continue;
        return switch (s.class) {
            .exec => HwStop{ .exec = @intCast(n) },
            .watch => HwStop{ .watch = .{ .slot = @intCast(n), .addr = s.addr } },
        };
    }
    return null;
}

// --- Mach type/constant declarations (Apple XNU). ---------------------------
// Declared locally so this file ast-checks on any host; on the real target they
// resolve against libSystem. Names/values from `<mach/*>`.

const mach_port_t = u32;
const kern_return_t = c_int;
const KERN_SUCCESS: kern_return_t = 0;

// thread_status.h: x86 state flavors and their natural_t (u32) counts.
const x86_THREAD_STATE64: c_int = 4;
const x86_DEBUG_STATE64: c_int = 11;
// x86_thread_state64_t is 21 u64 == 42 u32; x86_debug_state64_t is 8 u64 == 16 u32.
const x86_THREAD_STATE64_COUNT: u32 = 42;
const x86_DEBUG_STATE64_COUNT: u32 = 16;

// exception_types.h
const EXC_BREAKPOINT: u32 = 6;
const EXC_MASK_BREAKPOINT: u32 = 1 << EXC_BREAKPOINT; // 0x40
const EXCEPTION_DEFAULT: c_int = 1;
const THREAD_STATE_NONE: c_int = 13;
// i386/exception.h: sub-codes carried in exception code[0].
const EXC_I386_SGL: i32 = 1; // single-step / TF trap
const EXC_I386_BPT: i32 = 2; // INT3 / debug-register hit

// mach/message.h + port.h
const MACH_MSG_TYPE_MAKE_SEND: c_int = 20;
const MACH_PORT_RIGHT_RECEIVE: c_int = 1;
const MACH_SEND_MSG: c_int = 1;
const MACH_RCV_MSG: c_int = 2;
const MACH_MSG_TIMEOUT_NONE: u32 = 0;

// RFLAGS.TF (SDM Vol.1 3.4.3): setting bit 8 arms a single-step trap.
const RFLAGS_TF: u64 = 1 << 8;

/// x86_debug_state64_t (thread_status.h). dr4/dr5 are aliased/reserved.
const DebugState64 = extern struct {
    dr0: u64 = 0,
    dr1: u64 = 0,
    dr2: u64 = 0,
    dr3: u64 = 0,
    dr4: u64 = 0,
    dr5: u64 = 0,
    dr6: u64 = 0,
    dr7: u64 = 0,
};

/// x86_thread_state64_t (thread_status.h) — 21 u64 in declaration order. We index
/// by field for `readRegister` via the same order.
const ThreadState64 = extern struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rdi: u64 = 0,
    rsi: u64 = 0,
    rbp: u64 = 0,
    rsp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    rflags: u64 = 0,
    cs: u64 = 0,
    fs: u64 = 0,
    gs: u64 = 0,
};

extern "c" var mach_task_self_: mach_port_t;
extern "c" fn task_for_pid(target: mach_port_t, pid: c_int, out: *mach_port_t) kern_return_t;
extern "c" fn task_threads(task: mach_port_t, list: *[*]mach_port_t, count: *u32) kern_return_t;
extern "c" fn thread_suspend(thread: mach_port_t) kern_return_t;
extern "c" fn thread_resume(thread: mach_port_t) kern_return_t;
extern "c" fn thread_get_state(thread: mach_port_t, flavor: c_int, state: [*]u32, count: *u32) kern_return_t;
extern "c" fn thread_set_state(thread: mach_port_t, flavor: c_int, state: [*]const u32, count: u32) kern_return_t;
extern "c" fn mach_port_allocate(task: mach_port_t, right: c_int, name: *mach_port_t) kern_return_t;
extern "c" fn mach_port_insert_right(task: mach_port_t, name: mach_port_t, poly: mach_port_t, poly_poly: c_int) kern_return_t;
extern "c" fn thread_set_exception_ports(thread: mach_port_t, mask: u32, port: mach_port_t, behavior: c_int, flavor: c_int) kern_return_t;
extern "c" fn mach_msg(msg: [*]u32, option: c_int, send_size: u32, rcv_size: u32, rcv_name: mach_port_t, timeout: u32, notify: mach_port_t) kern_return_t;
extern "c" fn mach_vm_read_overwrite(task: mach_port_t, address: u64, size: u64, data: u64, out_size: *u64) kern_return_t;
extern "c" fn mach_vm_write(task: mach_port_t, address: u64, data: usize, count: u32) kern_return_t;

/// EXCEPTION_DEFAULT `exception_raise` request layout (mach/exc.defs, MIG). The
/// modern `mach_msg_header_t` carries a voucher port, so the header is six u32
/// (bits, size, remote, local, voucher, id). Two port descriptors (thread, task)
/// follow, each three u32; then NDR_record_t (two u32); then the exception int,
/// the code count, and code[0..1]. We only read the thread port + code[0].
const REQ_HEADER_U32 = 6;
const REQ_THREAD_PORT_IDX = 7; // header(6) + body(1)
const REQ_EXCEPTION_IDX = 15; // + 2 descriptors(6) + NDR(2)
const REQ_CODE0_IDX = 17; // exception(1) + codeCnt(1)

pub const DarwinX86_64 = struct {
    allocator: std.mem.Allocator,
    task: mach_port_t = 0,
    thread: mach_port_t = 0,
    exc_port: mach_port_t = 0,
    attached: bool = false,
    slots: [4]Slot = .{.{}} ** 4,

    pub fn init(allocator: std.mem.Allocator) DarwinX86_64 {
        return .{ .allocator = allocator };
    }

    /// Wrap as the vtable-driven `HwBreakpointController` the native target uses.
    pub fn controller(self: *DarwinX86_64) HwBreakpointController {
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

    // --- capability profile ------------------------------------------------

    fn capabilities(_: *DarwinX86_64) di.HwCapabilities {
        // DR0-DR3: 4 registers total, each usable as exec break or watch, so the
        // exec and watch classes share the same four slots. LEN maxes at 8 bytes
        // (SDM Table 17-2, 64-bit mode).
        return .{
            .max_exec_breakpoints = 4,
            .max_watchpoints = 4,
            .max_watch_bytes = 8,
            .single_step = true,
            .software_only = false,
        };
    }

    // --- slot allocation (shared across exec + watch) ----------------------

    fn allocSlot(self: *DarwinX86_64) HwError!u8 {
        for (&self.slots, 0..) |*s, n| {
            if (!s.used) return @intCast(n);
        }
        return HwError.SlotsExhausted;
    }

    fn arm(self: *DarwinX86_64) HwError!void {
        if (!supported) return HwError.Unsupported;
        if (!self.attached) return HwError.NotStopped;
        var dbg = DebugState64{};
        try self.getStateThread(x86_DEBUG_STATE64, std.mem.asBytes(&dbg), x86_DEBUG_STATE64_COUNT);
        const addrs = [_]*u64{ &dbg.dr0, &dbg.dr1, &dbg.dr2, &dbg.dr3 };
        for (self.slots, 0..) |s, n| {
            addrs[n].* = if (s.used) s.addr else 0;
        }
        dbg.dr7 = composeDr7(self.slots);
        dbg.dr6 = 0; // clear stale status when re-arming
        try self.setState(x86_DEBUG_STATE64, std.mem.asBytes(&dbg));
    }

    // --- Mach state helpers ------------------------------------------------

    fn getStateThread(self: *DarwinX86_64, flavor: c_int, bytes: []u8, count: u32) HwError!void {
        if (!supported) return HwError.Unsupported;
        var cnt = count;
        const words: [*]u32 = @ptrCast(@alignCast(bytes.ptr));
        if (thread_get_state(self.thread, flavor, words, &cnt) != KERN_SUCCESS)
            return HwError.NotStopped;
    }

    fn setState(self: *DarwinX86_64, flavor: c_int, bytes: []const u8) HwError!void {
        if (!supported) return HwError.Unsupported;
        const words: [*]const u32 = @ptrCast(@alignCast(bytes.ptr));
        const count: u32 = if (flavor == x86_DEBUG_STATE64) x86_DEBUG_STATE64_COUNT else x86_THREAD_STATE64_COUNT;
        if (thread_set_state(self.thread, flavor, words, count) != KERN_SUCCESS)
            return HwError.NotStopped;
    }

    // --- vtable trampolines ------------------------------------------------

    fn vtCapabilities(ctx: *anyopaque) di.HwCapabilities {
        return capabilities(cast(ctx));
    }

    fn vtAttach(ctx: *anyopaque, pid: i32) anyerror!void {
        const self = cast(ctx);
        if (!supported) return HwError.Unsupported;

        var task: mach_port_t = 0;
        if (task_for_pid(mach_task_self_, @intCast(pid), &task) != KERN_SUCCESS)
            return HwError.PermissionDenied; // needs task_for_pid entitlement / same-uid
        self.task = task;

        var list: [*]mach_port_t = undefined;
        var n: u32 = 0;
        if (task_threads(task, &list, &n) != KERN_SUCCESS or n == 0)
            return HwError.NotStopped;
        self.thread = list[0];

        // Per-thread exception port for EXC_BREAKPOINT.
        var port: mach_port_t = 0;
        if (mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS)
            return HwError.PermissionDenied;
        if (mach_port_insert_right(mach_task_self_, port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS)
            return HwError.PermissionDenied;
        if (thread_set_exception_ports(self.thread, EXC_MASK_BREAKPOINT, port, EXCEPTION_DEFAULT, THREAD_STATE_NONE) != KERN_SUCCESS)
            return HwError.PermissionDenied;
        self.exc_port = port;
        self.attached = true;
    }

    fn vtArmExec(ctx: *anyopaque, addr: u64) anyerror!u8 {
        const self = cast(ctx);
        if (!supported) return HwError.Unsupported;
        const slot = try self.allocSlot();
        self.slots[slot] = .{ .used = true, .class = .exec, .addr = addr, .rw = .exec, .len = .b1 };
        errdefer self.slots[slot] = .{};
        try self.arm();
        return slot;
    }

    fn vtArmWatch(ctx: *anyopaque, addr: u64, len: u16, kind: di.WatchKind) anyerror!u8 {
        const self = cast(ctx);
        if (!supported) return HwError.Unsupported;
        const enc = try lenEncoding(len);
        // x86 requires the watch address be aligned to its length (SDM 17.2.5).
        if (len > 1 and addr % len != 0) return HwError.Unsupported;
        const slot = try self.allocSlot();
        self.slots[slot] = .{ .used = true, .class = .watch, .addr = addr, .rw = watchRw(kind), .len = enc };
        errdefer self.slots[slot] = .{};
        try self.arm();
        return slot;
    }

    fn vtDisarm(ctx: *anyopaque, slot: u8) anyerror!void {
        const self = cast(ctx);
        if (!supported) return HwError.Unsupported;
        if (slot >= self.slots.len or !self.slots[slot].used) return HwError.NotStopped;
        self.slots[slot] = .{};
        try self.arm();
    }

    fn vtCont(ctx: *anyopaque) anyerror!HwStop {
        const self = cast(ctx);
        if (!supported) return HwError.Unsupported;
        if (!self.attached) return HwError.NotStopped;
        try self.clearTrapFlag();
        _ = thread_resume(self.thread);
        return self.waitForStop();
    }

    fn vtSingleStep(ctx: *anyopaque) anyerror!HwStop {
        const self = cast(ctx);
        if (!supported) return HwError.Unsupported;
        if (!self.attached) return HwError.NotStopped;
        try self.setTrapFlag();
        _ = thread_resume(self.thread);
        const stop = try self.waitForStop();
        try self.clearTrapFlag();
        return stop;
    }

    fn vtReadRegister(ctx: *anyopaque, index: u16) anyerror!u64 {
        const self = cast(ctx);
        if (!supported) return HwError.Unsupported;
        if (index >= 21) return HwError.Unsupported; // 21 GP/segment/flags fields
        var ts = ThreadState64{};
        try self.getStateThread(x86_THREAD_STATE64, std.mem.asBytes(&ts), x86_THREAD_STATE64_COUNT);
        const regs: [*]const u64 = @ptrCast(&ts);
        return regs[index];
    }

    fn vtReadMemory(ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void {
        const self = cast(ctx);
        if (!supported) return HwError.Unsupported;
        if (buf.len == 0) return;
        var out: u64 = 0;
        if (mach_vm_read_overwrite(self.task, addr, buf.len, @intFromPtr(buf.ptr), &out) != KERN_SUCCESS)
            return HwError.Unsupported;
    }

    fn vtWriteMemory(ctx: *anyopaque, addr: u64, bytes: []const u8) anyerror!void {
        const self = cast(ctx);
        if (!supported) return HwError.Unsupported;
        if (bytes.len == 0) return;
        if (mach_vm_write(self.task, addr, @intFromPtr(bytes.ptr), @intCast(bytes.len)) != KERN_SUCCESS)
            return HwError.Unsupported;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.attached = false;
        self.slots = .{.{}} ** 4;
    }

    // --- TF bit + exception pump ------------------------------------------

    fn setTrapFlag(self: *DarwinX86_64) HwError!void {
        try self.updateTrapFlag(true);
    }
    fn clearTrapFlag(self: *DarwinX86_64) HwError!void {
        try self.updateTrapFlag(false);
    }
    fn updateTrapFlag(self: *DarwinX86_64, on: bool) HwError!void {
        if (!supported) return HwError.Unsupported;
        var ts = ThreadState64{};
        try self.getStateThread(x86_THREAD_STATE64, std.mem.asBytes(&ts), x86_THREAD_STATE64_COUNT);
        if (on) ts.rflags |= RFLAGS_TF else ts.rflags &= ~RFLAGS_TF;
        try self.setState(x86_THREAD_STATE64, std.mem.asBytes(&ts));
    }

    /// Block on the exception port, decode the raised `EXC_BREAKPOINT`, then read
    /// DR6 to attribute it to a slot / single-step. The stopped thread stays
    /// suspended (the exception is left unreplied) until the next cont/step.
    fn waitForStop(self: *DarwinX86_64) HwError!HwStop {
        if (!supported) return HwError.Unsupported;
        var msg: [256]u32 = undefined;
        const rc = mach_msg(&msg, MACH_RCV_MSG, 0, @sizeOf(@TypeOf(msg)), self.exc_port, MACH_MSG_TIMEOUT_NONE, 0);
        if (rc != KERN_SUCCESS) return HwError.NotStopped;

        // Re-point at the faulting thread the kernel handed us.
        self.thread = msg[REQ_THREAD_PORT_IDX];
        const exception: u32 = msg[REQ_EXCEPTION_IDX];
        if (exception != EXC_BREAKPOINT) return HwStop{ .signal = exception };

        var dbg = DebugState64{};
        try self.getStateThread(x86_DEBUG_STATE64, std.mem.asBytes(&dbg), x86_DEBUG_STATE64_COUNT);
        const decoded = decodeDr6(dbg.dr6, self.slots);

        // Clear DR6 status so the next stop reports fresh bits (SDM 17.2.3: the
        // processor does not auto-clear B0-B3/BS).
        dbg.dr6 = 0;
        self.setState(x86_DEBUG_STATE64, std.mem.asBytes(&dbg)) catch {};

        if (decoded) |d| return d;
        // No DR bit set: fall back to the exception sub-code in code[0].
        const code0: i32 = @bitCast(msg[REQ_CODE0_IDX]);
        if (code0 == EXC_I386_SGL) return HwStop.step;
        return HwStop{ .signal = EXC_BREAKPOINT };
    }

    fn cast(ctx: *anyopaque) *DarwinX86_64 {
        return @ptrCast(@alignCast(ctx));
    }
};

// ---------------------------------------------------------------------------
// Tests — pure DR7/DR6 bit logic, host-independent.
// ---------------------------------------------------------------------------

test "composeDr7 packs exec + watch slots" {
    var slots = [_]Slot{.{}} ** 4;
    // slot0: exec break (rw=00, len=00), slot2: 4-byte write watch (rw=01, len=11).
    slots[0] = .{ .used = true, .class = .exec, .addr = 0x1000, .rw = .exec, .len = .b1 };
    slots[2] = .{ .used = true, .class = .watch, .addr = 0x2000, .rw = .write, .len = .b4 };

    const dr7 = composeDr7(slots);

    // Local enables: L0 = bit0, L2 = bit4.
    try std.testing.expect(dr7 & (1 << 0) != 0);
    try std.testing.expect(dr7 & (1 << 4) != 0);
    // L1/L3 and all global enables clear.
    try std.testing.expect(dr7 & (1 << 2) == 0);
    try std.testing.expect(dr7 & (1 << 1) == 0);

    // slot0 condition at bits 16-19: R/W=00, LEN=00.
    try std.testing.expectEqual(@as(u64, 0b00), (dr7 >> 16) & 0b11);
    try std.testing.expectEqual(@as(u64, 0b00), (dr7 >> 18) & 0b11);
    // slot2 condition at bits 24-27: R/W=01, LEN=11.
    try std.testing.expectEqual(@as(u64, 0b01), (dr7 >> 24) & 0b11);
    try std.testing.expectEqual(@as(u64, 0b11), (dr7 >> 26) & 0b11);
}

test "composeDr7 is empty for no slots" {
    const dr7 = composeDr7([_]Slot{.{}} ** 4);
    try std.testing.expectEqual(@as(u64, 0), dr7);
}

test "decodeDr6 attributes exec, watch, and single-step" {
    var slots = [_]Slot{.{}} ** 4;
    slots[1] = .{ .used = true, .class = .exec, .addr = 0x40, .rw = .exec, .len = .b1 };
    slots[3] = .{ .used = true, .class = .watch, .addr = 0x80, .rw = .read_write, .len = .b8 };

    // B1 set -> exec slot 1.
    switch (decodeDr6(1 << 1, slots).?) {
        .exec => |s| try std.testing.expectEqual(@as(u8, 1), s),
        else => return error.Unexpected,
    }
    // B3 set -> watch slot 3 with its address.
    switch (decodeDr6(1 << 3, slots).?) {
        .watch => |w| {
            try std.testing.expectEqual(@as(u8, 3), w.slot);
            try std.testing.expectEqual(@as(u64, 0x80), w.addr);
        },
        else => return error.Unexpected,
    }
    // BS (bit14) wins as single-step.
    try std.testing.expectEqual(HwStop.step, decodeDr6(1 << 14, slots).?);
    // No bits -> null.
    try std.testing.expect(decodeDr6(0, slots) == null);
}

test "lenEncoding maps valid widths and rejects others" {
    try std.testing.expectEqual(Len.b1, try lenEncoding(1));
    try std.testing.expectEqual(Len.b2, try lenEncoding(2));
    try std.testing.expectEqual(Len.b4, try lenEncoding(4));
    try std.testing.expectEqual(Len.b8, try lenEncoding(8));
    try std.testing.expectError(HwError.Unsupported, lenEncoding(3));
    try std.testing.expectError(HwError.Unsupported, lenEncoding(16));
}

test "watchRw has no read-only encoding" {
    try std.testing.expectEqual(Rw.write, watchRw(.write));
    try std.testing.expectEqual(Rw.read_write, watchRw(.read));
    try std.testing.expectEqual(Rw.read_write, watchRw(.read_write));
}

test "capabilities advertise four shared DR slots" {
    var c = DarwinX86_64.init(std.testing.allocator);
    const caps = c.controller().capabilities();
    try std.testing.expectEqual(@as(u8, 4), caps.max_exec_breakpoints);
    try std.testing.expectEqual(@as(u8, 4), caps.max_watchpoints);
    try std.testing.expectEqual(@as(u16, 8), caps.max_watch_bytes);
    try std.testing.expect(caps.single_step);
    try std.testing.expect(!caps.software_only);
}
