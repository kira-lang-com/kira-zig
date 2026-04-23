const std = @import("std");
const LineMap = @import("line_map.zig").LineMap;

pub const SourceFile = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    line_map: LineMap,

    pub fn initOwned(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !SourceFile {
        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .text = try allocator.dupe(u8, text),
            .line_map = try LineMap.init(allocator, text),
        };
    }

    pub fn fromPath(allocator: std.mem.Allocator, path: []const u8) !SourceFile {
        const text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024 * 1024));
        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .text = text,
            .line_map = try LineMap.init(allocator, text),
        };
    }

    pub fn deinit(self: *SourceFile) void {
        self.line_map.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.free(self.text);
    }
};
