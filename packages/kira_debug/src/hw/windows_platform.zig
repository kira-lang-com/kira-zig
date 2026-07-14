//! Windows target classification, `CONTEXT`/`DEBUG_EVENT` field layout, and the
//! `kernel32` externs the Windows `HwBreakpointController` (see `windows.zig`)
//! drives. Split out under Core Law #5 so the OS-ABI surface — offset tables and
//! extern declarations, no policy — lives in one focused module.
//!
//! Every `kernel32` extern here is referenced only from `if (comptime is_target)`
//! branches in `windows.zig`, so on non-Windows hosts they are never linked and
//! the whole controller AST-checks and links cleanly off-target.

const std = @import("std");
const builtin = @import("builtin");

pub const is_target = builtin.os.tag == .windows;
pub const is_x86 = is_target and builtin.cpu.arch == .x86_64;
pub const is_arm64 = is_target and builtin.cpu.arch == .aarch64;

// -- x86_64 CONTEXT field offsets ---------------------------------------------

/// x86_64 `CONTEXT` is 1232 bytes / 16-aligned. We only touch a handful of
/// fields, addressed by their fixed ABI offset.
pub const x64 = struct {
    pub const size: usize = 1232;
    pub const off_flags: usize = 0x30;
    pub const off_eflags: usize = 0x44;
    pub const off_dr0: usize = 0x48;
    pub const off_dr6: usize = 0x68;
    pub const off_dr7: usize = 0x70;
    /// Integer register file begins at Rax.
    pub const off_int_regs: usize = 0x78;
    /// CONTEXT_AMD64 | CONTEXT_CONTROL | CONTEXT_DEBUG_REGISTERS. CONTROL is
    /// needed so EFlags (TF) round-trips; DEBUG_REGISTERS for Dr0-7.
    pub const flags: u32 = 0x0010_0000 | 0x0000_0001 | 0x0000_0010;
    pub const eflags_tf: u32 = 1 << 8;
    pub fn drOffset(n: u8) usize {
        return off_dr0 + @as(usize, n) * 8;
    }
};

// -- arm64 ARM64_NT_CONTEXT field offsets -------------------------------------

/// arm64 `ARM64_NT_CONTEXT` is 912 bytes / 16-aligned.
pub const a64 = struct {
    pub const size: usize = 912;
    pub const off_flags: usize = 0x00;
    pub const off_cpsr: usize = 0x04;
    /// Integer register file (X0..) begins right after Cpsr.
    pub const off_int_regs: usize = 0x08;
    pub const off_bcr: usize = 792; // Bcr[8], u32 each
    pub const off_bvr: usize = 824; // Bvr[8], u64 each
    pub const off_wcr: usize = 888; // Wcr[2], u32 each
    pub const off_wvr: usize = 896; // Wvr[2], u64 each
    /// Number of watch registers the ARM64_NT_CONTEXT exposes (Wvr0/Wvr1).
    pub const watch_regs: u8 = 2;
    /// CONTEXT_ARM64 | CONTEXT_CONTROL | CONTEXT_DEBUG_REGISTERS.
    pub const flags: u32 = 0x0040_0000 | 0x0040_0001 | 0x0040_0008;
    pub const cpsr_ss: u32 = 1 << 21;
};

/// Comptime-selected CONTEXT size/flags/int-register base for the host arch. Off
/// target a 16-byte scratch buffer with zero flags keeps everything valid.
pub const ctx_size: usize = if (is_x86) x64.size else if (is_arm64) a64.size else 16;
pub const ctx_flags: u32 = if (is_x86) x64.flags else if (is_arm64) a64.flags else 0;
pub const off_flags: usize = if (is_x86) x64.off_flags else a64.off_flags;
pub const off_int_regs: usize = if (is_x86) x64.off_int_regs else a64.off_int_regs;

/// A raw, correctly-aligned CONTEXT buffer. `GetThreadContext` fills it; the
/// controller pokes the debug-register fields and hands it to
/// `SetThreadContext`.
pub const ContextBuf = struct {
    bytes: [ctx_size]u8 align(16) = [_]u8{0} ** ctx_size,

    pub fn getU32(self: *const ContextBuf, off: usize) u32 {
        return std.mem.readInt(u32, self.bytes[off..][0..4], .little);
    }
    pub fn setU32(self: *ContextBuf, off: usize, v: u32) void {
        std.mem.writeInt(u32, self.bytes[off..][0..4], v, .little);
    }
    pub fn getU64(self: *const ContextBuf, off: usize) u64 {
        return std.mem.readInt(u64, self.bytes[off..][0..8], .little);
    }
    pub fn setU64(self: *ContextBuf, off: usize, v: u64) void {
        std.mem.writeInt(u64, self.bytes[off..][0..8], v, .little);
    }
};

// -- DEBUG_EVENT layout + debug/exception codes -------------------------------

/// Debug-event codes and exception codes we classify.
pub const EXCEPTION_DEBUG_EVENT: u32 = 1;
pub const EXIT_PROCESS_DEBUG_EVENT: u32 = 5;
pub const EXCEPTION_BREAKPOINT: u32 = 0x8000_0003;
pub const EXCEPTION_SINGLE_STEP: u32 = 0x8000_0004;

/// Field offsets into `DEBUG_EVENT` on 64-bit Windows (the union is 8-aligned,
/// so it begins at offset 16). We read the code, the thread id, and — for an
/// exception event — the `EXCEPTION_RECORD` code and address.
pub const dbg = struct {
    pub const size: usize = 176; // generous upper bound; only leading fields read
    pub const off_code: usize = 0; // dwDebugEventCode
    pub const off_thread: usize = 8; // dwThreadId
    pub const off_exc_code: usize = 16; // union.Exception.ExceptionRecord.ExceptionCode
    pub const off_exc_addr: usize = 32; // union.Exception.ExceptionRecord.ExceptionAddress
    pub const off_exit_code: usize = 16; // union.ExitProcess.dwExitCode
};

// -- kernel32 externs ---------------------------------------------------------

pub const HANDLE = std.os.windows.HANDLE;
pub const DWORD = std.os.windows.DWORD;
pub const BOOL = std.os.windows.BOOL;

// Thread access rights we need to read/write a context and control the thread.
pub const THREAD_GET_CONTEXT: DWORD = 0x0008;
pub const THREAD_SET_CONTEXT: DWORD = 0x0010;
pub const THREAD_SUSPEND_RESUME: DWORD = 0x0002;
pub const THREAD_ACCESS: DWORD = THREAD_GET_CONTEXT | THREAD_SET_CONTEXT | THREAD_SUSPEND_RESUME;

pub const PROCESS_VM_OPERATION: DWORD = 0x0008;
pub const PROCESS_VM_READ: DWORD = 0x0010;
pub const PROCESS_VM_WRITE: DWORD = 0x0020;

pub const DBG_CONTINUE: DWORD = 0x0001_0002;
pub const DBG_EXCEPTION_NOT_HANDLED: DWORD = 0x8001_0001;
pub const INFINITE: DWORD = 0xFFFF_FFFF;
pub const ERROR_ACCESS_DENIED: DWORD = 5;

pub extern "kernel32" fn OpenThread(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwThreadId: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetThreadContext(hThread: HANDLE, lpContext: *anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetThreadContext(hThread: HANDLE, lpContext: *const anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn DebugActiveProcess(dwProcessId: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn DebugActiveProcessStop(dwProcessId: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForDebugEventEx(lpDebugEvent: *anyopaque, dwMilliseconds: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn ContinueDebugEvent(dwProcessId: DWORD, dwThreadId: DWORD, dwContinueStatus: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadProcessMemory(hProcess: ?*anyopaque, addr: ?*const anyopaque, buf: [*]u8, size: usize, read: ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteProcessMemory(hProcess: ?*anyopaque, addr: ?*anyopaque, buf: [*]const u8, size: usize, wrote: ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn AddVectoredExceptionHandler(First: c_ulong, Handler: *const anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

test "CONTEXT layout constants are self-consistent for the host arch" {
    if (is_x86) {
        try std.testing.expectEqual(@as(usize, 1232), ctx_size);
        try std.testing.expectEqual(@as(usize, 0x30), off_flags);
    } else if (is_arm64) {
        try std.testing.expectEqual(@as(usize, 912), ctx_size);
        try std.testing.expectEqual(@as(usize, 0x00), off_flags);
    } else {
        try std.testing.expectEqual(@as(u32, 0), ctx_flags);
    }
}
