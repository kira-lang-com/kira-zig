const std = @import("std");
const hybrid = @import("packages/kira_hybrid_definition/src/module_manifest.zig");

pub fn main() !void {
    const manifest = try hybrid.HybridModuleManifest.readFromFile(std.heap.page_allocator, "../kira-graphics/examples/basic_triangle/generated/triangle.run.khm");
    std.debug.print("entry={d} exec={s} bytecode={s} native={s}\n", .{ manifest.entry_function_id, @tagName(manifest.entry_execution), manifest.bytecode_path, manifest.native_library_path });
}
