const std = @import("std");
const ResolvedType = @import("types.zig").ResolvedType;

pub const LocalBinding = struct {
    id: u32,
    ty: ResolvedType,
};

pub const Scope = struct {
    entries: std.StringHashMapUnmanaged(LocalBinding) = .{},

    pub fn put(self: *Scope, allocator: std.mem.Allocator, name: []const u8, binding: LocalBinding) !void {
        try self.entries.put(allocator, name, binding);
    }

    pub fn get(self: Scope, name: []const u8) ?LocalBinding {
        return self.entries.get(name);
    }

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }
};
