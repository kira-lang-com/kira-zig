//! native_target_unwind — frame-pointer stack unwinding and register-layout
//! knowledge for the native `DebugTarget`.
//!
//! The hardware `HwBreakpointController` exposes only `readRegister(index)` and
//! `readMemory(addr, buf)`; it has no notion of a call stack. This module turns
//! those two primitives into a `[]Frame` backtrace by walking the standard
//! frame-record chain both AArch64 and x86-64 leave when compiled with frame
//! pointers:
//!
//!   * On entry a function stores the caller's frame pointer and the return
//!     address as an adjacent pair, and points its own FP at that pair:
//!     `[fp] = caller_fp`, `[fp + 8] = return_address`. This layout is identical
//!     on AArch64 (`x29`/`x30` via `stp`) and x86-64 (`rbp` via `push rbp`), so a
//!     single unwind loop serves both — only the *register indices* for
//!     PC/FP/SP differ per os+arch, which `layoutFor` encodes.
//!
//! Register-index conventions are read straight from each hardware controller's
//! `readRegister` contract (they differ, so they must be tracked here rather than
//! assumed uniform):
//!   * AArch64 (Darwin & Linux): `29 = fp`, `30 = lr`, `31 = sp`, `32 = pc`.
//!   * Darwin x86-64: field index into `x86_thread_state64` — `6 = rbp`,
//!     `7 = rsp`, `16 = rip`.
//!   * Linux x86-64: `index * 8` byte offset into `user_regs_struct` — `4 = rbp`,
//!     `19 = rsp`, `16 = rip`.
//!   * Windows / software-only: no frame-pointer unwind path (Windows x64 uses
//!     `RtlVirtualUnwind`, not an FP chain; software-only has no register file),
//!     so `unwind_supported = false` and unwinding honestly yields at most the
//!     top frame (from PC, when available) instead of a fabricated stack.
//!
//! `load_bias` is subtracted from every runtime PC before it is looked up in the
//! on-disk DWARF line table / symbol table: a non-PIE Kira executable links at
//! its final addresses (bias 0), while a PIE image is slid by the loader. The
//! first cut passes bias 0 and documents that computing the PIE slide (from
//! `/proc/pid/maps` or the dyld image list) is a follow-up — it never fabricates
//! a slide, so on a PIE image positions simply resolve to null rather than to a
//! wrong line.

const std = @import("std");
const debug_info = @import("debug_info.zig");
const ctrl = @import("hw/controller.zig");
const dwarf = @import("native_target_dwarf.zig");

const Frame = debug_info.Frame;
const SourcePosition = debug_info.SourcePosition;
const HwBreakpointController = ctrl.HwBreakpointController;
const Platform = ctrl.Platform;
const LineTable = dwarf.LineTable;
const Symbols = dwarf.Symbols;

/// Per-os+arch register indices for `readRegister`, plus whether an FP-chain
/// unwind is possible on this platform.
pub const RegLayout = struct {
    pc: u16,
    fp: u16,
    sp: u16,
    unwind_supported: bool,
};

/// The register layout for a platform. See the module header for the source of
/// each index.
pub fn layoutFor(platform: Platform) RegLayout {
    return switch (platform) {
        .darwin_arm64, .linux_arm64 => .{ .pc = 32, .fp = 29, .sp = 31, .unwind_supported = true },
        .darwin_x86_64 => .{ .pc = 16, .fp = 6, .sp = 7, .unwind_supported = true },
        .linux_x86_64 => .{ .pc = 16, .fp = 4, .sp = 19, .unwind_supported = true },
        .windows, .software => .{ .pc = 0, .fp = 0, .sp = 0, .unwind_supported = false },
    };
}

/// Reverse symbol lookup: the name of the defined symbol with the greatest
/// address `<= addr` (the function `addr` falls inside). Null when no table or no
/// symbol precedes the address.
pub fn symbolFor(symbols: ?Symbols, addr: u64) ?[]const u8 {
    const s = symbols orelse return null;
    var best: ?[]const u8 = null;
    var best_addr: u64 = 0;
    var it = s.map.iterator();
    while (it.next()) |kv| {
        const a = kv.value_ptr.*;
        if (a <= addr and (best == null or a > best_addr)) {
            best_addr = a;
            best = kv.key_ptr.*;
        }
    }
    return best;
}

/// The maximum frames we will unwind before giving up (a corrupt or hostile FP
/// chain must never spin forever).
pub const max_unwind_frames: usize = 256;

/// A resolved cursor: call-stack depth and the current source position. Used by
/// the step engine, which needs both at every single-step stop.
pub const Cursor = struct {
    depth: u32,
    position: ?SourcePosition,
};

/// Walk the frame-pointer chain and materialize a `[]Frame` backtrace, innermost
/// frame first. `load_bias` is subtracted from each PC before DWARF lookup.
/// Frames beyond the innermost resolve their position from `return_address - 1`
/// so a call site attributes to the calling line, not the line after the call.
///
/// Degrades honestly: if `readRegister(pc)` fails (unattached / no register
/// path) the result is empty; if `unwind_supported` is false only the top frame
/// (from PC) is produced. Caller owns the returned slice.
pub fn unwindFrames(
    allocator: std.mem.Allocator,
    hw: HwBreakpointController,
    layout: RegLayout,
    line_table: ?LineTable,
    symbols: ?Symbols,
    load_bias: u64,
    max_frames: usize,
) ![]Frame {
    var list = std.array_list.Managed(Frame).init(allocator);
    errdefer list.deinit();

    const pc0 = hw.readRegister(layout.pc) catch return list.toOwnedSlice();
    var pc = pc0;
    var fp = if (layout.unwind_supported) (hw.readRegister(layout.fp) catch 0) else 0;

    var index: u32 = 0;
    const limit = @min(max_frames, max_unwind_frames);
    while (index < limit) {
        try appendFrame(&list, index, pc, index == 0, load_bias, line_table, symbols);
        index += 1;

        if (!layout.unwind_supported or fp == 0) break;

        // Read the frame record: [fp] = caller_fp, [fp + 8] = return_address.
        var buf: [16]u8 = undefined;
        hw.readMemory(fp, &buf) catch break;
        const saved_fp = std.mem.readInt(u64, buf[0..8], .little);
        const ret = std.mem.readInt(u64, buf[8..16], .little);
        if (ret == 0) break;
        // The chain must climb toward higher addresses (stack grows down); a
        // non-increasing FP means a corrupt/terminated chain — stop rather than loop.
        if (saved_fp <= fp) break;
        pc = ret;
        fp = saved_fp;
    }

    return list.toOwnedSlice();
}

fn appendFrame(
    list: *std.array_list.Managed(Frame),
    index: u32,
    pc: u64,
    is_top: bool,
    load_bias: u64,
    line_table: ?LineTable,
    symbols: ?Symbols,
) !void {
    const static = pc -% load_bias;
    // For caller frames the PC is the return address (one past the call); bias it
    // back into the call instruction so the source line is the call site.
    const resolve_at = if (is_top) static else static -% 1;
    const position = if (line_table) |lt| lt.addressToPosition(resolve_at) else null;
    const name = symbolFor(symbols, static) orelse "";
    try list.append(.{
        .index = index,
        .backend = .native,
        // Native frames carry no manifest function id (that is a VM/hybrid
        // concept); 0 is the "unknown id" sentinel the merged view tolerates.
        .function_id = 0,
        .function_name = name,
        .position = position,
        .program_counter = pc,
    });
}

/// The current innermost source position and call-stack depth, walking the FP
/// chain without allocating. Drives the step state machine. `depth` is the frame
/// count (1 = only the current frame); `position` resolves the innermost PC.
pub fn cursor(
    hw: HwBreakpointController,
    layout: RegLayout,
    line_table: ?LineTable,
    load_bias: u64,
) Cursor {
    const pc = hw.readRegister(layout.pc) catch return .{ .depth = 0, .position = null };
    const position = if (line_table) |lt| lt.addressToPosition(pc -% load_bias) else null;
    if (!layout.unwind_supported) return .{ .depth = 1, .position = position };

    var fp = hw.readRegister(layout.fp) catch return .{ .depth = 1, .position = position };
    var depth: u32 = 1;
    while (fp != 0 and depth < max_unwind_frames) {
        var buf: [16]u8 = undefined;
        hw.readMemory(fp, &buf) catch break;
        const saved_fp = std.mem.readInt(u64, buf[0..8], .little);
        const ret = std.mem.readInt(u64, buf[8..16], .little);
        if (ret == 0 or saved_fp <= fp) break;
        depth += 1;
        fp = saved_fp;
    }
    return .{ .depth = depth, .position = position };
}

// ---------------------------------------------------------------------------
// Tests — the FP-chain walk against a synthetic in-memory stack served by a fake
// controller (no real inferior needed; host-independent).
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A fake `HwBreakpointController` serving a canned two-frame stack:
///   pc = 0x400000, fp = 0x1000
///   [0x1000] = { caller_fp = 0x1100, ret = 0x400100 }
///   [0x1100] = { caller_fp = 0x1200, ret = 0        }  (ret == 0 terminates)
/// Register indices follow the AArch64 layout (fp=29, pc=32) so the test is
/// deterministic regardless of host arch.
const FakeCtrl = struct {
    fn readRegister(ctx: *anyopaque, index: u16) anyerror!u64 {
        _ = ctx;
        return switch (index) {
            32 => 0x400000, // pc
            29 => 0x1000, // fp
            else => 0,
        };
    }
    fn readMemory(ctx: *anyopaque, addr: u64, buf: []u8) anyerror!void {
        _ = ctx;
        if (buf.len < 16) return error.BadRead;
        const rec: [2]u64 = switch (addr) {
            0x1000 => .{ 0x1100, 0x400100 },
            0x1100 => .{ 0x1200, 0 },
            else => return error.BadRead,
        };
        std.mem.writeInt(u64, buf[0..8], rec[0], .little);
        std.mem.writeInt(u64, buf[8..16], rec[1], .little);
    }
    fn capabilities(ctx: *anyopaque) debug_info.HwCapabilities {
        _ = ctx;
        return debug_info.HwCapabilities.none();
    }
    fn unsupported0(ctx: *anyopaque) anyerror!void {
        _ = ctx;
        return error.Unsupported;
    }
    fn deinit(ctx: *anyopaque) void {
        _ = ctx;
    }
    const vtable = HwBreakpointController.VTable{
        .capabilities = capabilities,
        .attach = attachStub,
        .armExec = armExecStub,
        .armWatch = armWatchStub,
        .disarm = disarmStub,
        .cont = contStub,
        .singleStep = stepStub,
        .readRegister = readRegister,
        .readMemory = readMemory,
        .writeMemory = writeStub,
        .deinit = deinit,
    };
    fn attachStub(ctx: *anyopaque, pid: i32) anyerror!void {
        _ = ctx;
        _ = pid;
    }
    fn armExecStub(ctx: *anyopaque, addr: u64) anyerror!u8 {
        _ = ctx;
        _ = addr;
        return 0;
    }
    fn armWatchStub(ctx: *anyopaque, addr: u64, len: u16, kind: debug_info.WatchKind) anyerror!u8 {
        _ = ctx;
        _ = addr;
        _ = len;
        _ = kind;
        return 0;
    }
    fn disarmStub(ctx: *anyopaque, slot: u8) anyerror!void {
        _ = ctx;
        _ = slot;
    }
    fn contStub(ctx: *anyopaque) anyerror!ctrl.HwStop {
        _ = ctx;
        return .{ .step = {} };
    }
    fn stepStub(ctx: *anyopaque) anyerror!ctrl.HwStop {
        _ = ctx;
        return .{ .step = {} };
    }
    fn writeStub(ctx: *anyopaque, addr: u64, bytes: []const u8) anyerror!void {
        _ = ctx;
        _ = addr;
        _ = bytes;
    }
};

fn fakeController() HwBreakpointController {
    const dummy = struct {
        var byte: u8 = 0;
    };
    return .{ .ptr = &dummy.byte, .vtable = &FakeCtrl.vtable };
}

const arm64_layout = RegLayout{ .pc = 32, .fp = 29, .sp = 31, .unwind_supported = true };

test "layoutFor tracks each platform's register indices" {
    try testing.expectEqual(@as(u16, 32), layoutFor(.darwin_arm64).pc);
    try testing.expectEqual(@as(u16, 29), layoutFor(.linux_arm64).fp);
    try testing.expectEqual(@as(u16, 6), layoutFor(.darwin_x86_64).fp);
    try testing.expectEqual(@as(u16, 4), layoutFor(.linux_x86_64).fp);
    try testing.expect(!layoutFor(.software).unwind_supported);
    try testing.expect(!layoutFor(.windows).unwind_supported);
}

test "unwindFrames walks the frame-pointer chain to the terminating record" {
    const hw = fakeController();
    const frames = try unwindFrames(testing.allocator, hw, arm64_layout, null, null, 0, 16);
    defer testing.allocator.free(frames);

    try testing.expectEqual(@as(usize, 2), frames.len);
    try testing.expectEqual(@as(u64, 0x400000), frames[0].program_counter);
    try testing.expectEqual(@as(u32, 0), frames[0].index);
    try testing.expectEqual(debug_info.Backend.native, frames[0].backend);
    try testing.expectEqual(@as(u64, 0x400100), frames[1].program_counter);
    try testing.expectEqual(@as(u32, 1), frames[1].index);
    // No line table -> no position, no fabricated source.
    try testing.expectEqual(@as(?SourcePosition, null), frames[0].position);
}

test "unwindFrames without unwind support yields only the top frame" {
    const hw = fakeController();
    const no_unwind = RegLayout{ .pc = 32, .fp = 29, .sp = 31, .unwind_supported = false };
    const frames = try unwindFrames(testing.allocator, hw, no_unwind, null, null, 0, 16);
    defer testing.allocator.free(frames);
    try testing.expectEqual(@as(usize, 1), frames.len);
    try testing.expectEqual(@as(u64, 0x400000), frames[0].program_counter);
}

test "cursor reports depth and stops at the terminating record" {
    const hw = fakeController();
    const c = cursor(hw, arm64_layout, null, 0);
    try testing.expectEqual(@as(u32, 2), c.depth);
}

test "symbolFor picks the greatest symbol at or below the address" {
    var syms = try dwarf.parseSymbols(testing.allocator,
        \\0000000000400000 T _start
        \\0000000000400100 T _mid
        \\0000000000400200 T _end
        \\
    );
    defer syms.deinit();
    try testing.expectEqualStrings("_start", symbolFor(syms, 0x400050).?);
    try testing.expectEqualStrings("_mid", symbolFor(syms, 0x400100).?);
    try testing.expectEqualStrings("_end", symbolFor(syms, 0x999999).?);
    // Below the first symbol -> none.
    try testing.expectEqual(@as(?[]const u8, null), symbolFor(syms, 0x100));
    try testing.expectEqual(@as(?[]const u8, null), symbolFor(null, 0x400000));
}
