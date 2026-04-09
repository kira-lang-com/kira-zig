const std = @import("std");
const manifest = @import("kira_manifest");
const package_support = @import("package_support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len > 1) return error.InvalidArguments;
    var location = try package_support.loadManifestLocation(allocator, if (args.len == 0) null else args[0]);
    var changed = false;
    var deps = std.array_list.Managed(manifest.DependencySpec).init(allocator);

    for (location.manifest.dependencies) |dep_spec| {
        var updated = dep_spec;
        if (dep_spec.source == .registry) {
            const latest = try package_support.latestRegistryVersion(
                allocator,
                location.manifest.registry_url orelse default_registry_url,
                dep_spec.name,
            );
            if (package_support.versionNewerThan(latest, dep_spec.source.registry.version)) {
                updated.source.registry.version = latest;
                changed = true;
            }
        }
        try deps.append(updated);
    }
    location.manifest.dependencies = try deps.toOwnedSlice();

    if (changed) try package_support.writeManifest(location.manifest_path, location.manifest);
    try package_support.syncAndRender(allocator, location.root_path, stdout, stderr, .{});
}

const default_registry_url = "https://registry.kira.sh";
