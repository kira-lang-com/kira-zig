//! AArch64 debug-register layout and encoding math for the macOS/Apple-Silicon
//! hardware-debug controller. Split out of `darwin_arm64.zig` (Core Law #5).
//!
//! Everything here is pure and host-independent: the `ArmThreadState64` /
//! `ArmDebugState64` structs mirror the XNU thread-state records, and the
//! `encode*` / `align*` helpers pack the `DBGBCR`/`DBGWCR` control fields per the
//! Arm Architecture Reference Manual. Unit-tested below on any host.
const std = @import("std");
const di = @import("../debug_info.zig");

// ---------------------------------------------------------------------------
// XNU thread-state flavors (from <mach/arm/thread_status.h>). Left untyped so
// each coerces to both the signed `thread_state_flavor_t` used by
// task_set_exception_ports and the unsigned `thread_flavor_t` used by
// thread_get_state / thread_set_state.
// ---------------------------------------------------------------------------

/// `ARM_THREAD_STATE64` flavor => 6.
pub const ARM_THREAD_STATE64 = 6;
/// `ARM_DEBUG_STATE64` flavor => 15.
pub const ARM_DEBUG_STATE64 = 15;
/// `ARM_THREAD_STATE64_COUNT` = sizeof(arm_thread_state64_t)/sizeof(u32) = 68.
pub const ARM_THREAD_STATE64_COUNT: u32 = @sizeOf(ArmThreadState64) / @sizeOf(u32);
/// `ARM_DEBUG_STATE64_COUNT` = sizeof(arm_debug_state64_t)/sizeof(u32) = 130.
pub const ARM_DEBUG_STATE64_COUNT: u32 = @sizeOf(ArmDebugState64) / @sizeOf(u32);

/// `PSTATE.SS` (software-step) bit within CPSR/SPSR. Arm ARM D2 => bit 21.
pub const PSTATE_SS_BIT: u32 = 1 << 21;
/// `MDSCR_EL1.SS` (software-step enable). Arm ARM D13 => bit 0.
pub const MDSCR_SS_BIT: u64 = 1 << 0;

// ---------------------------------------------------------------------------
// AArch64 thread/debug state as laid out by the XNU headers.
// ---------------------------------------------------------------------------

/// `arm_thread_state64_t`. 68 x u32 = 272 bytes.
pub const ArmThreadState64 = extern struct {
    x: [29]u64, // x0..x28
    fp: u64,
    lr: u64,
    sp: u64,
    pc: u64,
    cpsr: u32,
    __pad: u32,
};

/// `arm_debug_state64_t`. 130 x u32 = 520 bytes.
pub const ArmDebugState64 = extern struct {
    bvr: [16]u64,
    bcr: [16]u64,
    wvr: [16]u64,
    wcr: [16]u64,
    mdscr_el1: u64,
};

// ---------------------------------------------------------------------------
// Register-encoding math.
//
// DBGBCR<n>_EL1 (execution breakpoint control):
//   E     bit [0]      enable
//   PMC   bits [2:1]   privilege-mode control; 0b10 = EL0 (user)
//   BAS   bits [8:5]   byte-address-select; 0b1111 = match the whole A64 word
//   BT    bits [23:20] breakpoint type; 0b0000 = unlinked address match
//
// DBGWCR<n>_EL1 (watchpoint control):
//   E     bit [0]      enable
//   PAC   bits [2:1]   privilege access control; 0b10 = EL0 (user)
//   LSC   bits [4:3]   load/store control; 01=load/read 10=store/write 11=both
//   BAS   bits [12:5]  byte-address-select (8 bits, one per byte in the window)
// ---------------------------------------------------------------------------

/// Word-align an instruction address for `BVR` (A64 instructions are 4-byte).
pub fn alignExec(addr: u64) u64 {
    return addr & ~@as(u64, 0x3);
}

/// Double-word-align a data address for `WVR`; `BAS` selects bytes in the
/// 8-byte window starting at this base.
pub fn alignWatch(addr: u64) u64 {
    return addr & ~@as(u64, 0x7);
}

/// `BCR` value for a user-space execution breakpoint: E | PMC(EL0) | BAS(word).
/// = 0b1 | (0b10 << 1) | (0b1111 << 5) = 0x1E5.
pub fn encodeExecBcr() u64 {
    const e: u64 = 1;
    const pmc: u64 = 0b10 << 1;
    const bas: u64 = 0b1111 << 5;
    return e | pmc | bas;
}

/// `BAS` byte-mask for a watchpoint of `len` bytes at `addr`, positioned within
/// the 8-byte aligned window. Clamped to the 8-bit field.
pub fn encodeWatchBas(addr: u64, len: u16) u64 {
    const off: u6 = @intCast(addr & 0x7);
    const bytes: u16 = if (len == 0) 1 else if (len > 8) 8 else len;
    const mask: u64 = (@as(u64, 1) << @as(u4, @intCast(bytes))) - 1;
    return (mask << off) & 0xff;
}

/// Load/store control field for a watch kind.
pub fn lscFor(kind: di.WatchKind) u64 {
    return switch (kind) {
        .read => 0b01,
        .write => 0b10,
        .read_write => 0b11,
    };
}

/// Full `WCR` value: E | PAC(EL0) | LSC(kind) | BAS(addr,len).
pub fn encodeWcr(addr: u64, len: u16, kind: di.WatchKind) u64 {
    const e: u64 = 1;
    const pac: u64 = 0b10 << 1;
    const lsc: u64 = lscFor(kind) << 3;
    const bas: u64 = encodeWatchBas(addr, len) << 5;
    return e | pac | lsc | bas;
}

// ---------------------------------------------------------------------------
// Tests — host-independent register-encoding math.
// ---------------------------------------------------------------------------

test "state counts match the XNU-defined register layout" {
    try std.testing.expectEqual(@as(u32, 68), ARM_THREAD_STATE64_COUNT);
    try std.testing.expectEqual(@as(u32, 130), ARM_DEBUG_STATE64_COUNT);
}

test "exec BCR packs E | PMC(EL0) | BAS(word)" {
    // 0b1 | (0b10<<1) | (0b1111<<5) = 0x1E5
    try std.testing.expectEqual(@as(u64, 0x1E5), encodeExecBcr());
}

test "exec address is word-aligned for BVR" {
    try std.testing.expectEqual(@as(u64, 0x1004), alignExec(0x1006));
    try std.testing.expectEqual(@as(u64, 0x1000), alignExec(0x1000));
    try std.testing.expectEqual(@as(u64, 0x1004), alignExec(0x1007));
}

test "watch address is doubleword-aligned for WVR" {
    try std.testing.expectEqual(@as(u64, 0x1008), alignWatch(0x100F));
    try std.testing.expectEqual(@as(u64, 0x1000), alignWatch(0x1000));
}

test "watch BAS selects the accessed bytes in the 8-byte window" {
    // 4 bytes at an 8-aligned base => low nibble.
    try std.testing.expectEqual(@as(u64, 0x0F), encodeWatchBas(0x1000, 4));
    // 8 bytes => whole window.
    try std.testing.expectEqual(@as(u64, 0xFF), encodeWatchBas(0x1000, 8));
    // 2 bytes at offset +2 => bits [3:2].
    try std.testing.expectEqual(@as(u64, 0b1100), encodeWatchBas(0x1002, 2));
    // 1 byte at offset +7 => top bit.
    try std.testing.expectEqual(@as(u64, 0x80), encodeWatchBas(0x1007, 1));
    // len==0 defaults to a single byte.
    try std.testing.expectEqual(@as(u64, 0x01), encodeWatchBas(0x1000, 0));
}

test "WCR packs E | PAC(EL0) | LSC(kind) | BAS" {
    // read, 4 bytes, aligned: 1 | (0b10<<1=4) | (0b01<<3=8) | (0x0F<<5=0x1E0) = 0x1ED
    try std.testing.expectEqual(@as(u64, 0x1ED), encodeWcr(0x1000, 4, .read));
    // write, 4 bytes: LSC=0b10 => (2<<3=0x10). 1 | 4 | 0x10 | 0x1E0 = 0x1F5
    try std.testing.expectEqual(@as(u64, 0x1F5), encodeWcr(0x1000, 4, .write));
    // read_write, 8 bytes: LSC=0b11 => 0x18, BAS=0xFF => 0x1FE0. 1|4|0x18|0x1FE0 = 0x1FFD
    try std.testing.expectEqual(@as(u64, 0x1FFD), encodeWcr(0x1000, 8, .read_write));
}

test "LSC field encodes each watch kind" {
    try std.testing.expectEqual(@as(u64, 0b01), lscFor(.read));
    try std.testing.expectEqual(@as(u64, 0b10), lscFor(.write));
    try std.testing.expectEqual(@as(u64, 0b11), lscFor(.read_write));
}
