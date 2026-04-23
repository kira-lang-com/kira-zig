const std = @import("std");
const archive = @import("archive.zig");
const paths = @import("paths.zig");
const registry = @import("registry.zig");

pub const ResolvedRegistryVersion = struct {
    version: registry.PackageMetadata.Version,
    archive_url: []const u8,
};

pub fn fetchPackageVersion(
    allocator: std.mem.Allocator,
    registry_url: []const u8,
    package_name: []const u8,
    version_text: []const u8,
) !ResolvedRegistryVersion {
    const config = try fetchIndexConfig(allocator, registry_url);
    const metadata = try fetchPackageMetadata(allocator, registry_url, package_name);
    for (metadata.versions) |version| {
        if (!std.mem.eql(u8, version.version, version_text)) continue;
        return .{
            .version = version,
            .archive_url = try absolutizeUrl(allocator, config.archives_base_url, version.archive),
        };
    }
    return error.RegistryVersionNotFound;
}

pub fn ensureRegistrySource(
    allocator: std.mem.Allocator,
    archive_url: []const u8,
    checksum: []const u8,
    offline: bool,
) ![]u8 {
    const registry_root = try paths.registryRoot(allocator);
    defer allocator.free(registry_root);
    try paths.ensurePath(registry_root);

    const archives_root = try std.fs.path.join(allocator, &.{ registry_root, "archives" });
    defer allocator.free(archives_root);
    try paths.ensurePath(archives_root);
    const archive_name = try std.fmt.allocPrint(allocator, "{s}.tar", .{checksum});
    defer allocator.free(archive_name);
    const archive_path = try std.fs.path.join(allocator, &.{ archives_root, archive_name });
    defer allocator.free(archive_path);

    const sources_root = try std.fs.path.join(allocator, &.{ registry_root, "sources" });
    defer allocator.free(sources_root);
    try paths.ensurePath(sources_root);
    const source_root = try std.fs.path.join(allocator, &.{ sources_root, checksum });
    if (dirExists(source_root)) return source_root;
    errdefer allocator.free(source_root);

    if (!fileExists(archive_path)) {
        if (offline) return error.RegistryArchiveNotCached;
        try downloadToFile(allocator, archive_url, archive_path);
    }

    const archive_bytes = try readFileAbsoluteAlloc(allocator, archive_path, 64 * 1024 * 1024);
    defer allocator.free(archive_bytes);
    const actual_checksum = try archive.sha256Hex(allocator, archive_bytes);
    defer allocator.free(actual_checksum);
    if (!std.mem.eql(u8, actual_checksum, checksum)) return error.RegistryChecksumMismatch;

    try archive.extractTarSecure(allocator, archive_path, source_root);
    return source_root;
}

fn fetchIndexConfig(allocator: std.mem.Allocator, registry_url: []const u8) !registry.IndexConfig {
    const config_url = try std.fmt.allocPrint(allocator, "{s}/index/config.json", .{std.mem.trimEnd(u8, registry_url, "/")});
    defer allocator.free(config_url);
    const bytes = try fetchBytes(allocator, config_url);

    return std.json.parseFromSliceLeaky(registry.IndexConfig, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
}

pub fn fetchPackageMetadata(allocator: std.mem.Allocator, registry_url: []const u8, package_name: []const u8) !registry.PackageMetadata {
    const relative = try registry.sparseIndexPath(allocator, package_name);
    defer allocator.free(relative);
    const normalized = try normalizeToUrlPath(allocator, relative);
    defer allocator.free(normalized);
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/index/{s}",
        .{ std.mem.trimEnd(u8, registry_url, "/"), normalized },
    );
    defer allocator.free(url);
    const bytes = try fetchBytes(allocator, url);

    return std.json.parseFromSliceLeaky(registry.PackageMetadata, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
}

fn fetchBytes(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var client: std.http.Client = .{ .allocator = allocator, .io = std.Options.debug_io };
    defer client.deinit();
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &output.writer,
    });
    if (response.status != .ok) return error.RegistryFetchFailed;
    return try output.toOwnedSlice();
}

fn downloadToFile(allocator: std.mem.Allocator, url: []const u8, destination_path: []const u8) !void {
    if (std.fs.path.dirname(destination_path)) |parent| try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, parent);
    const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, destination_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);

    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(std.Options.debug_io, &buffer);
    var client: std.http.Client = .{ .allocator = allocator, .io = std.Options.debug_io };
    defer client.deinit();
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    });
    try writer.interface.flush();
    if (response.status != .ok) return error.RegistryFetchFailed;
}

fn absolutizeUrl(allocator: std.mem.Allocator, base: []const u8, value: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, value, "://")) |_| return allocator.dupe(u8, value);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), std.mem.trimStart(u8, value, "/") });
}

fn normalizeToUrlPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path);
    _ = std.mem.replaceScalar(u8, normalized, '\\', '/');
    return normalized;
}

fn readFileAbsoluteAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{});
    defer file.close(std.Options.debug_io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(std.Options.debug_io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

fn fileExists(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}

fn dirExists(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}
