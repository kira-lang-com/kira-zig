const std = @import("std");
const manifest = @import("kira_manifest");
const Project = @import("project.zig").Project;

pub fn loadProjectFromFile(allocator: std.mem.Allocator, path: []const u8) !Project {
    const text = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    return .{
        .manifest = try manifest.parseProjectManifest(allocator, text),
    };
}
