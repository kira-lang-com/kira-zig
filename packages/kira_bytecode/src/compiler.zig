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
    var types = std.array_list.Managed(bytecode.TypeDecl).init(allocator);
    for (program.types) |type_decl| {
        var fields = std.array_list.Managed(bytecode.Field).init(allocator);
        for (type_decl.fields) |field_decl| {
            try fields.append(.{
                .name = field_decl.name,
                .ty = lowerTypeRef(field_decl.ty),
            });
        }
        try types.append(.{
            .name = type_decl.name,
            .fields = try fields.toOwnedSlice(),
        });
    }

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
                .const_float => |value| try instructions.append(.{ .const_float = .{ .dst = value.dst, .value = value.value } }),
                .const_string => |value| try instructions.append(.{ .const_string = .{ .dst = value.dst, .value = value.value } }),
                .const_bool => |value| try instructions.append(.{ .const_bool = .{ .dst = value.dst, .value = value.value } }),
                .const_null_ptr => |value| try instructions.append(.{ .const_null_ptr = .{ .dst = value.dst } }),
                .alloc_struct => |value| try instructions.append(.{ .alloc_struct = .{ .dst = value.dst, .type_name = value.type_name } }),
                .alloc_array => |value| try instructions.append(.{ .alloc_array = .{ .dst = value.dst, .len = value.len } }),
                .const_function => |value| try instructions.append(.{ .const_function = .{
                    .dst = value.dst,
                    .function_id = value.function_id,
                    .representation = @enumFromInt(@intFromEnum(value.representation)),
                } }),
                .add => |value| try instructions.append(.{ .add = .{ .dst = value.dst, .lhs = value.lhs, .rhs = value.rhs } }),
                .subtract => |value| try instructions.append(.{ .subtract = .{ .dst = value.dst, .lhs = value.lhs, .rhs = value.rhs } }),
                .multiply => |value| try instructions.append(.{ .multiply = .{ .dst = value.dst, .lhs = value.lhs, .rhs = value.rhs } }),
                .divide => |value| try instructions.append(.{ .divide = .{ .dst = value.dst, .lhs = value.lhs, .rhs = value.rhs } }),
                .modulo => |value| try instructions.append(.{ .modulo = .{ .dst = value.dst, .lhs = value.lhs, .rhs = value.rhs } }),
                .compare => |value| try instructions.append(.{ .compare = .{
                    .dst = value.dst,
                    .lhs = value.lhs,
                    .rhs = value.rhs,
                    .op = @enumFromInt(@intFromEnum(value.op)),
                } }),
                .unary => |value| try instructions.append(.{ .unary = .{
                    .dst = value.dst,
                    .src = value.src,
                    .op = @enumFromInt(@intFromEnum(value.op)),
                } }),
                .store_local => |value| try instructions.append(.{ .store_local = .{ .local = value.local, .src = value.src } }),
                .load_local => |value| try instructions.append(.{ .load_local = .{ .dst = value.dst, .local = value.local } }),
                .subobject_ptr => |value| try instructions.append(.{ .subobject_ptr = .{
                    .dst = value.dst,
                    .base = value.base,
                    .offset = value.offset,
                } }),
                .field_ptr => |value| try instructions.append(.{ .field_ptr = .{
                    .dst = value.dst,
                    .base = value.base,
                    .base_type_name = value.base_type_name,
                    .field_index = value.field_index,
                    .field_ty = lowerTypeRef(value.field_ty),
                } }),
                .array_len => |value| try instructions.append(.{ .array_len = .{ .dst = value.dst, .array = value.array } }),
                .array_get => |value| try instructions.append(.{ .array_get = .{
                    .dst = value.dst,
                    .array = value.array,
                    .index = value.index,
                    .ty = lowerTypeRef(value.ty),
                } }),
                .array_set => |value| try instructions.append(.{ .array_set = .{
                    .array = value.array,
                    .index = value.index,
                    .src = value.src,
                } }),
                .load_indirect => |value| try instructions.append(.{ .load_indirect = .{
                    .dst = value.dst,
                    .ptr = value.ptr,
                    .ty = lowerTypeRef(value.ty),
                } }),
                .store_indirect => |value| try instructions.append(.{ .store_indirect = .{
                    .ptr = value.ptr,
                    .src = value.src,
                    .ty = lowerTypeRef(value.ty),
                } }),
                .copy_indirect => |value| try instructions.append(.{ .copy_indirect = .{
                    .dst_ptr = value.dst_ptr,
                    .src_ptr = value.src_ptr,
                    .type_name = value.type_name,
                } }),
                .branch => |value| try instructions.append(.{ .branch = .{
                    .condition = value.condition,
                    .true_label = value.true_label,
                    .false_label = value.false_label,
                } }),
                .jump => |value| try instructions.append(.{ .jump = .{ .label = value.label } }),
                .label => |value| try instructions.append(.{ .label = .{ .id = value.id } }),
                .print => |value| try instructions.append(.{ .print = .{ .src = value.src, .ty = lowerTypeRef(value.ty) } }),
                .call => |value| {
                    const callee_execution = functionExecutionById(program, value.callee) orelse return error.UnknownFunction;
                    const resolved_callee_execution = resolveExecution(callee_execution, mode);
                    try instructions.append(switch (resolved_callee_execution) {
                        .runtime => .{ .call_runtime = .{ .function_id = value.callee, .args = value.args, .dst = value.dst } },
                        .native => .{ .call_native = .{ .function_id = value.callee, .args = value.args, .dst = value.dst } },
                        .inherited => unreachable,
                    });
                },
                .call_value => |value| try instructions.append(.{ .call_value = .{
                    .callee = value.callee,
                    .args = value.args,
                    .dst = value.dst,
                } }),
                .ret => |value| try instructions.append(.{ .ret = .{ .src = value.src } }),
            }
        }

        try functions.append(.{
            .id = function_decl.id,
            .name = function_decl.name,
            .param_count = @as(u32, @intCast(function_decl.param_types.len)),
            .register_count = function_decl.register_count,
            .local_count = function_decl.local_count,
            .local_types = try lowerLocalTypes(allocator, function_decl.local_types),
            .instructions = try instructions.toOwnedSlice(),
        });

        if (index == program.entry_index and resolved_execution == .runtime) {
            entry_function_id = function_decl.id;
        }
    }

    return .{
        .types = try types.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
        .entry_function_id = entry_function_id,
    };
}

fn lowerLocalTypes(allocator: std.mem.Allocator, local_types: []const ir_pkg.ValueType) ![]instruction.TypeRef {
    const lowered = try allocator.alloc(instruction.TypeRef, local_types.len);
    for (local_types, 0..) |local_ty, index| lowered[index] = lowerTypeRef(local_ty);
    return lowered;
}

fn lowerTypeRef(value_type: ir_pkg.ValueType) instruction.TypeRef {
    return .{
        .kind = @enumFromInt(@intFromEnum(value_type.kind)),
        .name = value_type.name,
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
        .types = &.{},
        .functions = &.{
            .{
                .id = 0,
                .name = "main",
                .execution = .runtime,
                .is_extern = false,
                .foreign = null,
                .param_types = &.{},
                .return_type = .{ .kind = .void },
                .register_count = 0,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{
                    .{ .call = .{ .callee = 1, .args = &.{}, .dst = null } },
                    .{ .call = .{ .callee = 2, .args = &.{}, .dst = null } },
                    .{ .ret = .{ .src = null } },
                },
            },
            .{
                .id = 1,
                .name = "runtime_helper",
                .execution = .runtime,
                .is_extern = false,
                .foreign = null,
                .param_types = &.{},
                .return_type = .{ .kind = .void },
                .register_count = 0,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{.{ .ret = .{ .src = null } }},
            },
            .{
                .id = 2,
                .name = "native_helper",
                .execution = .native,
                .is_extern = false,
                .foreign = null,
                .param_types = &.{},
                .return_type = .{ .kind = .void },
                .register_count = 0,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{.{ .ret = .{ .src = null } }},
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

test "preserves function constants in bytecode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const program = ir_pkg.Program{
        .types = &.{},
        .functions = &.{
            .{
                .id = 0,
                .name = "main",
                .execution = .runtime,
                .param_types = &.{},
                .return_type = .{ .kind = .void },
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{
                    .{ .const_function = .{ .dst = 0, .function_id = 1 } },
                    .{ .ret = .{ .src = null } },
                },
            },
            .{
                .id = 1,
                .name = "callback",
                .execution = .runtime,
                .param_types = &.{},
                .return_type = .{ .kind = .void },
                .register_count = 0,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{.{ .ret = .{ .src = null } }},
            },
        },
        .entry_index = 0,
    };

    const module = try compileProgram(arena.allocator(), program, .vm);
    try std.testing.expect(module.functions[0].instructions[0] == .const_function);
    try std.testing.expectEqual(@as(u32, 1), module.functions[0].instructions[0].const_function.function_id);
}
