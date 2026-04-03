const std = @import("std");
const builtin = @import("builtin");
const llvm_metadata = @import("llvm_metadata.zig");

pub fn extractArchive(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    archive_format: llvm_metadata.ArchiveFormat,
    destination_path: []const u8,
) !void {
    var destination_dir = try std.fs.openDirAbsolute(destination_path, .{});
    defer destination_dir.close();

    switch (archive_format) {
        .zip => try extractZip(archive_path, destination_dir),
        .tar_xz => try extractTarXz(allocator, archive_path, destination_path),
    }
}

fn extractZip(archive_path: []const u8, destination_dir: std.fs.Dir) !void {
    if (builtin.os.tag == .windows) {
        return extractZipWindows(std.heap.page_allocator, archive_path, destination_dir);
    }

    const file = try std.fs.openFileAbsolute(archive_path, .{});
    defer file.close();

    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(&file_buffer);
    try std.zip.extract(destination_dir, &reader, .{
        .allow_backslashes = true,
        .verify_checksums = false,
    });
}

fn extractZipWindows(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    destination_dir: std.fs.Dir,
) !void {
    const destination_path = try destination_dir.realpathAlloc(allocator, ".");
    defer allocator.free(destination_path);

    const command = try std.fmt.allocPrint(
        allocator,
        "Expand-Archive -LiteralPath '{s}' -DestinationPath '{s}' -Force",
        .{ archive_path, destination_path },
    );
    defer allocator.free(command);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "powershell", "-NoProfile", "-Command", command },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.ArchiveExtractionFailed;
    }
}

fn extractTarXz(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    destination_path: []const u8,
) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-xJf", archive_path, "-C", destination_path },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.ArchiveExtractionFailed;
    }
}
