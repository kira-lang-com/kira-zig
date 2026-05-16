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

    try extractZipWindowsWithTar(allocator, archive_path, destination_path);
    if (!archiveLooksExtracted(destination_dir)) return error.ArchiveExtractionFailed;
}

fn extractZipWindowsWithTar(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    destination_path: []const u8,
) !void {
    const tar_candidates = [_][]const u8{
        "C:\\Windows\\System32\\tar.exe",
        "tar.exe",
        "tar",
    };
    var last_err: anyerror = error.FileNotFound;
    for (tar_candidates) |tar_path| {
        runTarExtract(allocator, tar_path, archive_path, destination_path) catch |err| {
            last_err = err;
            continue;
        };
        return;
    }
    return last_err;
}

fn runTarExtract(
    allocator: std.mem.Allocator,
    tar_path: []const u8,
    archive_path: []const u8,
    destination_path: []const u8,
) !void {
    const result = try std.process.run(allocator, std.Options.debug_io, .{
        .argv = &.{ tar_path, "-xf", archive_path, "-C", destination_path },
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

fn archiveLooksExtracted(destination_dir: std.Io.Dir) bool {
    var bin_dir = destination_dir.openDir(std.Options.debug_io, "bin", .{}) catch return false;
    bin_dir.close(std.Options.debug_io);
    return true;
}

fn extractTarXz(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    destination_path: []const u8,
) !void {
    const file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, archive_path, .{});
    defer file.close(std.Options.debug_io);

    var file_buffer: [16 * 1024]u8 = undefined;
    var file_reader = file.reader(std.Options.debug_io, &file_buffer);

    const decompress_buffer = try allocator.alloc(u8, 32 * 1024);
    var xz = try std.compress.xz.Decompress.init(&file_reader.interface, allocator, decompress_buffer);
    defer xz.deinit();

    var destination_dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, destination_path, .{});
    defer destination_dir.close(std.Options.debug_io);

    try std.tar.extract(std.Options.debug_io, destination_dir, &xz.reader, .{});
}
