const std = @import("std");
const fetch_llvm = @import("fetch_llvm.zig");
const kira_toolchain = @import("kira_toolchain");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(std.Options.debug_io, &stdout_buffer);
    defer stdout.interface.flush() catch {};
    var stderr = std.Io.File.stderr().writer(std.Options.debug_io, &stderr_buffer);
    defer stderr.interface.flush() catch {};

    const build_options = @import("fetch_llvm_build_options");
    _ = kira_toolchain;
    fetch_llvm.run(arena.allocator(), &stdout.interface, &stderr.interface, build_options.repo_root) catch |err| {
        if (!(err == error.InvalidLlvmMetadata or
            err == error.UnsupportedLlvmHost or
            err == error.LlvmTargetNotPublished or
            err == error.GitHubReleaseTagNotFound or
            err == error.GitHubReleaseAssetNotFound or
            err == error.GitHubReleaseLookupFailed or
            err == error.GitHubReleaseTagMismatch or
            err == error.GitHubAssetDownloadFailed or
            err == error.InvalidInstalledToolchain))
        {
            try stderr.interface.print("fetch-llvm failed: {s}\n", .{@errorName(err)});
        }
        return error.FetchLlvmFailed;
    };
}
