const std = @import("std");
const ir_pkg = @import("kira_ir");
const runtime_abi = @import("kira_runtime_abi");
const bytecode = @import("bytecode.zig");
const instruction = @import("instruction.zig");

pub const CompileMode = enum {
    vm,
    hybrid_runtime,
};

pub fn compileProgram(allocator: std.mem.Allocator, program: ir_pkg.Program, mode: CompileMode) !bytecode.Module {
    var functions = std.array_list.Managed(bytecode.Function).init(allocator);
    var entry_function_id: ?u32 = null;

    for (program.functions, 0..) |function_decl, index| {
        const resolved_execution = resolveExecution(function_decl.execution, mode);
        if (mode == .vm and resolved_execution == .native) return error.NativeFunctionInVmBuild;
        if (resolved_execution == .native and mode == .hybrid_runtime) continue;

        var instructions = std.array_list.Managed(instruction.Instruction).init(allocator);
        for (function_decl.instructions) |inst| {
            switch (inst) {
                .const_int => |value| try instructions.append(.{ .const_int = .{ .dst = value.dst, .value = value.value } }),
                .const_string => |value| try instructions.append(.{ .const_string = .{ .dst = value.dst, .value = value.value } }),
                .add => |value| try instructions.append(.{ .add = .{ .dst = value.dst, .lhs = value.lhs, .rhs = value.rhs } }),
                .store_local => |value| try instructions.append(.{ .store_local = .{ .local = value.local, .src = value.src } }),
                .load_local => |value| try instructions.append(.{ .load_local = .{ .dst = value.dst, .local = value.local } }),
                .print => |value| try instructions.append(.{ .print = .{ .src = value.src } }),
                .call => |value| {
                    const callee_execution = functionExecutionById(program, value.callee) orelse return error.UnknownFunction;
                    const resolved_callee_execution = resolveExecution(callee_execution, mode);
                    try instructions.append(switch (resolved_callee_execution) {
                        .runtime => .{ .call_runtime = .{ .function_id = value.callee } },
                        .native => .{ .call_native = .{ .function_id = value.callee } },
                        .inherited => unreachable,
                    });
                },
                .ret_void => try instructions.append(.{ .ret_void = {} }),
            }
        }

        try functions.append(.{
            .id = function_decl.id,
            .name = function_decl.name,
            .register_count = function_decl.register_count,
            .local_count = function_decl.local_count,
            .instructions = try instructions.toOwnedSlice(),
        });

        if (index == program.entry_index and resolved_execution == .runtime) {
            entry_function_id = function_decl.id;
        }
    }

    return .{
        .functions = try functions.toOwnedSlice(),
        .entry_function_id = entry_function_id,
    };
}

fn functionExecutionById(program: ir_pkg.Program, function_id: u32) ?runtime_abi.FunctionExecution {
    for (program.functions) |function_decl| {
        if (function_decl.id == function_id) return function_decl.execution;
    }
    return null;
}

fn resolveExecution(execution: runtime_abi.FunctionExecution, mode: CompileMode) runtime_abi.FunctionExecution {
    return switch (execution) {
        .inherited => switch (mode) {
            .vm => .runtime,
            .hybrid_runtime => .runtime,
        },
        else => execution,
    };
}

test "emits hybrid bytecode for runtime and native calls" {
    const program = ir_pkg.Program{
        .functions = &.{
            .{
                .id = 0,
                .name = "main",
                .execution = .runtime,
                .register_count = 0,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{
                    .{ .call = .{ .callee = 1 } },
                    .{ .call = .{ .callee = 2 } },
                    .{ .ret_void = {} },
                },
            },
            .{
                .id = 1,
                .name = "runtime_helper",
                .execution = .runtime,
                .register_count = 0,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{.{ .ret_void = {} }},
            },
            .{
                .id = 2,
                .name = "native_helper",
                .execution = .native,
                .register_count = 0,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{.{ .ret_void = {} }},
            },
        },
        .entry_index = 0,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try compileProgram(arena.allocator(), program, .hybrid_runtime);
    try std.testing.expectEqual(@as(usize, 2), module.functions.len);
    try std.testing.expectEqual(@as(?u32, 0), module.entry_function_id);
    try std.testing.expect(module.functions[0].instructions[0] == .call_runtime);
    try std.testing.expect(module.functions[0].instructions[1] == .call_native);
}
