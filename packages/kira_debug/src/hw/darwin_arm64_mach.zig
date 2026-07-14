//! Mach exception-message layout and XNU exception constants for the
//! macOS/Apple-Silicon hardware-debug controller. Split out of `darwin_arm64.zig`
//! (Core Law #5).
//!
//! Models the `mach_exception_raise` request/reply pair (behavior
//! `EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES`) that the kernel sends to our
//! exception port when the inferior hits a hardware breakpoint / watchpoint or a
//! software-step exception, and the MIG reply we send back to resume it.
//!
//! Every constant is defined here from the XNU headers (cited inline) because
//! they are absent from Zig's std.c and we do not `@cImport` macOS headers.
const std = @import("std");

// ---------------------------------------------------------------------------
// XNU exception constants.
// ---------------------------------------------------------------------------

/// `EXC_BREAKPOINT`. XNU: osfmk/mach/exception_types.h => 6. Untyped so it
/// compares directly against the message's signed `exception` field.
pub const EXC_BREAKPOINT = 6;
/// `EXC_MASK_BREAKPOINT` = 1 << EXC_BREAKPOINT. XNU => 0x40.
pub const EXC_MASK_BREAKPOINT: u32 = 1 << @as(u5, EXC_BREAKPOINT);
/// `EXCEPTION_DEFAULT` behavior (send catch_exception_raise). XNU => 1.
pub const EXCEPTION_DEFAULT: u32 = 1;
/// `MACH_EXCEPTION_CODES` — request 64-bit code/subcode. XNU => 0x80000000.
pub const MACH_EXCEPTION_CODES: u32 = 0x80000000;
/// `KERN_SUCCESS`. XNU: osfmk/mach/kern_return.h => 0.
pub const KERN_SUCCESS: std.c.kern_return_t = 0;
/// `MACH_MSGH_BITS_REMOTE_MASK`. XNU: osfmk/mach/message.h => 0x0000001f.
pub const MACH_MSGH_BITS_REMOTE_MASK: u32 = 0x0000001f;
/// MIG reply message id offset (request id + 100). XNU MIG convention.
pub const MIG_REPLY_ID_OFFSET: i32 = 100;

// ---------------------------------------------------------------------------
// Message layout for EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES.
// ---------------------------------------------------------------------------

/// `NDR_record_t` (8 bytes).
pub const NdrRecord = extern struct {
    mig_vers: u8 = 0,
    if_vers: u8 = 0,
    reserved1: u8 = 0,
    mig_encoding: u8 = 0,
    int_rep: u8 = 0,
    char_rep: u8 = 0,
    float_rep: u8 = 0,
    reserved2: u8 = 0,
};

/// `mach_msg_port_descriptor_t` (12 bytes on LP64): name, pad1, then a packed
/// {pad2:16, disposition:8, type:8}.
pub const MachPortDescriptor = extern struct {
    name: u32,
    pad1: u32,
    bits: u32,
};

/// `__Request__mach_exception_raise_t` plus receive-trailer slack.
pub const ExcRequest = extern struct {
    header: std.c.mach_msg_header_t,
    body: u32, // msgh_descriptor_count
    thread: MachPortDescriptor,
    task: MachPortDescriptor,
    ndr: NdrRecord,
    exception: i32,
    code_cnt: u32,
    code: [2]i64,
    trailer: [64]u8,
};

/// `__Reply__mach_exception_raise_t`.
pub const ExcReply = extern struct {
    header: std.c.mach_msg_header_t,
    ndr: NdrRecord,
    ret_code: std.c.kern_return_t,
};

/// `mach_thread_self()` — a send right to the calling thread. Not re-exported by
/// std.c, so declared directly.
pub extern "c" fn mach_thread_self() std.c.mach_port_t;

test "EXC_MASK_BREAKPOINT is 1 << EXC_BREAKPOINT" {
    try std.testing.expectEqual(@as(u32, 0x40), EXC_MASK_BREAKPOINT);
}

test "exception message structs match the LP64 wire sizes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(NdrRecord));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(MachPortDescriptor));
}
