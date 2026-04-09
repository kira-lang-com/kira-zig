const std = @import("std");
const manifest = @import("kira_manifest");
const package_support = @import("package_support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);
    var location = try package_support.loadManifestLocation(allocator, null);

    const dep_spec: manifest.DependencySpec = if (parsed.git_url) |git_url| .{
        .name = try allocator.dupe(u8, parsed.package_name),
        .source = .{ .git = .{
            .url = try allocator.dupe(u8, git_url),
            .rev = if (parsed.rev) |rev| try allocator.dupe(u8, rev) else null,
            .tag = if (parsed.tag) |tag| try allocator.dupe(u8, tag) else null,
        } },
    } else .{
        .name = try allocator.dupe(u8, parsed.package_name),
        .source = .{ .registry = .{
            .version = try package_support.latestRegistryVersion(
                allocator,
                location.manifest.registry_url orelse default_registry_url,
                parsed.package_name,
            ),
        } },
    };

    try package_support.upsertDependency(allocator, &location.manifest, dep_spec);
    try package_support.writeManifest(location.manifest_path, location.manifest);
    try package_support.syncAndRender(allocator, location.root_path, stdout, stderr, .{});
}

const ParsedArgs = struct {
    package_name: []const u8,
    git_url: ?[]const u8 = null,
    rev: ?[]const u8 = null,
    tag: ?[]const u8 = null,
};

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var git_url: ?[]const u8 = null;
    var rev: ?[]const u8 = null;
    var tag: ?[]const u8 = null;
    var package_name: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--git")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            git_url = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--rev")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            rev = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--tag")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            tag = args[index];
            continue;
        }
        if (package_name != null) return error.InvalidArguments;
        package_name = arg;
    }

    if (package_name == null) return error.InvalidArguments;
    if (git_url != null and rev == null and tag == null) return error.InvalidArguments;
    return .{
        .package_name = package_name.?,
        .git_url = git_url,
        .rev = rev,
        .tag = tag,
    };
}

const default_registry_url = "https://registry.kira.sh";
