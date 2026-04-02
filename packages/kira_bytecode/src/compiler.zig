const std = @import("std");
const ir_pkg = @import("kira_ir");
const bytecode = @import("bytecode.zig");
const instruction = @import("instruction.zig");

pub fn compileProgram(allocator: std.mem.Allocator, program: ir_pkg.Program) !bytecode.Module {
    var functions = std.array_list.Managed(bytecode.Function).init(allocator);
    for (program.functions) |function_decl| {
        var instructions = std.array_list.Managed(instruction.Instruction).init(allocator);
        for (function_decl.instructions) |inst| {
            switch (inst) {
                .const_int => |value| try instructions.append(.{ .const_int = .{ .dst = value.dst, .value = value.value } }),
                .const_string => |value| try instructions.append(.{ .const_string = .{ .dst = value.dst, .value = value.value } }),
                .add => |value| try instructions.append(.{ .add = .{ .dst = value.dst, .lhs = value.lhs, .rhs = value.rhs } }),
                .store_local => |value| try instructions.append(.{ .store_local = .{ .local = value.local, .src = value.src } }),
                .load_local => |value| try instructions.append(.{ .load_local = .{ .dst = value.dst, .local = value.local } }),
                .print => |value| try instructions.append(.{ .print = .{ .src = value.src } }),
                .ret_void => try instructions.append(.{ .ret_void = {} }),
            }
        }
        try functions.append(.{
            .name = function_decl.name,
            .register_count = function_decl.register_count,
            .local_count = function_decl.local_count,
            .instructions = try instructions.toOwnedSlice(),
        });
    }
    return .{
        .functions = try functions.toOwnedSlice(),
        .entry_index = program.entry_index,
    };
}

test "emits bytecode from ir" {
    const program = ir_pkg.Program{
        .functions = &.{.{
            .name = "main",
            .register_count = 2,
            .local_count = 1,
            .instructions = &.{
                .{ .const_int = .{ .dst = 0, .value = 1 } },
                .{ .store_local = .{ .local = 0, .src = 0 } },
                .{ .ret_void = {} },
            },
        }},
        .entry_index = 0,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try compileProgram(arena.allocator(), program);
    try std.testing.expectEqual(@as(usize, 1), module.functions.len);
    try std.testing.expectEqual(@as(usize, 3), module.functions[0].instructions.len);
}
