const std = @import("std");

pub const Allocator = std.mem.Allocator;
pub const String = []const u8;

pub const Version = struct {
    major: u16,
    minor: u16,
    patch: u16,
};
