//! `HwBreakpointController` software-trap FALLBACK.
//!
//! Used in two situations by `select()`/the native target:
//!
//!   1. **Overflow fallback on a real arch** — every hardware debug-register
//!      slot (DR0-DR3 / BVR0-BVRn) is already armed, but more execution
//!      breakpoints are needed. Software traps are effectively unlimited, so
//!      this controller advertises `max_exec_breakpoints = 255`. Data
//!      watchpoints still need hardware, so `max_watchpoints = 0`.
//!
//!   2. **Genuinely software-only platform** — the arch has no hardware debug
//!      path at all (wasm, unknown). `capabilities()` returns
//!      `HwCapabilities.none()` (`software_only = true`, all counts zero) so the
//!      session emits its "hardware debug unavailable, software instrumentation
//!      only" diagnostic and never smoke-passes a hardware feature.
//!
//! Mechanism: an execution breakpoint patches the target instruction with a
//! trap — `BRK #0` (0xD4200000) on arm64, `int3` (0xCC) on x86 — after saving
//! the original bytes; disarm writes the saved bytes back. Single-step restores
//! every armed original, drives one target step, then re-patches. `cont` steps
//! off whatever instruction we are parked on the same way, then resumes.
//!
//! This file is platform-neutral and stays well under Core Law #5's 600-line
//! bar by pushing every OS-specific primitive behind an injected
//! `ProcessHandle`: memory read/write is required; register read and target
//! resume/step are optional and honestly degrade to `HwError.Unsupported` when
//! the host cannot provide them (e.g. wasm). For self-process patching a
//! `selfProcessHandle()` backed by `@memcpy` is provided; cross-process hosts
//! inject a ptrace / ReadProcessMemory-backed handle. No `writeRegister` is
//! required: the resume provider is responsible for normalizing the reported
//! trap PC to the breakpoint address (x86 `int3` leaves PC one byte past the
//! trap), so PC fixup stays with the layer that owns register state.

const std = @import("std");
const builtin = @import("builtin");
const di = @import("../debug_info.zig");
const ctrl = @import("controller.zig");

const HwStop = ctrl.HwStop;
const HwError = ctrl.HwError;
const HwBreakpointController = ctrl.HwBreakpointController;

const log = std.log.scoped(.kira_debug);

/// SIGTRAP; reported when a trap fires that matches no armed breakpoint.
const sigtrap: u32 = 5;

/// Longest trap pattern we patch (arm64 `BRK` is 4 bytes; `int3` is 1).
pub const max_trap_len: usize = 4;

/// Software breakpoints are cheap, so we allow up to 255 simultaneously — the
/// same figure advertised by `capabilities()` in overflow-fallback mode.
pub const max_breakpoints: usize = 255;

/// How this controller was selected, which drives `capabilities()` and the
/// diagnostic the session shows.
pub const Mode = enum {
    /// Chosen because hardware slots were exhausted on an arch that has them.
    overflow_fallback,
    /// Chosen because the arch has no hardware debug facility at all.
    software_only,
};

/// The raw outcome of resuming/stepping the target, reported by the injected
/// `resumeFn`. The controller maps this to `HwStop` (resolving which armed
/// breakpoint a `trap` belongs to).
pub const RawStop = union(enum) {
    /// The target trapped at this PC. The provider must report the breakpoint
    /// address (having rewound any x86 `int3` skid); a small skid tolerance is
    /// applied defensively when matching.
    trap: u64,
    /// A single-step completed.
    step,
    /// The target exited with this code.
    exited: i32,
    /// A signal/exception with no owning breakpoint.
    signal: u32,
};

/// The OS-specific target primitives this controller needs but cannot perform
/// portably. `readMemory`/`writeMemory` are the required memory-access
/// injection point (self-process `@memcpy`, or cross-process ptrace /
/// ReadProcessMemory). `readRegister` and `resumeFn` are optional; when null
/// the corresponding operation honestly returns `HwError.Unsupported` instead
/// of pretending.
pub const ProcessHandle = struct {
    ctx: *anyopaque,
    readMemoryFn: *const fn (ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void,
    writeMemoryFn: *const fn (ctx: *anyopaque, addr: u64, bytes: []const u8) anyerror!void,
    readRegisterFn: ?*const fn (ctx: *anyopaque, index: u16) anyerror!u64 = null,
    resumeFn: ?*const fn (ctx: *anyopaque, single_step: bool) anyerror!RawStop = null,

    pub fn readMemory(self: ProcessHandle, addr: u64, buf: []u8) anyerror!void {
        return self.readMemoryFn(self.ctx, addr, buf);
    }
    pub fn writeMemory(self: ProcessHandle, addr: u64, bytes: []const u8) anyerror!void {
        return self.writeMemoryFn(self.ctx, addr, bytes);
    }
    pub fn readRegister(self: ProcessHandle, index: u16) anyerror!u64 {
        const f = self.readRegisterFn orelse return HwError.Unsupported;
        return f(self.ctx, index);
    }
    pub fn resumeTarget(self: ProcessHandle, single_step: bool) anyerror!RawStop {
        const f = self.resumeFn orelse return HwError.Unsupported;
        return f(self.ctx, single_step);
    }
};

// -- trap encoding ------------------------------------------------------------

/// The trap instruction bytes for a given arch, plus the PC skid the trap
/// leaves behind (0 for arm64 `BRK`, 1 for x86 `int3`).
pub const TrapEncoding = struct {
    bytes: [max_trap_len]u8 = [_]u8{0} ** max_trap_len,
    len: u8 = 0,
    pc_skid: u8 = 0,

    /// True when this arch has a software trap we can patch. wasm/unknown do
    /// not — code cannot be rewritten at runtime — so `armExec` there is
    /// `Unsupported`.
    pub fn available(self: TrapEncoding) bool {
        return self.len != 0;
    }

    pub fn forArch(arch: std.Target.Cpu.Arch) TrapEncoding {
        return switch (arch) {
            // BRK #0 == 0xD4200000, little-endian in memory.
            .aarch64, .aarch64_be => .{ .bytes = .{ 0x00, 0x00, 0x20, 0xD4 }, .len = 4, .pc_skid = 0 },
            // int3 == 0xCC; PC advances one byte past it.
            .x86, .x86_64 => .{ .bytes = .{ 0xCC, 0x00, 0x00, 0x00 }, .len = 1, .pc_skid = 1 },
            else => .{},
        };
    }
};

// -- controller ---------------------------------------------------------------

const SoftBreakpoint = struct {
    active: bool = false,
    addr: u64 = 0,
    len: u8 = 0,
    original: [max_trap_len]u8 = [_]u8{0} ** max_trap_len,
};

pub const SoftwareTrapController = struct {
    mode: Mode,
    trap: TrapEncoding,
    handle: ProcessHandle,
    pid: i32 = -1,
    attached: bool = false,
    breakpoints: [max_breakpoints]SoftBreakpoint = [_]SoftBreakpoint{.{}} ** max_breakpoints,

    /// Build a controller whose trap encoding matches the host arch. Use
    /// `initForArch` to target a different arch (e.g. in tests).
    pub fn init(mode: Mode, handle: ProcessHandle) SoftwareTrapController {
        return initForArch(mode, handle, builtin.cpu.arch);
    }

    pub fn initForArch(mode: Mode, handle: ProcessHandle, arch: std.Target.Cpu.Arch) SoftwareTrapController {
        return .{ .mode = mode, .trap = TrapEncoding.forArch(arch), .handle = handle };
    }

    /// Type-erased controller the native target drives.
    pub fn controller(self: *SoftwareTrapController) HwBreakpointController {
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

    fn cast(ptr: *anyopaque) *SoftwareTrapController {
        return @ptrCast(@alignCast(ptr));
    }

    fn freeSlot(self: *SoftwareTrapController) HwError!u8 {
        var i: usize = 0;
        while (i < max_breakpoints) : (i += 1) {
            if (!self.breakpoints[i].active) return @intCast(i);
        }
        return HwError.SlotsExhausted;
    }

    /// Write every armed breakpoint's saved original bytes back (used before a
    /// step so the real instruction executes) — best effort, first error wins.
    fn restoreAllActive(self: *SoftwareTrapController) anyerror!void {
        for (&self.breakpoints) |*bp| {
            if (!bp.active) continue;
            try self.handle.writeMemory(bp.addr, bp.original[0..bp.len]);
        }
    }

    /// Re-patch every armed breakpoint with the trap bytes (used after a step).
    fn repatchAllActive(self: *SoftwareTrapController) anyerror!void {
        for (&self.breakpoints) |*bp| {
            if (!bp.active) continue;
            try self.handle.writeMemory(bp.addr, self.trap.bytes[0..self.trap.len]);
        }
    }

    /// Resolve a raw trap PC to the armed breakpoint that fired.
    fn mapTrap(self: *SoftwareTrapController, pc: u64) HwStop {
        for (&self.breakpoints, 0..) |*bp, i| {
            if (!bp.active) continue;
            if (pc == bp.addr or pc == bp.addr + self.trap.pc_skid) {
                return HwStop{ .exec = @intCast(i) };
            }
        }
        return HwStop{ .signal = sigtrap };
    }

    fn mapRaw(self: *SoftwareTrapController, raw: RawStop) HwStop {
        return switch (raw) {
            .exited => |code| blk: {
                self.attached = false;
                break :blk HwStop{ .exited = code };
            },
            .signal => |s| blk: {
                self.attached = false;
                break :blk HwStop{ .signal = s };
            },
            .step => HwStop.step,
            .trap => |pc| self.mapTrap(pc),
        };
    }

    // -- vtable impls ---------------------------------------------------------

    fn capabilitiesImpl(ptr: *anyopaque) di.HwCapabilities {
        const self = cast(ptr);
        return switch (self.mode) {
            // No hardware facility: advertise nothing, flag software_only so the
            // session shows its diagnostic and never treats this as hardware.
            .software_only => di.HwCapabilities.none(),
            // Overflowing real hardware: software exec breakpoints are ~unlimited,
            // but data watch genuinely needs hardware, so zero watchpoints.
            .overflow_fallback => .{
                .max_exec_breakpoints = @intCast(max_breakpoints),
                .max_watchpoints = 0,
                .max_watch_bytes = 0,
                .single_step = self.handle.resumeFn != null,
                .software_only = false,
            },
        };
    }

    fn attachImpl(ptr: *anyopaque, pid: i32) anyerror!void {
        const self = cast(ptr);
        self.pid = pid;
        self.attached = true;
    }

    fn armExecImpl(ptr: *anyopaque, addr: u64) anyerror!u8 {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        if (!self.trap.available()) {
            log.warn("software instrumentation cannot patch code on this arch; no trap encoding", .{});
            return HwError.Unsupported;
        }
        const slot = try self.freeSlot();
        var bp = SoftBreakpoint{ .active = true, .addr = addr, .len = self.trap.len };
        // Save the original bytes, then patch in the trap.
        try self.handle.readMemory(addr, bp.original[0..bp.len]);
        try self.handle.writeMemory(addr, self.trap.bytes[0..self.trap.len]);
        self.breakpoints[slot] = bp;
        return slot;
    }

    fn armWatchImpl(ptr: *anyopaque, addr: u64, len: u16, kind: di.WatchKind) anyerror!u8 {
        _ = ptr;
        _ = addr;
        _ = len;
        _ = kind;
        // Software traps can only trap execution; data watchpoints require the
        // hardware watch registers this fallback exists precisely because we
        // lack. Fail clearly rather than silently no-op.
        log.warn("data watchpoints require hardware debug registers; unavailable under software instrumentation", .{});
        return HwError.Unsupported;
    }

    fn disarmImpl(ptr: *anyopaque, slot: u8) anyerror!void {
        const self = cast(ptr);
        if (slot >= max_breakpoints) return HwError.Unsupported;
        const bp = &self.breakpoints[slot];
        if (!bp.active) return; // idempotent
        try self.handle.writeMemory(bp.addr, bp.original[0..bp.len]);
        bp.* = .{};
    }

    fn contImpl(ptr: *anyopaque) anyerror!HwStop {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        // Step off whatever we are parked on (the real instruction, with traps
        // removed), re-arm, then resume. When not parked on a breakpoint this
        // just executes one instruction as a step first — same net effect.
        try self.restoreAllActive();
        const stepped = try self.handle.resumeTarget(true);
        switch (stepped) {
            .exited, .signal => return self.mapRaw(stepped),
            .trap => {
                try self.repatchAllActive();
                return self.mapRaw(stepped);
            },
            .step => {},
        }
        try self.repatchAllActive();
        const raw = try self.handle.resumeTarget(false);
        return self.mapRaw(raw);
    }

    fn singleStepImpl(ptr: *anyopaque) anyerror!HwStop {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        // Restore originals so the real instruction executes, step, re-patch.
        try self.restoreAllActive();
        const raw = try self.handle.resumeTarget(true);
        switch (raw) {
            .exited, .signal => return self.mapRaw(raw),
            else => {
                try self.repatchAllActive();
                return self.mapRaw(raw);
            },
        }
    }

    fn readRegisterImpl(ptr: *anyopaque, index: u16) anyerror!u64 {
        const self = cast(ptr);
        if (!self.attached) return HwError.NotStopped;
        return self.handle.readRegister(index);
    }

    fn readMemoryImpl(ptr: *anyopaque, addr: u64, buf: []u8) anyerror!void {
        const self = cast(ptr);
        return self.handle.readMemory(addr, buf);
    }

    fn writeMemoryImpl(ptr: *anyopaque, addr: u64, bytes: []const u8) anyerror!void {
        const self = cast(ptr);
        return self.handle.writeMemory(addr, bytes);
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self = cast(ptr);
        // Best-effort: pull every trap back out so we never leave patched code
        // behind. Ignore write errors — the target may already be gone.
        if (self.attached) {
            for (&self.breakpoints) |*bp| {
                if (!bp.active) continue;
                self.handle.writeMemory(bp.addr, bp.original[0..bp.len]) catch {};
                bp.* = .{};
            }
        }
        self.attached = false;
    }
};

// -- self-process handle ------------------------------------------------------

var self_marker: u8 = 0;

fn selfReadMemory(ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void {
    _ = ctx;
    const src: [*]const u8 = @ptrFromInt(@as(usize, @intCast(addr)));
    @memcpy(buf, src[0..buf.len]);
}

fn selfWriteMemory(ctx: *anyopaque, addr: u64, bytes: []const u8) anyerror!void {
    _ = ctx;
    const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(addr)));
    @memcpy(dst[0..bytes.len], bytes);
}

/// A `ProcessHandle` that patches this process's own memory via `@memcpy`.
/// Suitable for writable regions (heap/JIT/data); patching read-only `.text`
/// still requires the platform layer to remap the page writable first. No
/// resume/register facility — self-process execution control is the caller's.
pub fn selfProcessHandle() ProcessHandle {
    return .{
        .ctx = &self_marker,
        .readMemoryFn = selfReadMemory,
        .writeMemoryFn = selfWriteMemory,
    };
}

// -- tests --------------------------------------------------------------------

test "TrapEncoding.forArch encodes BRK on arm64 and int3 on x86" {
    const a = TrapEncoding.forArch(.aarch64);
    try std.testing.expect(a.available());
    try std.testing.expectEqual(@as(u8, 4), a.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x20, 0xD4 }, a.bytes[0..a.len]);
    try std.testing.expectEqual(@as(u8, 0), a.pc_skid);

    const x = TrapEncoding.forArch(.x86_64);
    try std.testing.expect(x.available());
    try std.testing.expectEqual(@as(u8, 1), x.len);
    try std.testing.expectEqual(@as(u8, 0xCC), x.bytes[0]);
    try std.testing.expectEqual(@as(u8, 1), x.pc_skid);

    const w = TrapEncoding.forArch(.wasm32);
    try std.testing.expect(!w.available());
}

test "arm64 exec breakpoint patches BRK and disarm restores original bytes exactly" {
    // A writable buffer standing in for target code; self-process @memcpy path.
    var code = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    const original = code;
    const addr: u64 = @intFromPtr(&code);

    var c = SoftwareTrapController.initForArch(.overflow_fallback, selfProcessHandle(), .aarch64);
    const hw = c.controller();
    try hw.attach(1234);

    const slot = try hw.armExec(addr);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x20, 0xD4 }, code[0..4]);
    // Bytes past the trap are untouched.
    try std.testing.expectEqualSlices(u8, original[4..8], code[4..8]);

    try hw.disarm(slot);
    // Round-trip: the buffer is byte-for-byte what it was before arming.
    try std.testing.expectEqualSlices(u8, &original, &code);
}

test "x86 int3 patches exactly one byte and restores it" {
    var code = [_]u8{ 0x90, 0xAB, 0xCD };
    const original = code;
    const addr: u64 = @intFromPtr(&code);

    var c = SoftwareTrapController.initForArch(.overflow_fallback, selfProcessHandle(), .x86_64);
    const hw = c.controller();
    try hw.attach(1);
    const slot = try hw.armExec(addr);
    try std.testing.expectEqual(@as(u8, 0xCC), code[0]);
    try std.testing.expectEqual(original[1], code[1]);
    try hw.disarm(slot);
    try std.testing.expectEqualSlices(u8, &original, &code);
}

test "software_only mode advertises HwCapabilities.none()" {
    var c = SoftwareTrapController.init(.software_only, selfProcessHandle());
    const caps = c.controller().capabilities();
    try std.testing.expect(caps.software_only);
    try std.testing.expectEqual(@as(u8, 0), caps.max_exec_breakpoints);
    try std.testing.expectEqual(@as(u8, 0), caps.max_watchpoints);
    try std.testing.expectEqual(@as(u16, 0), caps.max_watch_bytes);
    try std.testing.expect(!caps.single_step);
}

test "overflow_fallback advertises unlimited software exec breakpoints, zero watchpoints" {
    var c = SoftwareTrapController.initForArch(.overflow_fallback, selfProcessHandle(), .aarch64);
    const caps = c.controller().capabilities();
    try std.testing.expect(!caps.software_only);
    try std.testing.expectEqual(@as(u8, 255), caps.max_exec_breakpoints);
    try std.testing.expectEqual(@as(u8, 0), caps.max_watchpoints);
}

test "watchpoints are unsupported under software instrumentation in both modes" {
    inline for (.{ Mode.software_only, Mode.overflow_fallback }) |mode| {
        var c = SoftwareTrapController.initForArch(mode, selfProcessHandle(), .aarch64);
        const hw = c.controller();
        try hw.attach(7);
        try std.testing.expectError(HwError.Unsupported, hw.armWatch(0x4000, 8, .write));
    }
}

test "cont and singleStep report Unsupported when no resume driver is injected" {
    var c = SoftwareTrapController.initForArch(.overflow_fallback, selfProcessHandle(), .aarch64);
    const hw = c.controller();
    try hw.attach(2);
    try std.testing.expectError(HwError.Unsupported, hw.cont());
    try std.testing.expectError(HwError.Unsupported, hw.singleStep());
}

test "armExec is Unsupported on an arch with no trap encoding" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    var c = SoftwareTrapController.initForArch(.software_only, selfProcessHandle(), .wasm32);
    const hw = c.controller();
    try hw.attach(3);
    try std.testing.expectError(HwError.Unsupported, hw.armExec(@intFromPtr(&buf)));
}

/// A fake target: a byte buffer plus a resume hook that samples the trap site at
/// step time, proving the restore-before-step / re-patch-after-step ordering.
const FakeTarget = struct {
    base: u64,
    mem: []u8,
    sample_addr: u64 = 0,
    sample_len: u8 = 0,
    saw_at_step: [max_trap_len]u8 = [_]u8{0} ** max_trap_len,
    stepped: bool = false,

    fn off(self: *FakeTarget, addr: u64) usize {
        return @intCast(addr - self.base);
    }
    fn read(ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void {
        const self: *FakeTarget = @ptrCast(@alignCast(ctx));
        const o = self.off(addr);
        @memcpy(buf, self.mem[o .. o + buf.len]);
    }
    fn write(ctx: *anyopaque, addr: u64, bytes: []const u8) anyerror!void {
        const self: *FakeTarget = @ptrCast(@alignCast(ctx));
        const o = self.off(addr);
        @memcpy(self.mem[o .. o + bytes.len], bytes);
    }
    fn resumeTarget(ctx: *anyopaque, single_step: bool) anyerror!RawStop {
        const self: *FakeTarget = @ptrCast(@alignCast(ctx));
        self.stepped = true;
        // Snapshot the breakpoint site exactly as it looks to the CPU right now.
        const o = self.off(self.sample_addr);
        @memcpy(self.saw_at_step[0..self.sample_len], self.mem[o .. o + self.sample_len]);
        _ = single_step;
        return RawStop.step;
    }
    fn handle(self: *FakeTarget) ProcessHandle {
        return .{
            .ctx = self,
            .readMemoryFn = read,
            .writeMemoryFn = write,
            .resumeFn = resumeTarget,
        };
    }
};

test "singleStep restores the original instruction before stepping and re-patches after" {
    var mem = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00 };
    const original = mem;
    const base: u64 = 0x4000_0000;
    var fake = FakeTarget{ .base = base, .mem = &mem, .sample_addr = base, .sample_len = 4 };

    var c = SoftwareTrapController.initForArch(.overflow_fallback, fake.handle(), .aarch64);
    const hw = c.controller();
    try hw.attach(99);

    _ = try hw.armExec(base); // patches BRK at offset 0
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x20, 0xD4 }, mem[0..4]);

    const stop = try hw.singleStep();
    try std.testing.expectEqual(HwStop.step, stop);
    try std.testing.expect(fake.stepped);
    // At step time the CPU saw the REAL instruction, not the trap.
    try std.testing.expectEqualSlices(u8, original[0..4], fake.saw_at_step[0..4]);
    // After the step the trap is back in place.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x20, 0xD4 }, mem[0..4]);
}

test "deinit pulls every trap back out of target memory" {
    var mem = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const original = mem;
    const base: u64 = 0x9000;
    var fake = FakeTarget{ .base = base, .mem = &mem };

    var c = SoftwareTrapController.initForArch(.overflow_fallback, fake.handle(), .aarch64);
    const hw = c.controller();
    try hw.attach(5);
    _ = try hw.armExec(base);
    _ = try hw.armExec(base + 4);
    // Both sites patched.
    try std.testing.expect(mem[0] != original[0] or mem[4] != original[4]);
    hw.deinit();
    // deinit restored every original byte.
    try std.testing.expectEqualSlices(u8, &original, &mem);
}

test "mem read/write flow through the injected handle" {
    var mem = [_]u8{ 0, 0, 0, 0 };
    const base: u64 = 0x1_0000;
    var fake = FakeTarget{ .base = base, .mem = &mem };
    var c = SoftwareTrapController.initForArch(.overflow_fallback, fake.handle(), .aarch64);
    const hw = c.controller();
    try hw.writeMemory(base + 1, &[_]u8{ 0xAA, 0xBB });
    var out = [_]u8{ 0, 0 };
    try hw.readMemory(base + 1, &out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, &out);
}
