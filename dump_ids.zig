const std = @import("std");
const bytecode = @import("packages/kira_bytecode/src/bytecode.zig");

pub fn main() !void {
    const module = try bytecode.Module.readFromFile(std.heap.page_allocator, "../kira-graphics/examples/basic_triangle/generated/triangle.run.kbc");
    for (module.functions) |f| {
        if (f.id >= 360 and f.id <= 390) {
            std.debug.print("id={d} name={s} params={d}\n", .{ f.id, f.name, f.param_count });
            for (f.instructions, 0..) |inst, idx| {
                if (idx >= 40) break;
                std.debug.print("  {d}: {s}\n", .{ idx, @tagName(inst) });
            }
        }
    }
}
