const std = @import("std");
const builtin = @import("builtin");
const llvm_metadata = @import("llvm_metadata.zig");

pub fn extractArchive(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    archive_format: llvm_metadata.ArchiveFormat,
    destination_path: []const u8,
) !void {
    var destination_dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, destination_path, .{});
    defer destination_dir.close(std.Options.debug_io);

    switch (archive_format) {
        .zip => try extractZip(archive_path, destination_dir),
        .tar_xz => try extractTarXz(allocator, archive_path, destination_path),
    }
}

fn extractZip(archive_path: []const u8, destination_dir: std.Io.Dir) !void {
    if (builtin.os.tag == .windows) {
        return extractZipWindows(std.heap.page_allocator, archive_path, destination_dir);
    }

    const file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, archive_path, .{});
    defer file.close(std.Options.debug_io);

    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(std.Options.debug_io, &file_buffer);
    try std.zip.extract(destination_dir, &reader, .{
        .allow_backslashes = true,
        .verify_checksums = false,
    });
}

fn extractZipWindows(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    destination_dir: std.Io.Dir,
) !void {
    const destination_path = try destination_dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(destination_path);

    const command = try std.fmt.allocPrint(
        allocator,
        "Expand-Archive -LiteralPath '{s}' -DestinationPath '{s}' -Force",
        .{ archive_path, destination_path },
    );
    defer allocator.free(command);

    const result = try std.process.run(allocator, std.Options.debug_io, .{
        .argv = &.{ "powershell", "-NoProfile", "-Command", command },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return error.ArchiveExtractionFailed;
    }
}

fn extractTarXz(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    destination_path: []const u8,
) !void {
    const result = try std.process.run(allocator, std.Options.debug_io, .{
        .argv = &.{ "tar", "-xJf", archive_path, "-C", destination_path },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return error.ArchiveExtractionFailed;
    }
}
