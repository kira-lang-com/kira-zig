//! String-primitive opcode handlers (`String(x)` conversions, `charAt`,
//! `substring`, `indexOf`), extracted from the interpreter dispatch loop.
//!
//! These are cold relative to the dispatch path, and their arm bodies carry
//! enough locals (format buffers, slices) that keeping them inline measurably
//! inflated `runPrepared`'s native stack frame — enough to push the native
//! overflow cliff BELOW the 256-frame recursion guard (S6), turning the
//! guard's clean RuntimeFailure into a segfault. `noinline` keeps their
//! locals out of the dispatch frame; do not inline these back.
//!
//! Semantics are the parity contract with the native runtime helpers in
//! packages/kira_native_bridge/src/runtime_helpers.c — keep both in sync.

const std = @import("std");
const runtime_abi = @import("kira_runtime_abi");
const vm_mod = @import("vm.zig");
const slot_impl = @import("vm_slot_utils.zig");

const Vm = vm_mod.Vm;
const setSlotOwned = slot_impl.setSlotOwned;

/// `String(Int|Float|Bool)`. Format matches `print(scalar)` per the VM
/// builtins: integers base-10, Float via `{d}`, Bool as "true"/"false".
pub noinline fn stringFromScalar(
    vm: *Vm,
    registers: []runtime_abi.Value,
    register_owned: []bool,
    value: anytype,
) !void {
    const scalar = registers[value.src];
    const rendered: []u8 = switch (value.source) {
        .integer => blk: {
            if (scalar != .integer) {
                vm.rememberError("String(Int) requires an integer value");
                return error.RuntimeFailure;
            }
            break :blk try std.fmt.allocPrint(vm.heap.allocator, "{d}", .{scalar.integer});
        },
        .float => blk: {
            if (scalar != .float) {
                vm.rememberError("String(Float) requires a float value");
                return error.RuntimeFailure;
            }
            break :blk try std.fmt.allocPrint(vm.heap.allocator, "{d}", .{scalar.float});
        },
        .boolean => blk: {
            if (scalar != .boolean) {
                vm.rememberError("String(Bool) requires a boolean value");
                return error.RuntimeFailure;
            }
            break :blk try vm.heap.allocator.dupe(u8, if (scalar.boolean) "true" else "false");
        },
    };
    try vm.heap.registerString(rendered);
    setSlotOwned(vm, &registers[value.dst], &register_owned[value.dst], .{ .string = rendered });
}

/// `s.charAt(i)` — the byte at offset `i` as an Int. Out of bounds traps.
pub noinline fn stringCharAt(
    vm: *Vm,
    registers: []runtime_abi.Value,
    register_owned: []bool,
    value: anytype,
) !void {
    const string_value = registers[value.string];
    const index_value = registers[value.index];
    if (string_value != .string or index_value != .integer) {
        vm.rememberError("charAt requires a string value and an integer index");
        return error.RuntimeFailure;
    }
    if (index_value.integer < 0 or index_value.integer >= @as(i64, @intCast(string_value.string.len))) {
        vm.rememberError("string index is out of bounds");
        return error.RuntimeFailure;
    }
    const byte = string_value.string[@intCast(index_value.integer)];
    setSlotOwned(vm, &registers[value.dst], &register_owned[value.dst], .{ .integer = @intCast(byte) });
}

/// `s.substring(start, end)` — half-open byte range as a fresh owned String.
/// An invalid range traps.
pub noinline fn stringSubstring(
    vm: *Vm,
    registers: []runtime_abi.Value,
    register_owned: []bool,
    value: anytype,
) !void {
    const string_value = registers[value.string];
    const start_value = registers[value.start];
    const end_value = registers[value.end];
    if (string_value != .string or start_value != .integer or end_value != .integer) {
        vm.rememberError("substring requires a string value and integer bounds");
        return error.RuntimeFailure;
    }
    const len: i64 = @intCast(string_value.string.len);
    if (start_value.integer < 0 or end_value.integer > len or start_value.integer > end_value.integer) {
        vm.rememberError("string substring range is out of bounds");
        return error.RuntimeFailure;
    }
    const start: usize = @intCast(start_value.integer);
    const end: usize = @intCast(end_value.integer);
    const slice = try vm.heap.allocator.dupe(u8, string_value.string[start..end]);
    try vm.heap.registerString(slice);
    setSlotOwned(vm, &registers[value.dst], &register_owned[value.dst], .{ .string = slice });
}

/// `s.indexOf(needle)` — byte offset of the first occurrence, 0 for an empty
/// needle, -1 when absent.
pub noinline fn stringIndexOf(
    vm: *Vm,
    registers: []runtime_abi.Value,
    register_owned: []bool,
    value: anytype,
) !void {
    const string_value = registers[value.string];
    const needle_value = registers[value.needle];
    if (string_value != .string or needle_value != .string) {
        vm.rememberError("indexOf requires string values");
        return error.RuntimeFailure;
    }
    const found: i64 = if (needle_value.string.len == 0)
        0
    else if (std.mem.indexOf(u8, string_value.string, needle_value.string)) |offset|
        @intCast(offset)
    else
        -1;
    setSlotOwned(vm, &registers[value.dst], &register_owned[value.dst], .{ .integer = found });
}

test {
    std.testing.refAllDecls(@This());
}
