//! Callback lowering for HIR -> IR: counting callback expressions ahead of
//! time (so generated function ids can be planned deterministically), remapping
//! callback-local ids into the generated function's local space, and lowering a
//! `callback` expression into a generated IR function plus its capture wiring.
const std = @import("std");
const ir = @import("ir.zig");
const InstructionBuf = @import("instruction_buf.zig").InstructionBuf;
const model = @import("kira_semantics_model");
const runtime_abi = @import("kira_runtime_abi");
const parent = @import("lower_from_hir.zig");
const function_impl = @import("lower_from_hir_functions.zig");
const type_impl = @import("lower_from_hir_types.zig");
const boxed_impl = @import("lower_from_hir_boxed.zig");

const Lowerer = parent.Lowerer;
const lowerResolvedType = type_impl.lowerResolvedType;
const collectBoxedLocals = boxed_impl.collectBoxedLocals;

pub fn lowerCallbackExpr(lowerer: *Lowerer, node: model.hir.CallbackExpr) !u32 {
    const function_id = lowerer.state.next_generated_function_id;
    lowerer.state.next_generated_function_id += 1;
    const function_name = try std.fmt.allocPrint(lowerer.allocator, "{s}$callback_{d}", .{ lowerer.function_name, function_id });
    try lowerer.state.generated_functions.append(try lowerGeneratedCallbackFunction(
        lowerer.allocator,
        lowerer.program,
        lowerer.state,
        function_id,
        function_name,
        lowerer.execution,
        node,
    ));
    return function_id;
}

fn lowerGeneratedCallbackFunction(
    allocator: std.mem.Allocator,
    program: model.Program,
    state: *function_impl.FunctionLoweringState,
    function_id: u32,
    function_name: []const u8,
    execution: runtime_abi.FunctionExecution,
    callback: model.hir.CallbackExpr,
) !ir.Function {
    const local_remap = try buildCallbackLocalRemap(allocator, callback);
    defer allocator.free(local_remap);
    const callback_local_count = callbackLocalCount(local_remap);
    const original_boxed_locals = try collectBoxedLocals(allocator, callback.locals.len, callback.body);
    defer allocator.free(original_boxed_locals);
    const boxed_locals = try remapBoxedLocals(allocator, local_remap, callback_local_count, original_boxed_locals);
    for (callback.captures) |capture| {
        const mapped = remapLocalId(local_remap, capture.local_id);
        if (capture.by_ref and mapped < boxed_locals.len) boxed_locals[mapped] = true;
    }
    var lowerer = Lowerer{
        .allocator = allocator,
        .program = program,
        .state = state,
        .execution = execution,
        .function_name = function_name,
        .next_register = 0,
        .next_label = 0,
        .next_local = callback_local_count,
        .hidden_local_types = std.array_list.Managed(ir.ValueType).init(allocator),
        .loop_stack = std.array_list.Managed(Lowerer.LoopLabels).init(allocator),
        .boxed_locals = boxed_locals,
        .local_remap = local_remap,
    };
    defer allocator.free(boxed_locals);
    defer lowerer.hidden_local_types.deinit();
    defer lowerer.loop_stack.deinit();
    errdefer |err| parent.recordUnsupported(state.unsupported, lowerer.current_span, lowerer.current_construct, err);

    var instructions = InstructionBuf.init(allocator, &InstructionBuf.null_span);
    for (callback.captures, 0..) |capture, index| {
        const param_slot: u32 = @intCast(callback.params.len + index);
        const capture_local = lowerer.mapLocal(capture.local_id);
        if (param_slot == capture_local) continue;
        const reg = lowerer.freshRegister();
        try instructions.append(.{ .load_local = .{ .dst = reg, .local = param_slot } });
        try instructions.append(.{ .store_local = .{ .src = reg, .local = capture_local } });
    }
    const terminated = try lowerer.lowerStatements(&instructions, callback.body);
    if (!terminated and (instructions.list.items.len == 0 or instructions.list.items[instructions.list.items.len - 1] != .ret)) {
        try instructions.append(.{ .ret = .{ .src = null } });
    }

    return .{
        .id = function_id,
        .name = function_name,
        .execution = execution,
        .is_extern = false,
        .foreign = null,
        .param_types = try lowerCallbackParamTypes(allocator, program, callback),
        .param_ownership = try lowerCallbackParamOwnership(allocator, callback),
        .return_type = try lowerResolvedType(program, callback.return_type),
        .return_ownership = .owned,
        .register_count = lowerer.next_register,
        .local_count = lowerer.next_local,
        .local_types = try lowerCallbackLocalTypes(allocator, program, callback, local_remap, callback_local_count, lowerer.hidden_local_types.items, boxed_locals),
        .instructions = try instructions.toOwnedInstructions(),
        .locations = try instructions.toOwnedLocations(),
    };
}

pub fn countCallbacksInStatements(statements: []const model.Statement) u32 {
    var count: u32 = 0;
    for (statements) |statement| count += countCallbacksInStatement(statement);
    return count;
}

fn countCallbacksInStatement(statement: model.Statement) u32 {
    return switch (statement) {
        .let_stmt => |node| if (node.value) |value| countCallbacksInExpr(value) else 0,
        .assign_stmt => |node| countCallbacksInExpr(node.target) + countCallbacksInExpr(node.value),
        .expr_stmt => |node| countCallbacksInExpr(node.expr),
        .if_stmt => |node| blk: {
            var count = countCallbacksInExpr(node.condition) + countCallbacksInStatements(node.then_body);
            if (node.else_body) |else_body| count += countCallbacksInStatements(else_body);
            break :blk count;
        },
        .for_stmt => |node| countCallbacksInExpr(node.iterator) + countCallbacksInStatements(node.body),
        .while_stmt => |node| countCallbacksInExpr(node.condition) + countCallbacksInStatements(node.body),
        .break_stmt, .continue_stmt => 0,
        .match_stmt => |node| blk: {
            var count = countCallbacksInExpr(node.subject);
            for (node.arms) |arm| {
                count += countCallbacksInPattern(arm.pattern);
                if (arm.guard) |guard| count += countCallbacksInExpr(guard);
                count += countCallbacksInStatements(arm.body);
            }
            break :blk count;
        },
        .switch_stmt => |node| blk: {
            var count = countCallbacksInExpr(node.subject);
            for (node.cases) |case_node| {
                count += countCallbacksInExpr(case_node.pattern);
                count += countCallbacksInStatements(case_node.body);
            }
            if (node.default_body) |default_body| count += countCallbacksInStatements(default_body);
            break :blk count;
        },
        .return_stmt => |node| if (node.value) |value| countCallbacksInExpr(value) else 0,
    };
}

fn countCallbacksInPattern(pattern: model.MatchPattern) u32 {
    return switch (pattern) {
        .variant => |node| if (node.inner) |inner| countCallbacksInPattern(inner.*) else 0,
        .binding => 0,
    };
}

fn countCallbacksInExpr(expr: *model.Expr) u32 {
    return switch (expr.*) {
        .callback => |node| 1 + countCallbacksInStatements(node.body),
        .construct => |node| blk: {
            var count: u32 = 0;
            for (node.fields) |field| count += countCallbacksInExpr(field.value);
            break :blk count;
        },
        .construct_enum_variant => |node| if (node.payload) |payload| countCallbacksInExpr(payload) else 0,
        .native_state => |node| countCallbacksInExpr(node.value),
        .native_user_data => |node| countCallbacksInExpr(node.state),
        .native_recover => |node| countCallbacksInExpr(node.value),
        .native_state_free => |node| countCallbacksInExpr(node.state),
        .call => |node| blk: {
            var count: u32 = 0;
            for (node.args) |arg| count += countCallbacksInExpr(arg);
            break :blk count;
        },
        .virtual_call => |node| blk: {
            var count = countCallbacksInExpr(node.receiver);
            for (node.args) |arg| count += countCallbacksInExpr(arg);
            break :blk count;
        },
        .call_value => |node| blk: {
            var count = countCallbacksInExpr(node.callee);
            for (node.args) |arg| count += countCallbacksInExpr(arg);
            break :blk count;
        },
        .parent_view => |node| countCallbacksInExpr(node.object),
        .c_string_to_string => |node| countCallbacksInExpr(node.value),
        .array_len => |node| countCallbacksInExpr(node.object),
        .string_len => |node| countCallbacksInExpr(node.object),
        .string_from_scalar => |node| countCallbacksInExpr(node.operand),
        .string_char_at => |node| countCallbacksInExpr(node.object) + countCallbacksInExpr(node.index),
        .string_substring => |node| countCallbacksInExpr(node.object) + countCallbacksInExpr(node.start) + countCallbacksInExpr(node.end),
        .string_index_of => |node| countCallbacksInExpr(node.object) + countCallbacksInExpr(node.needle),
        .field => |node| countCallbacksInExpr(node.object),
        .binary => |node| countCallbacksInExpr(node.lhs) + countCallbacksInExpr(node.rhs),
        .conditional => |node| countCallbacksInExpr(node.condition) + countCallbacksInExpr(node.then_expr) + countCallbacksInExpr(node.else_expr),
        .unary => |node| countCallbacksInExpr(node.operand),
        .cast => |node| countCallbacksInExpr(node.operand),
        .array => |node| blk: {
            var count: u32 = 0;
            for (node.elements) |element| count += countCallbacksInExpr(element);
            break :blk count;
        },
        .builder_array => |node| countCallbacksInBuilderBlock(node.builder),
        .index => |node| countCallbacksInExpr(node.object) + countCallbacksInExpr(node.index),
        else => 0,
    };
}

fn countCallbacksInBuilderBlock(builder: model.BuilderBlock) u32 {
    var count: u32 = 0;
    for (builder.items) |item| {
        count += switch (item) {
            .expr => |value| countCallbacksInExpr(value.expr),
            .if_item => |value| countCallbacksInExpr(value.condition) + countCallbacksInBuilderBlock(value.then_block) + (if (value.else_block) |else_block| countCallbacksInBuilderBlock(else_block) else 0),
            .for_item => |value| countCallbacksInExpr(value.iterator) + countCallbacksInBuilderBlock(value.body),
            .switch_item => |value| blk: {
                var inner = countCallbacksInExpr(value.subject);
                for (value.cases) |case_node| {
                    inner += countCallbacksInExpr(case_node.pattern);
                    inner += countCallbacksInBuilderBlock(case_node.body);
                }
                if (value.default_block) |default_block| inner += countCallbacksInBuilderBlock(default_block);
                break :blk inner;
            },
        };
    }
    return count;
}

const unmapped_local = std.math.maxInt(u32);

fn buildCallbackLocalRemap(allocator: std.mem.Allocator, callback: model.hir.CallbackExpr) ![]u32 {
    var max_local: u32 = 0;
    for (callback.locals) |local| max_local = @max(max_local, local.id);
    for (callback.captures) |capture| max_local = @max(max_local, capture.local_id);

    const remap = try allocator.alloc(u32, @as(usize, @intCast(max_local)) + 1);
    @memset(remap, unmapped_local);

    for (callback.params, 0..) |param, index| {
        if (param.id < remap.len) remap[param.id] = @intCast(index);
    }
    for (callback.captures, 0..) |capture, index| {
        if (capture.local_id < remap.len) remap[capture.local_id] = @intCast(callback.params.len + index);
    }

    var next_local: u32 = @intCast(callback.params.len + callback.captures.len);
    for (callback.locals) |local| {
        if (local.id >= remap.len or remap[local.id] != unmapped_local) continue;
        remap[local.id] = next_local;
        next_local += 1;
    }

    return remap;
}

pub fn remapLocalId(remap: []const u32, local: u32) u32 {
    if (local >= remap.len) return local;
    const mapped = remap[local];
    return if (mapped == unmapped_local) local else mapped;
}

fn callbackLocalCount(remap: []const u32) u32 {
    var count: u32 = 0;
    for (remap) |mapped| {
        if (mapped == unmapped_local) continue;
        count = @max(count, mapped + 1);
    }
    return count;
}

fn remapBoxedLocals(allocator: std.mem.Allocator, remap: []const u32, local_count: u32, original: []const bool) ![]bool {
    const boxed = try allocator.alloc(bool, local_count);
    @memset(boxed, false);
    for (original, 0..) |is_boxed, local| {
        if (!is_boxed) continue;
        const mapped = remapLocalId(remap, @intCast(local));
        if (mapped < boxed.len) boxed[mapped] = true;
    }
    return boxed;
}

fn lowerCallbackLocalTypes(
    allocator: std.mem.Allocator,
    program: model.Program,
    callback: model.hir.CallbackExpr,
    local_remap: []const u32,
    local_count: u32,
    hidden_locals: []const ir.ValueType,
    boxed_locals: []const bool,
) ![]ir.ValueType {
    const lowered = try allocator.alloc(ir.ValueType, @as(usize, @intCast(local_count)) + hidden_locals.len);
    for (lowered) |*slot| slot.* = .{ .kind = .void };
    for (callback.locals) |local| {
        const mapped = remapLocalId(local_remap, local.id);
        if (mapped < local_count) lowered[mapped] = try lowerResolvedType(program, local.ty);
    }
    for (hidden_locals, 0..) |hidden, index| {
        lowered[@as(usize, @intCast(local_count)) + index] = hidden;
    }
    for (boxed_locals, 0..) |boxed, index| {
        if (boxed and index < lowered.len) lowered[index] = .{ .kind = .raw_ptr, .name = "CaptureCell" };
    }
    for (callback.captures, 0..) |capture, index| {
        const param_slot = callback.params.len + index;
        if (param_slot < lowered.len) lowered[param_slot] = if (capture.by_ref) .{ .kind = .raw_ptr, .name = "CaptureCell" } else try lowerResolvedType(program, capture.ty);
    }
    return lowered;
}

fn lowerCallbackParamTypes(allocator: std.mem.Allocator, program: model.Program, callback: model.hir.CallbackExpr) ![]ir.ValueType {
    const lowered = try allocator.alloc(ir.ValueType, callback.params.len + callback.captures.len);
    for (callback.params, 0..) |param, index| {
        lowered[index] = try lowerResolvedType(program, param.ty);
    }
    for (callback.captures, 0..) |capture, index| {
        lowered[callback.params.len + index] = if (capture.by_ref) .{ .kind = .raw_ptr, .name = "CaptureCell" } else try lowerResolvedType(program, capture.ty);
    }
    return lowered;
}

fn lowerCallbackParamOwnership(allocator: std.mem.Allocator, callback: model.hir.CallbackExpr) ![]const ir.OwnershipMode {
    const lowered = try allocator.alloc(ir.OwnershipMode, callback.params.len + callback.captures.len);
    for (callback.params, 0..) |param, index| lowered[index] = parent.lowerOwnershipMode(param.ownership);
    for (callback.captures, 0..) |capture, index| {
        lowered[callback.params.len + index] = parent.lowerOwnershipMode(capture.ownership);
    }
    return lowered;
}
