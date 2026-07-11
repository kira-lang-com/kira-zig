//! Expression-position lowering satellites for HIR -> IR: expression
//! statements (statement-position calls, appends, prints), builder-array
//! blocks and their control-flow items, enum-aware compare-operand
//! normalization, and short-circuit logical / conditional expression lowering.
const std = @import("std");
const ir = @import("ir.zig");
const model = @import("kira_semantics_model");
const parent = @import("lower_from_hir.zig");
const type_impl = @import("lower_from_hir_types.zig");
const places_impl = @import("lower_from_hir_places.zig");

const Lowerer = parent.Lowerer;
const lowerResolvedType = type_impl.lowerResolvedType;
const lowerResolvedTypeSlice = type_impl.lowerResolvedTypeSlice;
const lowerExecutableBooleanType = type_impl.lowerExecutableBooleanType;

fn containsConstructAnyStorage(program: model.Program, ty: model.ResolvedType, depth: u32) bool {
    if (depth >= 64) return false;
    return switch (ty.kind) {
        .construct_any => true,
        .array => if (ty.name) |name|
            containsConstructAnyStorage(program, resolvedTypeFromStorageText(name) orelse return false, depth + 1)
        else
            false,
        .named => if (type_impl.findTypeDeclByName(program, ty.name orelse "")) |type_decl| blk: {
            for (type_decl.fields) |field| {
                if (containsConstructAnyStorage(program, field.ty, depth + 1)) break :blk true;
            }
            break :blk false;
        } else false,
        .enum_instance => blk: {
            const name = ty.name orelse return false;
            for (program.enums) |enum_decl| {
                if (!std.mem.eql(u8, enum_decl.name, name)) continue;
                for (enum_decl.variants) |variant| {
                    if (variant.payload_ty) |payload| {
                        if (containsConstructAnyStorage(program, payload, depth + 1)) break :blk true;
                    }
                }
                break;
            }
            break :blk false;
        },
        else => false,
    };
}

fn resolvedTypeFromStorageText(text: []const u8) ?model.ResolvedType {
    if (std.mem.startsWith(u8, text, "any ")) {
        return .{
            .kind = .construct_any,
            .name = text,
            .construct_constraint = .{ .construct_name = text[4..] },
        };
    }
    if (text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']') {
        return .{ .kind = .array, .name = text[1 .. text.len - 1] };
    }
    return .{ .kind = .named, .name = text };
}

pub fn lowerExprStatement(lowerer: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), expr: *model.Expr) !void {
    switch (expr.*) {
        .call => |call| {
            if (call.trailing_builder != null) return error.UnsupportedExecutableFeature;
            if (std.mem.eql(u8, call.callee_name, "array.append")) {
                if (call.args.len != 2) return error.UnsupportedExecutableFeature;
                // `arr[i].xs.append(v)`: the receiver array is reached through an array
                // element materialized by value, so the append only grows a transient
                // copy unless the element is written back. `lowerMutableObject` records
                // that write-back (none for a plain local-array receiver).
                var writebacks = places_impl.WritebackList.init(lowerer.allocator);
                defer writebacks.deinit();
                const array = try places_impl.lowerMutableObject(lowerer, instructions, call.args[0], &writebacks);
                const src = try lowerer.lowerExpr(instructions, call.args[1]);
                try instructions.append(.{ .array_append = .{
                    .array = array,
                    .src = src,
                } });
                try places_impl.emitWritebacks(instructions, &writebacks);
                return;
            }
            if (std.mem.eql(u8, call.callee_name, "print")) {
                if (call.args.len != 1) return error.UnsupportedExecutableFeature;
                const reg = try lowerer.lowerExpr(instructions, call.args[0]);
                try instructions.append(.{ .print = .{
                    .src = reg,
                    .ty = try lowerResolvedType(lowerer.program, model.hir.exprType(call.args[0].*)),
                } });
                return;
            }
            if (call.function_id == null) return error.UnsupportedExecutableFeature;
            // An array-element argument passed to a `borrow mut` parameter is mutated by
            // the callee in place on the VM's materialized element copy; persist those
            // mutations back into the array after the call.
            var writebacks = places_impl.WritebackList.init(lowerer.allocator);
            defer writebacks.deinit();
            const arg_regs = try places_impl.lowerDirectCallArgs(lowerer, instructions, call.args, call.function_id.?, &writebacks);
            try instructions.append(.{ .call = .{
                .callee = call.function_id.?,
                .args = arg_regs,
                .dst = null,
            } });
            try places_impl.emitWritebacks(instructions, &writebacks);
        },
        .builder_array => |node| {
            _ = try lowerBuilderArrayExpr(lowerer, instructions, node);
        },
        .native_state_free => |node| {
            const state = try lowerer.lowerExpr(instructions, node.state);
            try instructions.append(.{ .free_native_state = .{
                .state = state,
            } });
        },
        .call_value => |call| {
            const callee = try lowerer.lowerExpr(instructions, call.callee);
            var args = std.array_list.Managed(u32).init(lowerer.allocator);
            defer args.deinit();
            for (call.args) |arg| try args.append(try lowerer.lowerExpr(instructions, arg));
            try instructions.append(.{ .call_value = .{
                .callee = callee,
                .args = try args.toOwnedSlice(),
                .param_types = try lowerResolvedTypeSlice(lowerer.allocator, lowerer.program, call.param_types),
                .param_ownership = try parent.lowerOwnershipModeSlice(lowerer.allocator, call.param_ownership),
                .return_type = try lowerResolvedType(lowerer.program, call.ty),
                .dst = null,
            } });
        },
        .virtual_call => |call| {
            const receiver = try lowerer.lowerExpr(instructions, call.receiver);
            var args = std.array_list.Managed(u32).init(lowerer.allocator);
            defer args.deinit();
            for (call.args) |arg| try args.append(try lowerer.lowerExpr(instructions, arg));
            try instructions.append(.{ .call_virtual = .{
                .receiver = receiver,
                .static_type_name = call.static_type_name,
                .method_name = call.method_name,
                .args = try args.toOwnedSlice(),
                .return_ty = if (call.ty.kind == .unknown) .{ .kind = .void } else try lowerResolvedType(lowerer.program, call.ty),
                .dst = null,
            } });
        },
        .callback => return error.UnsupportedExecutableFeature,
        // A bare value in statement position is a no-op: reading a local has no
        // side effect, so nothing is emitted.
        .local => {},
        // Task operations in statement position: cancel/detach are the common
        // forms; a discarded spawn or await still evaluates for its effects.
        .task_cancel, .task_detach, .task_spawn, .task_spawn_ready, .task_await, .task_yield, .task_sleep => {
            _ = try lowerer.lowerExpr(instructions, expr);
        },
        else => return error.UnsupportedExecutableFeature,
    }
}

pub fn lowerBuilderArrayExpr(
    lowerer: *Lowerer,
    instructions: *std.array_list.Managed(ir.Instruction),
    node: model.hir.BuilderArrayExpr,
) !u32 {
    const len_reg = lowerer.freshRegister();
    try instructions.append(.{ .const_int = .{ .dst = len_reg, .value = 0 } });
    const dst = lowerer.freshRegister();
    try instructions.append(.{ .alloc_array = .{
        .dst = dst,
        .len = len_reg,
        .ty = try lowerResolvedType(lowerer.program, node.ty),
    } });
    try emitBuilderArrayItems(lowerer, instructions, dst, node.builder);
    return dst;
}

fn emitBuilderArrayItems(
    lowerer: *Lowerer,
    instructions: *std.array_list.Managed(ir.Instruction),
    array_reg: u32,
    builder: model.BuilderBlock,
) !void {
    for (builder.items) |item| {
        switch (item) {
            .expr => |expr_item| {
                const value_reg = try lowerer.lowerExpr(instructions, expr_item.expr);
                try instructions.append(.{ .array_append = .{ .array = array_reg, .src = value_reg } });
            },
            .if_item => |if_item| {
                const condition_reg = try lowerer.lowerExpr(instructions, if_item.condition);
                const then_label = lowerer.freshLabel();
                const else_label = lowerer.freshLabel();
                const end_label = lowerer.freshLabel();
                try instructions.append(.{ .branch = .{
                    .condition = condition_reg,
                    .true_label = then_label,
                    .false_label = else_label,
                } });
                try instructions.append(.{ .label = .{ .id = then_label } });
                try emitBuilderArrayItems(lowerer, instructions, array_reg, if_item.then_block);
                try instructions.append(.{ .jump = .{ .label = end_label } });
                try instructions.append(.{ .label = .{ .id = else_label } });
                if (if_item.else_block) |else_block| try emitBuilderArrayItems(lowerer, instructions, array_reg, else_block);
                try instructions.append(.{ .label = .{ .id = end_label } });
            },
            .for_item => |for_item| {
                switch (for_item.iterator.*) {
                    .array => |iterator| {
                        const binding_ty = try type_impl.lowerResolvedType(lowerer.program, for_item.binding_ty);
                        const binding_borrow = containsConstructAnyStorage(lowerer.program, for_item.binding_ty, 0);
                        for (iterator.elements) |element| {
                            const element_reg = try lowerer.lowerExpr(instructions, element);
                            if (binding_borrow) {
                                try instructions.append(.{ .store_local = .{ .local = for_item.binding_local_id, .src = element_reg, .borrow = true } });
                            } else {
                                try lowerer.storeValueToLocal(instructions, for_item.binding_local_id, binding_ty, element_reg);
                            }
                            try emitBuilderArrayItems(lowerer, instructions, array_reg, for_item.body);
                        }
                    },
                    else => {
                        const binding_ty = try type_impl.lowerResolvedType(lowerer.program, for_item.binding_ty);
                        // An Any (move-only) element is DRAINED out of the source array:
                        // `For(child in children) { child }` moves each element into the
                        // builder array (the EdOpenMenuTap content-forward shape). The
                        // read tombstones the source slot to VOID (array_get moved), so
                        // the source array's owner frees only the shell — not elements now
                        // owned by the destination. Without this the element aliases into
                        // two arrays and double-frees once Any teardown is enabled. The
                        // mid-IR checker rejects draining a borrowed source (move-out of a
                        // borrow), so this is only reachable for owned iterators.
                        const binding_borrow = containsConstructAnyStorage(lowerer.program, for_item.binding_ty, 0);
                        const iterator_reg = try lowerer.lowerExpr(instructions, for_item.iterator);
                        const len_reg = lowerer.freshRegister();
                        try instructions.append(.{ .array_len = .{ .dst = len_reg, .array = iterator_reg } });
                        const index_local = try lowerer.freshHiddenLocal(.{ .kind = .integer, .name = "I64" });
                        const zero_reg = lowerer.freshRegister();
                        try instructions.append(.{ .const_int = .{ .dst = zero_reg, .value = 0 } });
                        try instructions.append(.{ .store_local = .{ .local = index_local, .src = zero_reg } });

                        const loop_label = lowerer.freshLabel();
                        const body_label = lowerer.freshLabel();
                        const end_label = lowerer.freshLabel();
                        try instructions.append(.{ .label = .{ .id = loop_label } });
                        const index_reg = lowerer.freshRegister();
                        try instructions.append(.{ .load_local = .{ .dst = index_reg, .local = index_local } });
                        const cmp_reg = lowerer.freshRegister();
                        try instructions.append(.{ .compare = .{ .dst = cmp_reg, .lhs = index_reg, .rhs = len_reg, .op = .less } });
                        try instructions.append(.{ .branch = .{ .condition = cmp_reg, .true_label = body_label, .false_label = end_label } });
                        try instructions.append(.{ .label = .{ .id = body_label } });
                        const item_reg = lowerer.freshRegister();
                        // Any elements DRAIN (moved read, VOID the source slot) and are
                        // OWNED by the binding; everything else is a plain owned store of
                        // a borrowed/copied element (pre-existing behavior).
                        try instructions.append(.{ .array_get = .{ .dst = item_reg, .array = iterator_reg, .index = index_reg, .ty = binding_ty, .moved = binding_borrow } });
                        try lowerer.storeValueToLocal(instructions, for_item.binding_local_id, binding_ty, item_reg);
                        try instructions.append(.{ .scope_enter = .{} });
                        try emitBuilderArrayItems(lowerer, instructions, array_reg, for_item.body);
                        try instructions.append(.{ .scope_exit = .{ .locals = &.{for_item.binding_local_id} } });
                        const one_reg = lowerer.freshRegister();
                        try instructions.append(.{ .const_int = .{ .dst = one_reg, .value = 1 } });
                        const next_reg = lowerer.freshRegister();
                        try instructions.append(.{ .add = .{ .dst = next_reg, .lhs = index_reg, .rhs = one_reg } });
                        try instructions.append(.{ .store_local = .{ .local = index_local, .src = next_reg } });
                        try instructions.append(.{ .jump = .{ .label = loop_label } });
                        try instructions.append(.{ .label = .{ .id = end_label } });
                    },
                }
            },
            .switch_item => |switch_item| {
                const subject_reg = try lowerer.lowerExpr(instructions, switch_item.subject);
                const subject_ty = try type_impl.lowerExecutableCompareOperandType(lowerer.program, model.hir.exprType(switch_item.subject.*), .equal);
                const end_label = lowerer.freshLabel();
                var used_end_label = false;
                for (switch_item.cases) |case_node| {
                    const pattern_reg = try lowerer.lowerExpr(instructions, case_node.pattern);
                    const pattern_ty = try type_impl.lowerExecutableCompareOperandType(lowerer.program, model.hir.exprType(case_node.pattern.*), .equal);
                    if (!type_impl.valueTypesEqual(subject_ty, pattern_ty)) return error.UnsupportedExecutableFeature;
                    const compare_reg = lowerer.freshRegister();
                    const case_label = lowerer.freshLabel();
                    const next_label = lowerer.freshLabel();
                    const normalized = try normalizeCompareOperands(lowerer, instructions, subject_ty, subject_reg, pattern_reg);
                    try instructions.append(.{ .compare = .{ .dst = compare_reg, .lhs = normalized.lhs, .rhs = normalized.rhs, .op = .equal } });
                    try instructions.append(.{ .branch = .{ .condition = compare_reg, .true_label = case_label, .false_label = next_label } });
                    try instructions.append(.{ .label = .{ .id = case_label } });
                    try emitBuilderArrayItems(lowerer, instructions, array_reg, case_node.body);
                    try instructions.append(.{ .jump = .{ .label = end_label } });
                    used_end_label = true;
                    try instructions.append(.{ .label = .{ .id = next_label } });
                }
                if (switch_item.default_block) |default_block| try emitBuilderArrayItems(lowerer, instructions, array_reg, default_block);
                if (used_end_label) try instructions.append(.{ .label = .{ .id = end_label } });
            },
        }
    }
}

pub const CompareOperands = struct {
    lhs: u32,
    rhs: u32,
};

pub fn normalizeCompareOperands(
    lowerer: *Lowerer,
    instructions: *std.array_list.Managed(ir.Instruction),
    operand_vt: ir.ValueType,
    lhs: u32,
    rhs: u32,
) !CompareOperands {
    if (operand_vt.kind != .enum_instance) return .{ .lhs = lhs, .rhs = rhs };

    // Enum equality compares discriminant tags, not heap value identity. Without this,
    // `e == E.A` and builder-switch pattern matches compare boxed enum handles and never
    // agree for equal discriminants.
    const lhs_tag = lowerer.freshRegister();
    try instructions.append(.{ .enum_tag = .{ .dst = lhs_tag, .src = lhs } });
    const rhs_tag = lowerer.freshRegister();
    try instructions.append(.{ .enum_tag = .{ .dst = rhs_tag, .src = rhs } });
    return .{ .lhs = lhs_tag, .rhs = rhs_tag };
}

pub fn lowerLogicalBinaryExpr(
    lowerer: *Lowerer,
    instructions: *std.array_list.Managed(ir.Instruction),
    node: model.hir.BinaryExpr,
    lhs: u32,
) anyerror!u32 {
    _ = try lowerExecutableBooleanType(lowerer.program, model.hir.exprType(node.lhs.*));
    _ = try lowerExecutableBooleanType(lowerer.program, model.hir.exprType(node.rhs.*));

    const result_local = try lowerer.freshHiddenLocal(.{ .kind = .boolean });
    const rhs_label = lowerer.freshLabel();
    const short_label = lowerer.freshLabel();
    const end_label = lowerer.freshLabel();

    try instructions.append(.{ .branch = .{
        .condition = lhs,
        .true_label = if (node.op == .logical_and) rhs_label else short_label,
        .false_label = if (node.op == .logical_and) short_label else rhs_label,
    } });

    try instructions.append(.{ .label = .{ .id = short_label } });
    const short_value = lowerer.freshRegister();
    try instructions.append(.{ .const_bool = .{
        .dst = short_value,
        .value = node.op == .logical_or,
    } });
    try instructions.append(.{ .store_local = .{ .local = result_local, .src = short_value } });
    try instructions.append(.{ .jump = .{ .label = end_label } });

    try instructions.append(.{ .label = .{ .id = rhs_label } });
    const rhs = try lowerer.lowerExpr(instructions, node.rhs);
    try instructions.append(.{ .store_local = .{ .local = result_local, .src = rhs } });
    try instructions.append(.{ .jump = .{ .label = end_label } });

    try instructions.append(.{ .label = .{ .id = end_label } });
    const dst = lowerer.freshRegister();
    try instructions.append(.{ .load_local = .{ .dst = dst, .local = result_local } });
    return dst;
}

pub fn lowerConditionalExpr(
    lowerer: *Lowerer,
    instructions: *std.array_list.Managed(ir.Instruction),
    node: model.hir.ConditionalExpr,
) anyerror!u32 {
    _ = try lowerExecutableBooleanType(lowerer.program, model.hir.exprType(node.condition.*));
    const result_ty = try lowerResolvedType(lowerer.program, node.ty);
    const result_local = try lowerer.freshHiddenLocal(result_ty);

    const condition_reg = try lowerer.lowerExpr(instructions, node.condition);
    const then_label = lowerer.freshLabel();
    const else_label = lowerer.freshLabel();
    const end_label = lowerer.freshLabel();

    try instructions.append(.{ .branch = .{
        .condition = condition_reg,
        .true_label = then_label,
        .false_label = else_label,
    } });

    try instructions.append(.{ .label = .{ .id = then_label } });
    const then_value = try lowerer.lowerExpr(instructions, node.then_expr);
    try lowerer.storeValueToLocal(instructions, result_local, result_ty, then_value);
    try instructions.append(.{ .jump = .{ .label = end_label } });

    try instructions.append(.{ .label = .{ .id = else_label } });
    const else_value = try lowerer.lowerExpr(instructions, node.else_expr);
    try lowerer.storeValueToLocal(instructions, result_local, result_ty, else_value);
    try instructions.append(.{ .jump = .{ .label = end_label } });

    try instructions.append(.{ .label = .{ .id = end_label } });
    const dst = lowerer.freshRegister();
    try instructions.append(.{ .load_local = .{ .dst = dst, .local = result_local } });
    return dst;
}
