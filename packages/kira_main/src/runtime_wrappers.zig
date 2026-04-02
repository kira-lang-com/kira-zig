const std = @import("std");

pub fn cStringSlice(value: [*:0]const u8) []const u8 {
    return std.mem.span(value);
}
