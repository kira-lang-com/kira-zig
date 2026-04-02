const std = @import("std");
const hybrid = @import("kira_hybrid_definition");

pub fn loadHybridModule(allocator: std.mem.Allocator, path: []const u8) !hybrid.HybridModuleManifest {
    return hybrid.HybridModuleManifest.readFromFile(allocator, path);
}
