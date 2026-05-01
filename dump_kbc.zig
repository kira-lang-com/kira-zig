const std = @import("std");
const bytecode = @import("packages/kira_bytecode/src/bytecode.zig");

fn dump(path: []const u8) !void {
    const module = try bytecode.Module.readFromFile(std.heap.page_allocator, path);
    std.debug.print("PATH {s}\n", .{path});
    for (module.functions) |function_decl| {
        if (function_decl.id >= 350 and function_decl.id <= 360) {
            std.debug.print("  id={d} name={s} params={d}\n", .{ function_decl.id, function_decl.name, function_decl.param_count });
        }
    }
}

pub fn main() !void {
    try dump("../kira-graphics/examples/basic_triangle/generated/triangle.kbc");
    try dump("../kira-graphics/examples/basic_triangle/generated/triangle.run.kbc");
    try dump("../kira-graphics/examples/basic_triangle/.kira-build/cache/hybrid/28c871458c2714071c663283ff617ab7801782b593df337b6469b727774e6a76/main.kbc");
}
