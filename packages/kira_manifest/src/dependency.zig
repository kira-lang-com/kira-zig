const std = @import("std");

pub const DependencySpec = struct {
    name: []const u8,
    source: Source,

    pub const Source = union(enum) {
        registry: RegistrySource,
        path: PathSource,
        git: GitSource,
    };

    pub const RegistrySource = struct {
        version: []const u8,
    };

    pub const PathSource = struct {
        path: []const u8,
    };

    pub const GitSource = struct {
        url: []const u8,
        rev: ?[]const u8 = null,
        tag: ?[]const u8 = null,
    };

    pub fn clone(self: DependencySpec, allocator: std.mem.Allocator) !DependencySpec {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .source = switch (self.source) {
                .registry => |registry| .{ .registry = .{
                    .version = try allocator.dupe(u8, registry.version),
                } },
                .path => |path| .{ .path = .{
                    .path = try allocator.dupe(u8, path.path),
                } },
                .git => |git| .{ .git = .{
                    .url = try allocator.dupe(u8, git.url),
                    .rev = if (git.rev) |rev| try allocator.dupe(u8, rev) else null,
                    .tag = if (git.tag) |tag| try allocator.dupe(u8, tag) else null,
                } },
            },
        };
    }
};
