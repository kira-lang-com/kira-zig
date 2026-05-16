const std = @import("std");

pub const managed_toolchains_dir = "toolchains";
pub const managed_llvm_dir = "llvm";

pub fn hostLlvmBundleKey(host: std.Target) ?[]const u8 {
    return switch (host.os.tag) {
        .windows => switch (host.cpu.arch) {
            .x86_64 => "x86_64-windows-msvc",
            else => null,
        },
        .linux => switch (host.cpu.arch) {
            .x86_64 => "x86_64-linux-gnu",
            else => null,
        },
        .macos => switch (host.cpu.arch) {
            .aarch64 => "aarch64-macos",
            else => null,
        },
        else => null,
    };
}

pub fn managedLlvmRoot(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_root, ".kira", managed_toolchains_dir, managed_llvm_dir });
}

pub fn managedLlvmVersionRoot(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    llvm_version: []const u8,
) ![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_root, ".kira", managed_toolchains_dir, managed_llvm_dir, llvm_version });
}

pub fn managedLlvmHome(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    llvm_version: []const u8,
    host_key: []const u8,
) ![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_root, ".kira", managed_toolchains_dir, managed_llvm_dir, llvm_version, host_key });
}

pub fn legacyLlvmCurrentHome(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_root, ".kira", "llvm", "current" });
}

pub fn legacyLlvmVersionedHome(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    llvm_version: []const u8,
    host_key: []const u8,
) ![]const u8 {
    const versioned_dir = try std.fmt.allocPrint(allocator, "llvm-{s}-{s}", .{ llvm_version, host_key });
    return std.fs.path.join(allocator, &.{ repo_root, ".kira", "llvm", versioned_dir });
}

test "maps supported hosts to metadata keys" {
    const windows = std.Target.Query.parse(.{ .arch_os_abi = "x86_64-windows" }) catch unreachable;
    try std.testing.expectEqualStrings("x86_64-windows-msvc", hostLlvmBundleKey(std.zig.resolveTargetQueryOrFatal(windows)));

    const linux = std.Target.Query.parse(.{ .arch_os_abi = "x86_64-linux" }) catch unreachable;
    try std.testing.expectEqualStrings("x86_64-linux-gnu", hostLlvmBundleKey(std.zig.resolveTargetQueryOrFatal(linux)));

    const macos = std.Target.Query.parse(.{ .arch_os_abi = "aarch64-macos" }) catch unreachable;
    try std.testing.expectEqualStrings("aarch64-macos", hostLlvmBundleKey(std.zig.resolveTargetQueryOrFatal(macos)));
}

test "builds managed install path" {
    const llvm_version = try pinnedLlvmVersionForTests(std.testing.allocator);
    defer std.testing.allocator.free(llvm_version);

    const path = try managedLlvmHome(std.testing.allocator, "/repo", llvm_version, "x86_64-linux-gnu");
    defer std.testing.allocator.free(path);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "/repo/.kira/toolchains/llvm/{s}/x86_64-linux-gnu", .{llvm_version});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

fn pinnedLlvmVersionForTests(allocator: std.mem.Allocator) ![]u8 {
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, "llvm-metadata.toml", allocator, .limited(16 * 1024));
    defer allocator.free(contents);

    const llvm_section = std.mem.indexOf(u8, contents, "[llvm]") orelse return error.InvalidLlvmMetadata;
    const version_key = std.mem.indexOfPos(u8, contents, llvm_section, "version") orelse return error.InvalidLlvmMetadata;
    const after_key = contents[version_key + "version".len ..];
    const equals_index = std.mem.indexOfScalar(u8, after_key, '=') orelse return error.InvalidLlvmMetadata;
    const after_equals = std.mem.trimStart(u8, after_key[equals_index + 1 ..], " \t\r\n");
    if (after_equals.len < 2 or after_equals[0] != '"') return error.InvalidLlvmMetadata;
    const closing_quote = std.mem.indexOfScalarPos(u8, after_equals, 1, '"') orelse return error.InvalidLlvmMetadata;
    return allocator.dupe(u8, after_equals[1..closing_quote]);
}
