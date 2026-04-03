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
    const path = try managedLlvmHome(std.testing.allocator, "/repo", "22.1.2", "x86_64-linux-gnu");
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/repo/.kira/toolchains/llvm/22.1.2/x86_64-linux-gnu", path);
}
