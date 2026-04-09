const std = @import("std");

pub const IndexConfig = struct {
    schema: u32 = 1,
    archives_base_url: []const u8,
    api_base_url: ?[]const u8 = null,
    auth: ?AuthConfig = null,

    pub const AuthConfig = struct {
        token_env: ?[]const u8 = null,
    };
};

pub const PackageMetadata = struct {
    name: []const u8,
    versions: []const Version,

    pub const Version = struct {
        version: []const u8,
        checksum: []const u8,
        kira: []const u8,
        kind: []const u8,
        module_root: ?[]const u8 = null,
        archive: []const u8,
        dependencies: []const Dependency = &.{},
        description: ?[]const u8 = null,
        repository: ?[]const u8 = null,
        license: ?[]const u8 = null,
    };

    pub const Dependency = struct {
        name: []const u8,
        version: ?[]const u8 = null,
        git: ?[]const u8 = null,
        rev: ?[]const u8 = null,
        tag: ?[]const u8 = null,
    };
};

pub fn sparseIndexPath(allocator: std.mem.Allocator, package_name: []const u8) ![]u8 {
    const lowered = try std.ascii.allocLowerString(allocator, package_name);
    defer allocator.free(lowered);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{lowered});
    defer allocator.free(file_name);

    return switch (lowered.len) {
        0 => error.InvalidPackageName,
        1 => std.fs.path.join(allocator, &.{ "1", file_name }),
        2 => std.fs.path.join(allocator, &.{ "2", file_name }),
        3 => std.fs.path.join(allocator, &.{ "3", lowered[0..1], file_name }),
        else => std.fs.path.join(allocator, &.{ lowered[0..2], lowered[2..4], file_name }),
    };
}

test "builds sparse index path" {
    const one = try sparseIndexPath(std.testing.allocator, "a");
    defer std.testing.allocator.free(one);
    const one_expected = try std.fs.path.join(std.testing.allocator, &.{ "1", "a.json" });
    defer std.testing.allocator.free(one_expected);
    try std.testing.expectEqualStrings(one_expected, one);

    const two = try sparseIndexPath(std.testing.allocator, "ab");
    defer std.testing.allocator.free(two);
    const two_expected = try std.fs.path.join(std.testing.allocator, &.{ "2", "ab.json" });
    defer std.testing.allocator.free(two_expected);
    try std.testing.expectEqualStrings(two_expected, two);

    const three = try sparseIndexPath(std.testing.allocator, "abc");
    defer std.testing.allocator.free(three);
    const three_expected = try std.fs.path.join(std.testing.allocator, &.{ "3", "a", "abc.json" });
    defer std.testing.allocator.free(three_expected);
    try std.testing.expectEqualStrings(three_expected, three);

    const four = try sparseIndexPath(std.testing.allocator, "FrostUI");
    defer std.testing.allocator.free(four);
    const four_expected = try std.fs.path.join(std.testing.allocator, &.{ "fr", "os", "frostui.json" });
    defer std.testing.allocator.free(four_expected);
    try std.testing.expectEqualStrings(four_expected, four);
}
