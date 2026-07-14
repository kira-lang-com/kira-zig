//! Pure, portable debug-register control-word encoding for the Windows
//! `HwBreakpointController` (see `windows.zig`). Split out under Core Law #5 so
//! the encoding — the part with real logic worth unit-testing — stays a small,
//! host-independent module: nothing here touches a Win32 API, so every test runs
//! on any host.
//!
//! Two encodings live here:
//!   * **x86 DR7** — 2-bit local-enable pairs plus 4-bit condition fields
//!     (R/W + length) per slot, exactly as the CPU consumes them.
//!   * **arm64 BCR/WCR** — the ARM debug architecture control words for
//!     instruction breakpoints (BCR) and data watchpoints (WCR): enable +
//!     privilege + byte-address-select, and for watch a load/store-control field.

const std = @import("std");
const di = @import("../debug_info.zig");
const ctrl = @import("controller.zig");

const HwError = ctrl.HwError;

/// Number of hardware address slots we expose per class. x86 shares four debug
/// registers (`Dr0`-`Dr3`) across exec+watch; arm64 has separate `Bvr`/`Wvr`
/// banks. Four is the common floor advertised across both arches.
pub const slot_count: u8 = 4;

/// Logical-slot id bit marking an arm64 watch (`Wvr`) slot, so `disarm` can tell
/// which register bank a slot belongs to. Exec/x86 slots are plain indices.
pub const watch_flag: u8 = 0x80;

// -- x86 DR7 control-word encoding --------------------------------------------

/// R/W condition field (2 bits per slot in DR7 at bit `16 + 4*n`):
///   00 execute, 01 write, 11 read-or-write. x86 has no read-only trap, so a
/// read watch is encoded as read-or-write.
pub const Rw = enum(u2) { exec = 0b00, write = 0b01, read_write = 0b11 };

/// Length field (2 bits per slot in DR7 at bit `18 + 4*n`):
///   00 = 1 byte, 01 = 2 bytes, 11 = 4 bytes, 10 = 8 bytes (the architectural
/// 4/8 swap relative to the numeric value).
pub const Len = enum(u2) { one = 0b00, two = 0b01, four = 0b11, eight = 0b10 };

/// One slot's DR7 contribution.
pub const Dr7Slot = struct {
    enabled: bool = false,
    rw: Rw = .exec,
    len: Len = .one,
};

/// Local-enable bit for slot `n` (DR7 bit `2*n`; the global-enable `2*n+1` is
/// left clear — per-thread local enable is what a debugger wants).
fn localEnableBit(n: u8) u64 {
    return @as(u64, 1) << @intCast(2 * @as(u6, @intCast(n)));
}

/// Bit position of slot `n`'s R/W condition field in DR7.
fn condShift(n: u8) u6 {
    return @intCast(16 + 4 * @as(u6, @intCast(n)));
}

/// Pack four slot configs into a DR7 value. Bit 10 is architecturally
/// read-as-one and set to match hardware expectations.
pub fn packDr7(slots: [slot_count]Dr7Slot) u64 {
    var v: u64 = 1 << 10; // reserved, must-be-one
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
/// x86 debug registers cannot express.
pub fn lenForBytes(bytes: u16) HwError!Len {
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
pub fn rwForWatch(kind: di.WatchKind) Rw {
    return switch (kind) {
        .write => .write,
        .read, .read_write => .read_write,
    };
}

// -- arm64 BCR/WCR control-word encoding --------------------------------------

/// Load/store control (WCR bits 3-4): 01 load (read), 10 store (write), 11 both.
fn lscForWatch(kind: di.WatchKind) u32 {
    return switch (kind) {
        .read => 0b01,
        .write => 0b10,
        .read_write => 0b11,
    };
}

/// Byte-address-select mask for a naturally-aligned watch of `bytes` bytes:
/// one set bit per watched byte (`(1<<bytes)-1`). WCR BAS is 8 bits (WVR covers
/// up to 8 bytes); BCR BAS is 4 bits.
pub fn basForBytes(bytes: u16) HwError!u32 {
    return switch (bytes) {
        1, 2, 4, 8 => (@as(u32, 1) << @intCast(bytes)) - 1,
        else => HwError.Unsupported,
    };
}

/// Pack an arm64 instruction-breakpoint control register (BCR):
///   E=1 (bit0), PMC=0b10 (bits1-2, EL0/unlinked), BAS=0b1111 (bits5-8, all four
/// bytes of the aligned A64 instruction). Disabled slots pack to zero.
pub fn packBcr(enabled: bool) u32 {
    if (!enabled) return 0;
    return 0b1 | (@as(u32, 0b10) << 1) | (@as(u32, 0b1111) << 5);
}

/// Pack an arm64 watchpoint control register (WCR):
///   E=1 (bit0), PAC=0b10 (bits1-2, EL0), LSC (bits3-4), BAS (bits5-12).
pub fn packWcr(enabled: bool, kind: di.WatchKind, bytes: u16) HwError!u32 {
    if (!enabled) return 0;
    const bas = try basForBytes(bytes);
    return 0b1 | (@as(u32, 0b10) << 1) | (lscForWatch(kind) << 3) | (bas << 5);
}

// -- tests --------------------------------------------------------------------

test "packDr7 encodes an exec slot 0" {
    var slots = [_]Dr7Slot{.{}} ** slot_count;
    slots[0] = .{ .enabled = true, .rw = .exec, .len = .one };
    const v = packDr7(slots);
    try std.testing.expectEqual(@as(u64, 1), v & 0b1); // L0 set
    try std.testing.expectEqual(@as(u64, 0), (v >> 16) & 0b1111); // exec / 1-byte
    try std.testing.expectEqual(@as(u64, 1), (v >> 10) & 1); // reserved read-as-one
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

test "packDr7 disabled slots contribute nothing but the reserved bit" {
    const slots = [_]Dr7Slot{.{}} ** slot_count;
    try std.testing.expectEqual(@as(u64, 1 << 10), packDr7(slots));
}

test "packDr7 packs all four slots independently" {
    var slots = [_]Dr7Slot{.{}} ** slot_count;
    slots[0] = .{ .enabled = true, .rw = .exec, .len = .one };
    slots[1] = .{ .enabled = true, .rw = .write, .len = .two };
    slots[3] = .{ .enabled = true, .rw = .read_write, .len = .four };
    const v = packDr7(slots);
    // Local-enable bits L0, L1, L3 set; L2 clear.
    try std.testing.expectEqual(@as(u64, 0b1), v & (@as(u64, 1) << 0));
    try std.testing.expectEqual(@as(u64, 0b100), v & (@as(u64, 1) << 2));
    try std.testing.expectEqual(@as(u64, 0), v & (@as(u64, 1) << 4)); // L2 clear
    try std.testing.expectEqual(@as(u64, 0b1000000), v & (@as(u64, 1) << 6));
    // Slot 1 condition: len=01(2B)<<2 | rw=01(write) = 0b0101.
    try std.testing.expectEqual(@as(u64, 0b0101), (v >> (16 + 4 * 1)) & 0b1111);
}

test "lenForBytes maps supported widths and rejects the rest" {
    try std.testing.expectEqual(Len.one, try lenForBytes(1));
    try std.testing.expectEqual(Len.two, try lenForBytes(2));
    try std.testing.expectEqual(Len.four, try lenForBytes(4));
    try std.testing.expectEqual(Len.eight, try lenForBytes(8));
    try std.testing.expectError(HwError.Unsupported, lenForBytes(3));
    try std.testing.expectError(HwError.Unsupported, lenForBytes(16));
}

test "rwForWatch degrades read to read_write on x86" {
    try std.testing.expectEqual(Rw.read_write, rwForWatch(.read));
    try std.testing.expectEqual(Rw.write, rwForWatch(.write));
    try std.testing.expectEqual(Rw.read_write, rwForWatch(.read_write));
}

test "packBcr encodes an enabled instruction breakpoint and zero when disabled" {
    try std.testing.expectEqual(@as(u32, 0), packBcr(false));
    const v = packBcr(true);
    try std.testing.expectEqual(@as(u32, 1), v & 0b1); // E
    try std.testing.expectEqual(@as(u32, 0b10), (v >> 1) & 0b11); // PMC = EL0
    try std.testing.expectEqual(@as(u32, 0b1111), (v >> 5) & 0b1111); // BAS all four bytes
}

test "packWcr encodes a store watch with byte-address-select mask" {
    try std.testing.expectEqual(@as(u32, 0), try packWcr(false, .write, 8));
    const v = try packWcr(true, .write, 8);
    try std.testing.expectEqual(@as(u32, 1), v & 0b1); // E
    try std.testing.expectEqual(@as(u32, 0b10), (v >> 3) & 0b11); // LSC = store
    try std.testing.expectEqual(@as(u32, 0xFF), (v >> 5) & 0xFF); // BAS = 8 bytes
    const r = try packWcr(true, .read, 4);
    try std.testing.expectEqual(@as(u32, 0b01), (r >> 3) & 0b11); // LSC = load
    try std.testing.expectEqual(@as(u32, 0x0F), (r >> 5) & 0xFF); // BAS = 4 bytes
}

test "basForBytes rejects non-power-of-two widths" {
    try std.testing.expectEqual(@as(u32, 0x1), try basForBytes(1));
    try std.testing.expectEqual(@as(u32, 0x3), try basForBytes(2));
    try std.testing.expectError(HwError.Unsupported, basForBytes(3));
    try std.testing.expectError(HwError.Unsupported, basForBytes(5));
}
