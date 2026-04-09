const std = @import("std");

pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    const hex = try allocator.alloc(u8, digest.len * 2);
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        hex[index * 2] = alphabet[byte >> 4];
        hex[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return hex;
}

pub fn extractTarSecure(allocator: std.mem.Allocator, archive_path: []const u8, destination_path: []const u8) !void {
    try std.fs.cwd().makePath(destination_path);
    try validateTarEntries(archive_path);
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-xf", archive_path, "-C", destination_path },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return error.ArchiveExtractionFailed;
}

fn isSafeArchivePath(path: []const u8) bool {
    if (path.len == 0) return false;
    const normalized = std.mem.trimRight(u8, path, "/");
    if (normalized.len == 0) return false;
    if (normalized[0] == '/' or normalized[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, ':')) |_| return false;
    if (std.mem.indexOfScalar(u8, path, '\\')) |_| return false;

    var parts = std.mem.splitScalar(u8, normalized, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn validateTarEntries(archive_path: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "tar", "-tvf", archive_path },
        .max_output_bytes = 256 * 1024,
    });
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return error.ArchiveExtractionFailed;

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0) continue;
        const entry_kind = line[0];
        if (entry_kind == 'l') return error.ArchiveSymbolicLinkUnsupported;

        var parts = std.mem.tokenizeAny(u8, line, " \t");
        var last: ?[]const u8 = null;
        while (parts.next()) |part| last = part;
        const path = last orelse return error.ArchiveExtractionFailed;
        if (!isSafeArchivePath(path)) return error.ArchivePathTraversal;
    }
}

test "rejects archive traversal paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tar_path = try tmp.dir.realpathAlloc(arena.allocator(), "bad.tar");
    defer arena.allocator().free(tar_path);

    const tar_file = try std.fs.createFileAbsolute(tar_path, .{ .truncate = true });
    defer tar_file.close();
    var write_buf: [1024]u8 = undefined;
    var file_writer = tar_file.writer(&write_buf);
    var tar_writer = std.tar.Writer{ .underlying_writer = &file_writer.interface };
    try tar_writer.writeFileBytes("../evil.txt", "bad", .{});
    try file_writer.interface.flush();

    const dest = try tmp.dir.realpathAlloc(arena.allocator(), "dest");
    defer arena.allocator().free(dest);
    try std.testing.expectError(error.ArchivePathTraversal, extractTarSecure(arena.allocator(), tar_path, dest));
}
