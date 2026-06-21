const builtin = @import("builtin");
const std = @import("std");
const llvm_metadata = @import("llvm_metadata.zig");
extern "c" fn system(command: [*:0]const u8) c_int;

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
        .tar_gz => try extractTarGz(allocator, archive_path, destination_path),
        .tar_xz => try extractTarXz(allocator, archive_path, destination_path),
    }
}

fn extractZip(archive_path: []const u8, destination_dir: std.Io.Dir) !void {
    const file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, archive_path, .{});
    defer file.close(std.Options.debug_io);

    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(std.Options.debug_io, &file_buffer);
    try std.zip.extract(destination_dir, &reader, .{
        .allow_backslashes = true,
        .verify_checksums = false,
    });
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

fn extractTarGz(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    destination_path: []const u8,
) !void {
    const quoted_archive = try shQuote(allocator, archive_path);
    defer allocator.free(quoted_archive);
    const quoted_destination = try shQuote(allocator, destination_path);
    defer allocator.free(quoted_destination);
    const command = try std.fmt.allocPrint(
        allocator,
        "tar -xzf {s} -C {s}",
        .{ quoted_archive, quoted_destination },
    );
    defer allocator.free(command);
    try runSystemCommand(allocator, command);
}

fn runSystemCommand(allocator: std.mem.Allocator, command: []const u8) !void {
    if (!builtin.link_libc) return error.SystemCommandUnavailable;

    const command_z = try allocator.dupeZ(u8, command);
    defer allocator.free(command_z);
    if (system(command_z.ptr) != 0) return error.ExternalCommandFailed;
}

fn shQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var quoted = std.array_list.Managed(u8).init(allocator);
    defer quoted.deinit();

    try quoted.append('\'');
    for (value) |byte| {
        if (byte == '\'') {
            try quoted.appendSlice("'\\''");
        } else {
            try quoted.append(byte);
        }
    }
    try quoted.append('\'');
    return quoted.toOwnedSlice();
}
