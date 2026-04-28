const std = @import("std");
const ir = @import("ir.zig");
const model = @import("kira_semantics_model");
const type_impl = @import("lower_from_hir_types.zig");

pub fn lowerIfStatement(lowerer: anytype, instructions: *std.array_list.Managed(ir.Instruction), node: model.hir.IfStatement) !bool {
    const condition_reg = try lowerer.lowerExpr(instructions, node.condition);
    const then_label = lowerer.freshLabel();
    const else_label = lowerer.freshLabel();
    try instructions.append(.{ .branch = .{
        .condition = condition_reg,
        .true_label = then_label,
        .false_label = else_label,
    } });

    try instructions.append(.{ .label = .{ .id = then_label } });
    const then_terminated = try lowerer.lowerStatements(instructions, node.then_body);

    if (node.else_body) |else_body| {
        const needs_end_label = !then_terminated;
        const end_label = if (needs_end_label) lowerer.freshLabel() else 0;

        if (!then_terminated) {
            try instructions.append(.{ .jump = .{ .label = end_label } });
        }

        try instructions.append(.{ .label = .{ .id = else_label } });
        const else_terminated = try lowerer.lowerStatements(instructions, else_body);

        if (!then_terminated) {
            try instructions.append(.{ .label = .{ .id = end_label } });
        }

        return then_terminated and else_terminated;
    }

    try instructions.append(.{ .label = .{ .id = else_label } });
    return false;
}

pub fn lowerSwitchStatement(lowerer: anytype, instructions: *std.array_list.Managed(ir.Instruction), node: model.hir.SwitchStatement) !bool {
    const subject_reg = try lowerer.lowerExpr(instructions, node.subject);
    const subject_ty = try type_impl.lowerExecutableCompareOperandType(lowerer.program, model.hir.exprType(node.subject.*), .equal);

    var need_end_label = false;
    const end_label = lowerer.freshLabel();
    var all_cases_terminated = true;

    for (node.cases) |case_node| {
        const pattern_reg = try lowerer.lowerExpr(instructions, case_node.pattern);
        const pattern_ty = try type_impl.lowerExecutableCompareOperandType(lowerer.program, model.hir.exprType(case_node.pattern.*), .equal);
        if (!type_impl.valueTypesEqual(subject_ty, pattern_ty)) return error.UnsupportedExecutableFeature;

        const compare_reg = lowerer.freshRegister();
        const case_label = lowerer.freshLabel();
        const next_label = lowerer.freshLabel();

        try instructions.append(.{ .compare = .{
            .dst = compare_reg,
            .lhs = subject_reg,
            .rhs = pattern_reg,
            .op = .equal,
        } });
        try instructions.append(.{ .branch = .{
            .condition = compare_reg,
            .true_label = case_label,
            .false_label = next_label,
        } });

        try instructions.append(.{ .label = .{ .id = case_label } });
        const case_terminated = try lowerer.lowerStatements(instructions, case_node.body);
        all_cases_terminated = all_cases_terminated and case_terminated;
        if (!case_terminated) {
            need_end_label = true;
            try instructions.append(.{ .jump = .{ .label = end_label } });
        }

        try instructions.append(.{ .label = .{ .id = next_label } });
    }

    const default_terminated = if (node.default_body) |default_body|
        try lowerer.lowerStatements(instructions, default_body)
    else
        false;

    if (need_end_label) {
        try instructions.append(.{ .label = .{ .id = end_label } });
    }

    return node.default_body != null and all_cases_terminated and default_terminated;
}

pub fn lowerMatchStatement(lowerer: anytype, instructions: *std.array_list.Managed(ir.Instruction), node: model.hir.MatchStatement) !bool {
    const subject_reg = try lowerer.lowerExpr(instructions, node.subject);
    var need_end_label = false;
    const end_label = lowerer.freshLabel();
    var all_arms_terminated = true;

    for (node.arms) |arm| {
        const next_label = lowerer.freshLabel();
        try lowerMatchPattern(lowerer, instructions, subject_reg, arm.pattern, next_label);

        if (arm.guard) |guard| {
            const guard_reg = try lowerer.lowerExpr(instructions, guard);
            const body_label = lowerer.freshLabel();
            try instructions.append(.{ .branch = .{
                .condition = guard_reg,
                .true_label = body_label,
                .false_label = next_label,
            } });
            try instructions.append(.{ .label = .{ .id = body_label } });
        }

        const arm_terminated = try lowerer.lowerStatements(instructions, arm.body);
        all_arms_terminated = all_arms_terminated and arm_terminated;
        if (!arm_terminated) {
            need_end_label = true;
            try instructions.append(.{ .jump = .{ .label = end_label } });
        }

        try instructions.append(.{ .label = .{ .id = next_label } });
    }

    if (need_end_label) {
        try instructions.append(.{ .label = .{ .id = end_label } });
    }

    return all_arms_terminated;
}

fn lowerMatchPattern(
    lowerer: anytype,
    instructions: *std.array_list.Managed(ir.Instruction),
    value_reg: u32,
    pattern: model.MatchPattern,
    fail_label: u32,
) !void {
    switch (pattern) {
        .binding => |node| {
            try lowerer.storeValueToLocal(instructions, node.local_id, try type_impl.lowerResolvedType(lowerer.program, node.ty), value_reg);
        },
        .variant => |node| {
            const tag_reg = lowerer.freshRegister();
            try instructions.append(.{ .enum_tag = .{ .dst = tag_reg, .src = value_reg } });
            const disc_reg = lowerer.freshRegister();
            try instructions.append(.{ .const_int = .{ .dst = disc_reg, .value = @as(i64, @intCast(node.discriminant)) } });
            const cmp_reg = lowerer.freshRegister();
            try instructions.append(.{ .compare = .{
                .dst = cmp_reg,
                .lhs = tag_reg,
                .rhs = disc_reg,
                .op = .equal,
            } });
            const success_label = lowerer.freshLabel();
            try instructions.append(.{ .branch = .{
                .condition = cmp_reg,
                .true_label = success_label,
                .false_label = fail_label,
            } });
            try instructions.append(.{ .label = .{ .id = success_label } });

            if (node.as_binding_local_id) |local_id| {
                try lowerer.storeValueToLocal(instructions, local_id, try type_impl.lowerResolvedType(lowerer.program, node.as_binding_ty orelse return error.UnsupportedExecutableFeature), value_reg);
            }
            if (node.inner) |inner| {
                const payload_reg = lowerer.freshRegister();
                try instructions.append(.{ .enum_payload = .{
                    .dst = payload_reg,
                    .src = value_reg,
                    .payload_ty = try type_impl.lowerResolvedType(lowerer.program, node.payload_ty orelse return error.UnsupportedExecutableFeature),
                } });
                try lowerMatchPattern(lowerer, instructions, payload_reg, inner.*, fail_label);
            }
        },
    }
}

pub fn lowerForStatement(lowerer: anytype, instructions: *std.array_list.Managed(ir.Instruction), node: model.hir.ForStatement) !bool {
    switch (node.iterator.*) {
        .array => |iterator| {
            if (iterator.elements.len == 0) return false;
            const binding_ty = try type_impl.lowerResolvedType(lowerer.program, node.binding_ty);
            for (iterator.elements) |element| {
                const element_reg = try lowerer.lowerExpr(instructions, element);
                try lowerer.storeValueToLocal(instructions, node.binding_local_id, binding_ty, element_reg);
                const end_label = lowerer.freshLabel();
                try lowerer.loop_stack.append(.{ .break_label = end_label, .continue_label = end_label });
                const body_terminated = try lowerer.lowerStatements(instructions, node.body);
                _ = lowerer.loop_stack.pop();
                try instructions.append(.{ .label = .{ .id = end_label } });
                if (body_terminated) return true;
            }
            return false;
        },
        else => {
            const binding_ty = try type_impl.lowerResolvedType(lowerer.program, node.binding_ty);
            const array_reg = try lowerer.lowerExpr(instructions, node.iterator);
            const len_reg = lowerer.freshRegister();
            try instructions.append(.{ .array_len = .{ .dst = len_reg, .array = array_reg } });

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
            try instructions.append(.{ .compare = .{
                .dst = cmp_reg,
                .lhs = index_reg,
                .rhs = len_reg,
                .op = .less,
            } });
            try instructions.append(.{ .branch = .{
                .condition = cmp_reg,
                .true_label = body_label,
                .false_label = end_label,
            } });

            try instructions.append(.{ .label = .{ .id = body_label } });
            const item_reg = lowerer.freshRegister();
            try instructions.append(.{ .array_get = .{
                .dst = item_reg,
                .array = array_reg,
                .index = index_reg,
                .ty = binding_ty,
            } });
            try lowerer.storeValueToLocal(instructions, node.binding_local_id, binding_ty, item_reg);
            try lowerer.loop_stack.append(.{ .break_label = end_label, .continue_label = loop_label });
            const body_terminated = try lowerer.lowerStatements(instructions, node.body);
            _ = lowerer.loop_stack.pop();
            if (!body_terminated) {
                const one_reg = lowerer.freshRegister();
                try instructions.append(.{ .const_int = .{ .dst = one_reg, .value = 1 } });
                const next_reg = lowerer.freshRegister();
                try instructions.append(.{ .add = .{ .dst = next_reg, .lhs = index_reg, .rhs = one_reg } });
                try instructions.append(.{ .store_local = .{ .local = index_local, .src = next_reg } });
                try instructions.append(.{ .jump = .{ .label = loop_label } });
                try instructions.append(.{ .label = .{ .id = end_label } });
                return false;
            }
            return true;
        },
    }
}

pub fn lowerWhileStatement(lowerer: anytype, instructions: *std.array_list.Managed(ir.Instruction), node: model.hir.WhileStatement) !bool {
    const loop_label = lowerer.freshLabel();
    const body_label = lowerer.freshLabel();
    const end_label = lowerer.freshLabel();

    try instructions.append(.{ .label = .{ .id = loop_label } });
    const condition_reg = try lowerer.lowerExpr(instructions, node.condition);
    try instructions.append(.{ .branch = .{
        .condition = condition_reg,
        .true_label = body_label,
        .false_label = end_label,
    } });

    try instructions.append(.{ .label = .{ .id = body_label } });
    try lowerer.loop_stack.append(.{ .break_label = end_label, .continue_label = loop_label });
    const body_terminated = try lowerer.lowerStatements(instructions, node.body);
    _ = lowerer.loop_stack.pop();
    if (!body_terminated) {
        try instructions.append(.{ .jump = .{ .label = loop_label } });
    }
    try instructions.append(.{ .label = .{ .id = end_label } });
    return false;
}
