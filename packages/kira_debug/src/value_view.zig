//! Read-only rendering of a runtime `Value` into the human string the variables
//! view shows. This module NEVER moves, drops, copies-into-runtime, or frees the
//! value it inspects: the VM tracks affine ownership through a parallel `owned[]`
//! bool array, so a debugger that duplicated or released a slot would manufacture
//! a double-free or a leak the runtime can't see. Everything here reads the
//! union tag and formats a fresh, caller-owned string; the runtime's storage is
//! untouched. For `raw_ptr`, we refuse to dereference blindly — an optional
//! injected describe callback may name the heap object's type, and that name is
//! the only thing we trust about the pointee.
const std = @import("std");
const abi = @import("kira_runtime_abi");
const debug_info = @import("debug_info.zig");

const Value = abi.Value;
const LocalView = debug_info.LocalView;

/// A callback that best-effort names the heap object a `raw_ptr` refers to
/// (e.g. "struct Point", "enum Color", "closure"). It must itself be read-only
/// and must tolerate any bit pattern: return null when the pointer can't be
/// safely described rather than dereferencing an unknown address. The returned
/// slice is borrowed — `render` copies out of it and never frees it.
pub const DescribeFn = *const fn (usize) ?[]const u8;

/// Public surface of this module, grouped so the integration stage can wire a
/// single stable handle. The free functions below remain callable directly too.
pub const API = struct {
    pub const DescribeFn = @import("value_view.zig").DescribeFn;
    pub const render = @import("value_view.zig").render;
    pub const renderLocal = @import("value_view.zig").renderLocal;
};

/// Render `value` into a fresh, caller-owned display string. Read-only: the
/// value's runtime storage (including any heap the `string`/`raw_ptr` variants
/// point at) is never mutated or freed. Caller owns and frees the result.
pub fn render(allocator: std.mem.Allocator, value: Value, describe: ?DescribeFn) ![]const u8 {
    switch (value) {
        .void => return allocator.dupe(u8, "void"),
        .integer => |n| return std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| return std.fmt.allocPrint(allocator, "{d}", .{f}),
        .boolean => |b| return allocator.dupe(u8, if (b) "true" else "false"),
        // Copy the bytes into a quoted display string. Copying the *contents*
        // is safe; it does not transfer ownership of the runtime's backing
        // buffer, which the VM still owns and will free.
        .string => |s| return std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
        // Never dereference the pointer ourselves. Ask the injected describer to
        // name the pointee; if it declines (or none is wired), show only the
        // address so the view stays truthful about what we actually know.
        .raw_ptr => |p| {
            if (describe) |d| {
                if (d(p)) |type_name| {
                    return std.fmt.allocPrint(allocator, "<{s}@0x{x}>", .{ type_name, p });
                }
            }
            return std.fmt.allocPrint(allocator, "0x{x}", .{p});
        },
    }
}

/// Build a full `LocalView` for one slot: renders `value` (read-only) and pairs
/// it with the local's name, slot index, and declared type. `name` and
/// `type_name` are borrowed by reference into the returned view (the debugger
/// owns their lifetime); only `value` is freshly allocated and caller-owned.
pub fn renderLocal(
    allocator: std.mem.Allocator,
    name: []const u8,
    slot: u32,
    type_name: []const u8,
    value: Value,
    describe: ?DescribeFn,
) !LocalView {
    const rendered = try render(allocator, value, describe);
    return LocalView{
        .name = name,
        .type_name = type_name,
        .value = rendered,
        .slot = slot,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "render void" {
    const a = std.testing.allocator;
    const s = try render(a, Value{ .void = {} }, null);
    defer a.free(s);
    try std.testing.expectEqualStrings("void", s);
}

test "render integer" {
    const a = std.testing.allocator;
    const s = try render(a, Value{ .integer = -42 }, null);
    defer a.free(s);
    try std.testing.expectEqualStrings("-42", s);
}

test "render float" {
    const a = std.testing.allocator;
    const s = try render(a, Value{ .float = 3.5 }, null);
    defer a.free(s);
    try std.testing.expectEqualStrings("3.5", s);
}

test "render boolean" {
    const a = std.testing.allocator;
    const t = try render(a, Value{ .boolean = true }, null);
    defer a.free(t);
    try std.testing.expectEqualStrings("true", t);
    const f = try render(a, Value{ .boolean = false }, null);
    defer a.free(f);
    try std.testing.expectEqualStrings("false", f);
}

test "render string is quoted and does not free the source buffer" {
    const a = std.testing.allocator;
    // Heap-allocate the source to prove render() never frees it (leak/UAF check).
    const src = try a.dupe(u8, "hello");
    defer a.free(src);
    const s = try render(a, Value{ .string = src }, null);
    defer a.free(s);
    try std.testing.expectEqualStrings("\"hello\"", s);
    // Source still readable and independently freeable — render copied, not moved.
    try std.testing.expectEqualStrings("hello", src);
}

fn describeStruct(ptr: usize) ?[]const u8 {
    _ = ptr;
    return "struct Point";
}

fn describeNothing(ptr: usize) ?[]const u8 {
    _ = ptr;
    return null;
}

test "render raw_ptr with describe callback names the pointee" {
    const a = std.testing.allocator;
    const s = try render(a, Value{ .raw_ptr = 0xdead }, describeStruct);
    defer a.free(s);
    try std.testing.expectEqualStrings("<struct Point@0xdead>", s);
}

test "render raw_ptr without a describer shows only the address" {
    const a = std.testing.allocator;
    const s = try render(a, Value{ .raw_ptr = 0xbeef }, null);
    defer a.free(s);
    try std.testing.expectEqualStrings("0xbeef", s);
}

test "render raw_ptr when describer declines shows only the address" {
    const a = std.testing.allocator;
    const s = try render(a, Value{ .raw_ptr = 0x1000 }, describeNothing);
    defer a.free(s);
    try std.testing.expectEqualStrings("0x1000", s);
}

test "renderLocal pairs metadata with a read-only rendered value" {
    const a = std.testing.allocator;
    const view = try renderLocal(a, "count", 3, "Int", Value{ .integer = 7 }, null);
    defer a.free(view.value);
    try std.testing.expectEqualStrings("count", view.name);
    try std.testing.expectEqualStrings("Int", view.type_name);
    try std.testing.expectEqual(@as(u32, 3), view.slot);
    try std.testing.expectEqualStrings("7", view.value);
}
