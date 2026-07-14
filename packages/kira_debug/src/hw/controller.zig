//! `HwBreakpointController` — the hardware-debug abstraction the native target
//! drives. One vtable, one implementation per os/arch, plus a software-trap
//! fallback. `select()` picks the right implementation for the build target at
//! comptime; when no hardware path exists (e.g. wasm) it returns the software
//! fallback and advertises `software_only` capabilities so the session degrades
//! with a diagnostic instead of pretending.
const std = @import("std");
const builtin = @import("builtin");
const di = @import("../debug_info.zig");

/// A stop reported by the hardware/OS debug facility.
pub const HwStop = union(enum) {
    /// An armed execution breakpoint at this slot fired.
    exec: u8,
    /// A watchpoint at this slot fired (data address in `addr`).
    watch: struct { slot: u8, addr: u64 },
    /// A single-step completed.
    step,
    /// The inferior exited with this code.
    exited: i32,
    /// A signal/exception with no owning slot.
    signal: u32,
};

pub const HwError = error{
    /// All hardware register slots of the requested class are in use.
    SlotsExhausted,
    /// The OS refused the request (missing entitlement/permission, e.g.
    /// task_for_pid on macOS or ptrace scope on Linux).
    PermissionDenied,
    /// This controller has no hardware path for the requested operation.
    Unsupported,
    /// The inferior is not in a stopped state.
    NotStopped,
};

pub const HwBreakpointController = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        capabilities: *const fn (ctx: *anyopaque) di.HwCapabilities,
        /// Attach to an already-launched, stopped inferior thread/task.
        attach: *const fn (ctx: *anyopaque, pid: i32) anyerror!void,
        armExec: *const fn (ctx: *anyopaque, addr: u64) anyerror!u8,
        armWatch: *const fn (ctx: *anyopaque, addr: u64, len: u16, kind: di.WatchKind) anyerror!u8,
        disarm: *const fn (ctx: *anyopaque, slot: u8) anyerror!void,
        cont: *const fn (ctx: *anyopaque) anyerror!HwStop,
        singleStep: *const fn (ctx: *anyopaque) anyerror!HwStop,
        readRegister: *const fn (ctx: *anyopaque, index: u16) anyerror!u64,
        readMemory: *const fn (ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void,
        writeMemory: *const fn (ctx: *anyopaque, addr: u64, bytes: []const u8) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn capabilities(self: HwBreakpointController) di.HwCapabilities {
        return self.vtable.capabilities(self.ptr);
    }
    pub fn attach(self: HwBreakpointController, pid: i32) !void {
        return self.vtable.attach(self.ptr, pid);
    }
    pub fn armExec(self: HwBreakpointController, addr: u64) !u8 {
        return self.vtable.armExec(self.ptr, addr);
    }
    pub fn armWatch(self: HwBreakpointController, addr: u64, len: u16, kind: di.WatchKind) !u8 {
        return self.vtable.armWatch(self.ptr, addr, len, kind);
    }
    pub fn disarm(self: HwBreakpointController, slot: u8) !void {
        return self.vtable.disarm(self.ptr, slot);
    }
    pub fn cont(self: HwBreakpointController) !HwStop {
        return self.vtable.cont(self.ptr);
    }
    pub fn singleStep(self: HwBreakpointController) !HwStop {
        return self.vtable.singleStep(self.ptr);
    }
    pub fn readRegister(self: HwBreakpointController, index: u16) !u64 {
        return self.vtable.readRegister(self.ptr, index);
    }
    pub fn readMemory(self: HwBreakpointController, addr: u64, buf: []u8) !void {
        return self.vtable.readMemory(self.ptr, addr, buf);
    }
    pub fn writeMemory(self: HwBreakpointController, addr: u64, bytes: []const u8) !void {
        return self.vtable.writeMemory(self.ptr, addr, bytes);
    }
    pub fn deinit(self: HwBreakpointController) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Comptime target classification so each os/arch impl file compiles only where
/// it applies and the fallback is chosen otherwise.
pub const Platform = enum { darwin_arm64, darwin_x86_64, linux_arm64, linux_x86_64, windows, software };

pub fn currentPlatform() Platform {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => .darwin_arm64,
            .x86_64 => .darwin_x86_64,
            else => .software,
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => .linux_arm64,
            .x86_64 => .linux_x86_64,
            else => .software,
        },
        .windows => .windows,
        else => .software,
    };
}

test "currentPlatform resolves a variant for the host" {
    _ = currentPlatform();
}
