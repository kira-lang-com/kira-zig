const std = @import("std");

pub const LinkExtras = struct {
    include_dirs: []const []const u8 = &.{},
    defines: []const []const u8 = &.{},
    frameworks: []const []const u8 = &.{},
    system_libs: []const []const u8 = &.{},

    pub fn clone(allocator: std.mem.Allocator, extras: LinkExtras) !LinkExtras {
        return .{
            .include_dirs = try cloneStrings(allocator, extras.include_dirs),
            .defines = try cloneStrings(allocator, extras.defines),
            .frameworks = try cloneStrings(allocator, extras.frameworks),
            .system_libs = try cloneStrings(allocator, extras.system_libs),
        };
    }
};

fn cloneStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(allocator);
    for (values) |value| {
        try list.append(try allocator.dupe(u8, value));
    }
    return list.toOwnedSlice();
}
