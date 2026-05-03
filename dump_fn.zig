const std = @import("std");
const bytecode = @import("packages/kira_bytecode/src/bytecode.zig");

pub fn main() !void {
    const module = try bytecode.Module.readFromFile(std.heap.page_allocator, "../kira-graphics/examples/basic_triangle/generated/triangle.run.kbc");
    for (module.functions) |f| {
        if (f.id == 366) {
            std.debug.print("FUNCTION {d} {s}\n", .{ f.id, f.name });
            for (f.instructions, 0..) |inst, idx| {
                switch (inst) {
                    .call_runtime => |v| std.debug.print("  {d}: call_runtime fn={d} argCount={d}\n", .{ idx, v.function_id, v.args.len }),
                    .load_local => |v| std.debug.print("  {d}: load_local local={d} dst={d}\n", .{ idx, v.local, v.dst }),
                    .const_int => |v| std.debug.print("  {d}: const_int {d}\n", .{ idx, v.value }),
                    else => std.debug.print("  {d}: {s}\n", .{ idx, @tagName(inst) }),
                }
            }
        }
    }
}
