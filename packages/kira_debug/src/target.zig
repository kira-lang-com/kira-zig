//! `DebugTarget` — the backend-agnostic interface the session drives. VM, native
//! (hardware-assisted), and hybrid each provide one. A vtable rather than a
//! tagged union so backends live in their own files and are composed freely
//! (hybrid wraps a vm target + a native target).
const std = @import("std");
const di = @import("debug_info.zig");

pub const StepKind = enum {
    /// Step one source line, descending into calls.
    into,
    /// Step one source line, running calls to completion.
    over,
    /// Run until the current function returns.
    out,
    /// Step exactly one backend instruction (VM opcode / native insn).
    instruction,
};

/// Errors any target may surface; backends may also return allocator errors.
pub const TargetError = error{
    /// The operation has no meaning for this backend (e.g. readMemory on the VM
    /// value model). Callers should treat it as a soft, reported limitation.
    Unsupported,
    /// The target is not in a stopped state where this call is valid.
    NotStopped,
    /// No such frame / breakpoint id.
    NotFound,
    /// Hardware or OS debug facility refused the request (slots exhausted, no
    /// permission). Callers may retry via the software fallback.
    HardwareUnavailable,
};

pub const DebugTarget = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ctx: *anyopaque) anyerror!di.StopReason,
        cont: *const fn (ctx: *anyopaque) anyerror!di.StopReason,
        step: *const fn (ctx: *anyopaque, kind: StepKind) anyerror!di.StopReason,
        setBreakpoint: *const fn (ctx: *anyopaque, spec: di.BreakpointSpec) anyerror!u32,
        clearBreakpoint: *const fn (ctx: *anyopaque, id: u32) anyerror!void,
        backtrace: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]di.Frame,
        locals: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32) anyerror![]di.LocalView,
        evaluate: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) anyerror![]const u8,
        readMemory: *const fn (ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn start(self: DebugTarget) !di.StopReason {
        return self.vtable.start(self.ptr);
    }
    pub fn cont(self: DebugTarget) !di.StopReason {
        return self.vtable.cont(self.ptr);
    }
    pub fn step(self: DebugTarget, kind: StepKind) !di.StopReason {
        return self.vtable.step(self.ptr, kind);
    }
    pub fn setBreakpoint(self: DebugTarget, spec: di.BreakpointSpec) !u32 {
        return self.vtable.setBreakpoint(self.ptr, spec);
    }
    pub fn clearBreakpoint(self: DebugTarget, id: u32) !void {
        return self.vtable.clearBreakpoint(self.ptr, id);
    }
    pub fn backtrace(self: DebugTarget, allocator: std.mem.Allocator) ![]di.Frame {
        return self.vtable.backtrace(self.ptr, allocator);
    }
    pub fn locals(self: DebugTarget, allocator: std.mem.Allocator, frame_index: u32) ![]di.LocalView {
        return self.vtable.locals(self.ptr, allocator, frame_index);
    }
    pub fn evaluate(self: DebugTarget, allocator: std.mem.Allocator, frame_index: u32, expr: []const u8) ![]const u8 {
        return self.vtable.evaluate(self.ptr, allocator, frame_index, expr);
    }
    pub fn readMemory(self: DebugTarget, addr: u64, buf: []u8) !void {
        return self.vtable.readMemory(self.ptr, addr, buf);
    }
    pub fn deinit(self: DebugTarget) void {
        self.vtable.deinit(self.ptr);
    }
};
