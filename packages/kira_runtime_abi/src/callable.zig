const std = @import("std");

pub const native_closure_tag_bit: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);
pub const native_closure_pointer_mask: usize = ~native_closure_tag_bit;

pub fn tagNativeClosurePointer(ptr: usize) usize {
    return ptr | native_closure_tag_bit;
}

pub fn untagNativeClosurePointer(ptr: usize) usize {
    return ptr & native_closure_pointer_mask;
}

pub fn isTaggedNativeClosurePointer(ptr: usize) bool {
    return (ptr & native_closure_tag_bit) != 0;
}

test "native closure pointer tagging is reversible" {
    const raw: usize = 0x1234_5678;
    const tagged = tagNativeClosurePointer(raw);
    try std.testing.expect(isTaggedNativeClosurePointer(tagged));
    try std.testing.expectEqual(raw, untagNativeClosurePointer(tagged));
}
