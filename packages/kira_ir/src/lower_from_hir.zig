const std = @import("std");
const ir = @import("ir.zig");
const model = @import("kira_semantics_model");
const runtime_abi = @import("kira_runtime_abi");
const program_impl = @import("lower_from_hir_program.zig");
const type_impl = @import("lower_from_hir_types.zig");

pub const lowerTypeDecls = program_impl.lowerTypeDecls;
pub const lowerConstructs = program_impl.lowerConstructs;
pub const lowerConstructImplementations = program_impl.lowerConstructImplementations;
pub const markReachableFunction = program_impl.markReachableFunction;
pub const markReachableStatement = program_impl.markReachableStatement;
pub const markReachableExpr = program_impl.markReachableExpr;
pub const markReferencedType = program_impl.markReferencedType;
pub const lowerFieldTypes = program_impl.lowerFieldTypes;
pub const lowerFfiTypeInfo = program_impl.lowerFfiTypeInfo;
pub const lowerAssignmentStatement = program_impl.lowerAssignmentStatement;
pub const findTypeFieldDefaultExpr = program_impl.findTypeFieldDefaultExpr;
pub const fieldDeclIsTypeConstant = program_impl.fieldDeclIsTypeConstant;
pub const lowerResolvedType = type_impl.lowerResolvedType;
pub const lowerNamedType = type_impl.lowerNamedType;
pub const lowerExecutableCompareOperandType = type_impl.lowerExecutableCompareOperandType;
pub const lowerExecutableIntegerType = type_impl.lowerExecutableIntegerType;
pub const lowerExecutableNumericType = type_impl.lowerExecutableNumericType;
pub const lowerExecutableBooleanType = type_impl.lowerExecutableBooleanType;
pub const valueTypesEqual = type_impl.valueTypesEqual;
pub const findTypeDeclByName = type_impl.findTypeDeclByName;
pub const resolveConstructFieldIndex = type_impl.resolveConstructFieldIndex;
pub const fieldIndexByName = type_impl.fieldIndexByName;
pub const nativeStateTypeId = type_impl.nativeStateTypeId;

pub fn lowerProgram(allocator: std.mem.Allocator, program: model.Program) !ir.Program {
    var reachable = std.AutoHashMapUnmanaged(u32, void){};
    defer reachable.deinit(allocator);
    try markReachableFunction(allocator, program, &reachable, program.functions[program.entry_index].id);

    const constructs = try lowerConstructs(allocator, program);
    const construct_implementations = try lowerConstructImplementations(allocator, program);
    const types = try lowerTypeDecls(allocator, program, reachable);
    var state = ProgramLoweringState{
        .next_generated_function_id = nextGeneratedFunctionId(program),
        .generated_functions = std.array_list.Managed(ir.Function).init(allocator),
    };
    defer state.generated_functions.deinit();
    var functions = std.array_list.Managed(ir.Function).init(allocator);
    var entry_index: ?usize = null;
    for (program.functions) |function_decl| {
        if (!reachable.contains(function_decl.id)) continue;
        if (function_decl.id == program.functions[program.entry_index].id) entry_index = functions.items.len;
        try functions.append(try lowerFunction(allocator, program, function_decl, &state));
    }
    for (state.generated_functions.items) |function_decl| try functions.append(function_decl);
    return .{
        .constructs = constructs,
        .construct_implementations = construct_implementations,
        .types = types,
        .functions = try functions.toOwnedSlice(),
        .entry_index = entry_index orelse return error.UnsupportedExecutableFeature,
    };
}

const ProgramLoweringState = struct {
    next_generated_function_id: u32,
    generated_functions: std.array_list.Managed(ir.Function),
};

fn nextGeneratedFunctionId(program: model.Program) u32 {
    var next_id: u32 = 0;
    for (program.functions) |function_decl| {
        if (function_decl.id >= next_id) next_id = function_decl.id + 1;
    }
    return next_id;
}

fn lowerFunction(
    allocator: std.mem.Allocator,
    program: model.Program,
    function_decl: model.Function,
    state: *ProgramLoweringState,
) !ir.Function {
    if (function_decl.is_extern) {
        return .{
            .id = function_decl.id,
            .name = function_decl.name,
            .execution = function_decl.execution,
            .is_extern = true,
            .foreign = if (function_decl.foreign) |foreign| .{
                .library_name = foreign.library_name,
                .symbol_name = foreign.symbol_name,
                .calling_convention = foreign.calling_convention,
            } else null,
            .param_types = try lowerParamTypes(allocator, program, function_decl.params),
            .return_type = try lowerResolvedType(program, function_decl.return_type),
            .register_count = 0,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &.{},
        };
    }

    const boxed_locals = try collectBoxedLocals(allocator, function_decl.locals.len, function_decl.body);
    var lowerer = Lowerer{
        .allocator = allocator,
        .program = program,
        .state = state,
        .execution = function_decl.execution,
        .function_name = function_decl.name,
        .next_register = 0,
        .next_label = 0,
        .next_local = @as(u32, @intCast(function_decl.locals.len)),
        .hidden_local_types = std.array_list.Managed(ir.ValueType).init(allocator),
        .loop_stack = std.array_list.Managed(Lowerer.LoopLabels).init(allocator),
        .boxed_locals = boxed_locals,
    };
    defer allocator.free(boxed_locals);
    defer lowerer.hidden_local_types.deinit();
    defer lowerer.loop_stack.deinit();
    var instructions = std.array_list.Managed(ir.Instruction).init(allocator);
    const terminated = try lowerer.lowerStatements(&instructions, function_decl.body);

    if (!terminated and (instructions.items.len == 0 or instructions.items[instructions.items.len - 1] != .ret)) {
        try instructions.append(.{ .ret = .{ .src = null } });
    }

    return .{
        .id = function_decl.id,
        .name = function_decl.name,
        .execution = function_decl.execution,
        .is_extern = false,
        .foreign = null,
        .param_types = try lowerParamTypes(allocator, program, function_decl.params),
        .return_type = try lowerResolvedType(program, function_decl.return_type),
        .register_count = lowerer.next_register,
        .local_count = lowerer.next_local,
        .local_types = try lowerAllLocalTypesBoxed(allocator, program, function_decl.locals, lowerer.hidden_local_types.items, boxed_locals),
        .instructions = try instructions.toOwnedSlice(),
    };
}

fn lowerGeneratedCallbackFunction(
    allocator: std.mem.Allocator,
    program: model.Program,
    state: *ProgramLoweringState,
    function_id: u32,
    function_name: []const u8,
    execution: runtime_abi.FunctionExecution,
    callback: model.hir.CallbackExpr,
) !ir.Function {
    const boxed_locals = try collectBoxedLocals(allocator, callback.locals.len, callback.body);
    for (callback.captures) |capture| {
        if (capture.by_ref and capture.local_id < boxed_locals.len) boxed_locals[capture.local_id] = true;
    }
    var lowerer = Lowerer{
        .allocator = allocator,
        .program = program,
        .state = state,
        .execution = execution,
        .function_name = function_name,
        .next_register = 0,
        .next_label = 0,
        .next_local = @as(u32, @intCast(callback.locals.len)),
        .hidden_local_types = std.array_list.Managed(ir.ValueType).init(allocator),
        .loop_stack = std.array_list.Managed(Lowerer.LoopLabels).init(allocator),
        .boxed_locals = boxed_locals,
    };
    defer allocator.free(boxed_locals);
    defer lowerer.hidden_local_types.deinit();
    defer lowerer.loop_stack.deinit();

    var instructions = std.array_list.Managed(ir.Instruction).init(allocator);
    for (callback.captures, 0..) |capture, index| {
        const param_slot: u32 = @intCast(callback.params.len + index);
        if (param_slot == capture.local_id) continue;
        const reg = lowerer.freshRegister();
        try instructions.append(.{ .load_local = .{ .dst = reg, .local = param_slot } });
        try instructions.append(.{ .store_local = .{ .src = reg, .local = capture.local_id } });
    }
    const terminated = try lowerer.lowerStatements(&instructions, callback.body);
    if (!terminated and (instructions.items.len == 0 or instructions.items[instructions.items.len - 1] != .ret)) {
        try instructions.append(.{ .ret = .{ .src = null } });
    }

    return .{
        .id = function_id,
        .name = function_name,
        .execution = execution,
        .is_extern = false,
        .foreign = null,
        .param_types = try lowerCallbackParamTypes(allocator, program, callback),
        .return_type = try lowerResolvedType(program, callback.return_type),
        .register_count = lowerer.next_register,
        .local_count = lowerer.next_local,
        .local_types = try lowerCallbackLocalTypes(allocator, program, callback, lowerer.hidden_local_types.items, boxed_locals),
        .instructions = try instructions.toOwnedSlice(),
    };
}

fn lowerAllLocalTypes(
    allocator: std.mem.Allocator,
    program: model.Program,
    locals: []const model.LocalSymbol,
    hidden_locals: []const ir.ValueType,
) ![]ir.ValueType {
    const lowered = try allocator.alloc(ir.ValueType, locals.len + hidden_locals.len);
    for (locals, 0..) |local, index| {
        lowered[index] = try lowerResolvedType(program, local.ty);
    }
    for (hidden_locals, 0..) |local, index| {
        lowered[locals.len + index] = local;
    }
    return lowered;
}

fn lowerAllLocalTypesBoxed(
    allocator: std.mem.Allocator,
    program: model.Program,
    locals: []const model.LocalSymbol,
    hidden_locals: []const ir.ValueType,
    boxed_locals: []const bool,
) ![]ir.ValueType {
    const lowered = try lowerAllLocalTypes(allocator, program, locals, hidden_locals);
    for (boxed_locals, 0..) |boxed, index| {
        if (boxed and index < lowered.len) lowered[index] = .{ .kind = .raw_ptr, .name = "CaptureCell" };
    }
    return lowered;
}

fn lowerCallbackLocalTypes(
    allocator: std.mem.Allocator,
    program: model.Program,
    callback: model.hir.CallbackExpr,
    hidden_locals: []const ir.ValueType,
    boxed_locals: []const bool,
) ![]ir.ValueType {
    const lowered = try lowerAllLocalTypesBoxed(allocator, program, callback.locals, hidden_locals, boxed_locals);
    for (callback.captures, 0..) |_, index| {
        const param_slot = callback.params.len + index;
        if (param_slot < lowered.len) lowered[param_slot] = if (callback.captures[index].by_ref) .{ .kind = .raw_ptr, .name = "CaptureCell" } else try lowerResolvedType(program, callback.captures[index].ty);
    }
    return lowered;
}

fn lowerParamTypes(allocator: std.mem.Allocator, program: model.Program, params: []const model.Parameter) ![]ir.ValueType {
    const lowered = try allocator.alloc(ir.ValueType, params.len);
    for (params, 0..) |param, index| {
        lowered[index] = try lowerResolvedType(program, param.ty);
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

const lowerResolvedTypeSlice = type_impl.lowerResolvedTypeSlice;

fn collectBoxedLocals(allocator: std.mem.Allocator, local_count: usize, body: []const model.Statement) ![]bool {
    _ = body;
    const boxed = try allocator.alloc(bool, local_count);
    @memset(boxed, false);
    return boxed;
}

fn collectBoxedFromStatements(boxed: []bool, body: []const model.Statement) void {
    for (body) |statement| switch (statement) {
        .let_stmt => |node| if (node.value) |value| collectBoxedFromExpr(boxed, value),
        .assign_stmt => |node| {
            collectBoxedFromExpr(boxed, node.target);
            collectBoxedFromExpr(boxed, node.value);
        },
        .expr_stmt => |node| collectBoxedFromExpr(boxed, node.expr),
        .if_stmt => |node| {
            collectBoxedFromExpr(boxed, node.condition);
            collectBoxedFromStatements(boxed, node.then_body);
            if (node.else_body) |else_body| collectBoxedFromStatements(boxed, else_body);
        },
        .for_stmt => |node| {
            collectBoxedFromExpr(boxed, node.iterator);
            collectBoxedFromStatements(boxed, node.body);
        },
        .while_stmt => |node| {
            collectBoxedFromExpr(boxed, node.condition);
            collectBoxedFromStatements(boxed, node.body);
        },
        .switch_stmt => |node| {
            collectBoxedFromExpr(boxed, node.subject);
            for (node.cases) |case| {
                collectBoxedFromExpr(boxed, case.pattern);
                collectBoxedFromStatements(boxed, case.body);
            }
            if (node.default_body) |default_body| collectBoxedFromStatements(boxed, default_body);
        },
        .return_stmt => |node| if (node.value) |value| collectBoxedFromExpr(boxed, value),
        .break_stmt, .continue_stmt => {},
    };
}

fn collectBoxedFromExpr(boxed: []bool, expr: *const model.Expr) void {
    switch (expr.*) {
        .callback => |node| {
            for (node.captures) |capture| {
                if (capture.by_ref and capture.source_local_id < boxed.len) boxed[capture.source_local_id] = true;
            }
        },
        .binary => |node| {
            collectBoxedFromExpr(boxed, node.lhs);
            collectBoxedFromExpr(boxed, node.rhs);
        },
        .unary => |node| collectBoxedFromExpr(boxed, node.operand),
        .conditional => |node| {
            collectBoxedFromExpr(boxed, node.condition);
            collectBoxedFromExpr(boxed, node.then_expr);
            collectBoxedFromExpr(boxed, node.else_expr);
        },
        .construct => |node| for (node.fields) |field| collectBoxedFromExpr(boxed, field.value),
        .call => |node| for (node.args) |arg| collectBoxedFromExpr(boxed, arg),
        .call_value => |node| {
            collectBoxedFromExpr(boxed, node.callee);
            for (node.args) |arg| collectBoxedFromExpr(boxed, arg);
        },
        .array => |node| for (node.elements) |element| collectBoxedFromExpr(boxed, element),
        .index => |node| {
            collectBoxedFromExpr(boxed, node.object);
            collectBoxedFromExpr(boxed, node.index);
        },
        .field => |node| collectBoxedFromExpr(boxed, node.object),
        .parent_view => |node| collectBoxedFromExpr(boxed, node.object),
        .native_state => |node| collectBoxedFromExpr(boxed, node.value),
        .native_user_data => |node| collectBoxedFromExpr(boxed, node.state),
        .native_recover => |node| collectBoxedFromExpr(boxed, node.value),
        else => {},
    }
}

fn lowerExprStatement(lowerer: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), expr: *model.Expr) !void {
    switch (expr.*) {
        .call => |call| {
            if (call.trailing_builder != null) return error.UnsupportedExecutableFeature;
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
            var args = std.array_list.Managed(u32).init(lowerer.allocator);
            defer args.deinit();
            for (call.args) |arg| try args.append(try lowerer.lowerExpr(instructions, arg));
            try instructions.append(.{ .call = .{
                .callee = call.function_id.?,
                .args = try args.toOwnedSlice(),
                .dst = null,
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
                .return_type = try lowerResolvedType(lowerer.program, call.ty),
                .dst = null,
            } });
        },
        .callback => return error.UnsupportedExecutableFeature,
        else => return error.UnsupportedExecutableFeature,
    }
}

pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    program: model.Program,
    state: *ProgramLoweringState,
    execution: runtime_abi.FunctionExecution,
    function_name: []const u8,
    next_register: u32,
    next_label: u32,
    next_local: u32,
    hidden_local_types: std.array_list.Managed(ir.ValueType),
    loop_stack: std.array_list.Managed(LoopLabels),
    boxed_locals: []const bool,

    const LoopLabels = struct {
        break_label: u32,
        continue_label: u32,
    };

    pub fn freshRegister(self: *Lowerer) u32 {
        const reg = self.next_register;
        self.next_register += 1;
        return reg;
    }

    fn freshLabel(self: *Lowerer) u32 {
        const label = self.next_label;
        self.next_label += 1;
        return label;
    }

    fn freshHiddenLocal(self: *Lowerer, ty: ir.ValueType) !u32 {
        const local = self.next_local;
        self.next_local += 1;
        try self.hidden_local_types.append(ty);
        return local;
    }

    pub fn isBoxedLocal(self: *Lowerer, local: u32) bool {
        return local < self.boxed_locals.len and self.boxed_locals[local];
    }

    fn lowerCallbackExpr(self: *Lowerer, node: model.hir.CallbackExpr) !u32 {
        const function_id = self.state.next_generated_function_id;
        self.state.next_generated_function_id += 1;
        const function_name = try std.fmt.allocPrint(self.allocator, "{s}$callback_{d}", .{ self.function_name, function_id });
        try self.state.generated_functions.append(try lowerGeneratedCallbackFunction(
            self.allocator,
            self.program,
            self.state,
            function_id,
            function_name,
            self.execution,
            node,
        ));
        return function_id;
    }

    fn lowerStatements(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), statements: []const model.Statement) !bool {
        for (statements) |statement| {
            if (try self.lowerStatement(instructions, statement)) return true;
        }
        return false;
    }

    fn lowerStatement(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), statement: model.Statement) !bool {
        switch (statement) {
            .let_stmt => |node| {
                if (self.isBoxedLocal(node.local_id)) {
                    const ptr = self.freshRegister();
                    try instructions.append(.{ .local_ptr = .{ .dst = ptr, .local = node.local_id } });
                    try instructions.append(.{ .store_local = .{ .local = node.local_id, .src = ptr } });
                }
                if (node.value) |value| {
                    const reg = try self.lowerExpr(instructions, value);
                    if (self.isBoxedLocal(node.local_id)) {
                        try self.storeValueToLocal(instructions, node.local_id, try lowerResolvedType(self.program, node.ty), reg);
                        return false;
                    }
                    if ((try lowerResolvedType(self.program, node.ty)).kind == .ffi_struct) {
                        const dst_ptr = self.freshRegister();
                        try instructions.append(.{ .load_local = .{ .dst = dst_ptr, .local = node.local_id } });
                        try instructions.append(.{ .copy_indirect = .{
                            .dst_ptr = dst_ptr,
                            .src_ptr = reg,
                            .type_name = node.ty.name orelse return error.UnsupportedExecutableFeature,
                        } });
                    } else {
                        try instructions.append(.{ .store_local = .{ .local = node.local_id, .src = reg } });
                    }
                }
                return false;
            },
            .assign_stmt => |node| {
                try lowerAssignmentStatement(self, instructions, self.program, node);
                return false;
            },
            .expr_stmt => |node| {
                try lowerExprStatement(self, instructions, node.expr);
                return false;
            },
            .if_stmt => |node| return self.lowerIfStatement(instructions, node),
            .for_stmt => |node| return self.lowerForStatement(instructions, node),
            .while_stmt => |node| return self.lowerWhileStatement(instructions, node),
            .break_stmt => {
                const labels = self.loop_stack.getLast();
                try instructions.append(.{ .jump = .{ .label = labels.break_label } });
                return true;
            },
            .continue_stmt => {
                const labels = self.loop_stack.getLast();
                try instructions.append(.{ .jump = .{ .label = labels.continue_label } });
                return true;
            },
            .switch_stmt => |node| return self.lowerSwitchStatement(instructions, node),
            .return_stmt => |node| {
                const src = if (node.value) |value| try self.lowerExpr(instructions, value) else null;
                try instructions.append(.{ .ret = .{ .src = src } });
                return true;
            },
        }
    }

    fn lowerIfStatement(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), node: model.hir.IfStatement) !bool {
        const condition_reg = try self.lowerExpr(instructions, node.condition);
        const then_label = self.freshLabel();
        const else_label = self.freshLabel();
        try instructions.append(.{ .branch = .{
            .condition = condition_reg,
            .true_label = then_label,
            .false_label = else_label,
        } });

        try instructions.append(.{ .label = .{ .id = then_label } });
        const then_terminated = try self.lowerStatements(instructions, node.then_body);

        if (node.else_body) |else_body| {
            const needs_end_label = !then_terminated;
            const end_label = if (needs_end_label) self.freshLabel() else 0;

            if (!then_terminated) {
                try instructions.append(.{ .jump = .{ .label = end_label } });
            }

            try instructions.append(.{ .label = .{ .id = else_label } });
            const else_terminated = try self.lowerStatements(instructions, else_body);

            if (!then_terminated) {
                try instructions.append(.{ .label = .{ .id = end_label } });
            }

            return then_terminated and else_terminated;
        }

        try instructions.append(.{ .label = .{ .id = else_label } });
        return false;
    }

    fn lowerSwitchStatement(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), node: model.hir.SwitchStatement) !bool {
        const subject_reg = try self.lowerExpr(instructions, node.subject);
        const subject_ty = try lowerExecutableCompareOperandType(self.program, model.hir.exprType(node.subject.*), .equal);

        var need_end_label = false;
        const end_label = self.freshLabel();
        var all_cases_terminated = true;

        for (node.cases) |case_node| {
            const pattern_reg = try self.lowerExpr(instructions, case_node.pattern);
            const pattern_ty = try lowerExecutableCompareOperandType(self.program, model.hir.exprType(case_node.pattern.*), .equal);
            if (!valueTypesEqual(subject_ty, pattern_ty)) return error.UnsupportedExecutableFeature;

            const compare_reg = self.freshRegister();
            const case_label = self.freshLabel();
            const next_label = self.freshLabel();

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
            const case_terminated = try self.lowerStatements(instructions, case_node.body);
            all_cases_terminated = all_cases_terminated and case_terminated;
            if (!case_terminated) {
                need_end_label = true;
                try instructions.append(.{ .jump = .{ .label = end_label } });
            }

            try instructions.append(.{ .label = .{ .id = next_label } });
        }

        const default_terminated = if (node.default_body) |default_body|
            try self.lowerStatements(instructions, default_body)
        else
            false;

        if (need_end_label) {
            try instructions.append(.{ .label = .{ .id = end_label } });
        }

        return node.default_body != null and all_cases_terminated and default_terminated;
    }

    fn lowerForStatement(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), node: model.hir.ForStatement) !bool {
        switch (node.iterator.*) {
            .array => |iterator| {
                if (iterator.elements.len == 0) return false;
                const binding_ty = try lowerResolvedType(self.program, node.binding_ty);
                for (iterator.elements) |element| {
                    const element_reg = try self.lowerExpr(instructions, element);
                    try self.storeValueToLocal(instructions, node.binding_local_id, binding_ty, element_reg);
                    const end_label = self.freshLabel();
                    try self.loop_stack.append(.{ .break_label = end_label, .continue_label = end_label });
                    const body_terminated = try self.lowerStatements(instructions, node.body);
                    _ = self.loop_stack.pop();
                    try instructions.append(.{ .label = .{ .id = end_label } });
                    if (body_terminated) return true;
                }
                return false;
            },
            else => {
                const binding_ty = try lowerResolvedType(self.program, node.binding_ty);
                const array_reg = try self.lowerExpr(instructions, node.iterator);
                const len_reg = self.freshRegister();
                try instructions.append(.{ .array_len = .{ .dst = len_reg, .array = array_reg } });

                const index_local = try self.freshHiddenLocal(.{ .kind = .integer, .name = "I64" });
                const zero_reg = self.freshRegister();
                try instructions.append(.{ .const_int = .{ .dst = zero_reg, .value = 0 } });
                try instructions.append(.{ .store_local = .{ .local = index_local, .src = zero_reg } });

                const loop_label = self.freshLabel();
                const body_label = self.freshLabel();
                const end_label = self.freshLabel();

                try instructions.append(.{ .label = .{ .id = loop_label } });
                const index_reg = self.freshRegister();
                try instructions.append(.{ .load_local = .{ .dst = index_reg, .local = index_local } });
                const cmp_reg = self.freshRegister();
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
                const item_reg = self.freshRegister();
                try instructions.append(.{ .array_get = .{
                    .dst = item_reg,
                    .array = array_reg,
                    .index = index_reg,
                    .ty = binding_ty,
                } });
                try self.storeValueToLocal(instructions, node.binding_local_id, binding_ty, item_reg);
                try self.loop_stack.append(.{ .break_label = end_label, .continue_label = loop_label });
                const body_terminated = try self.lowerStatements(instructions, node.body);
                _ = self.loop_stack.pop();
                if (!body_terminated) {
                    const one_reg = self.freshRegister();
                    try instructions.append(.{ .const_int = .{ .dst = one_reg, .value = 1 } });
                    const next_reg = self.freshRegister();
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

    fn lowerWhileStatement(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), node: model.hir.WhileStatement) !bool {
        const loop_label = self.freshLabel();
        const body_label = self.freshLabel();
        const end_label = self.freshLabel();

        try instructions.append(.{ .label = .{ .id = loop_label } });
        const condition_reg = try self.lowerExpr(instructions, node.condition);
        try instructions.append(.{ .branch = .{
            .condition = condition_reg,
            .true_label = body_label,
            .false_label = end_label,
        } });

        try instructions.append(.{ .label = .{ .id = body_label } });
        try self.loop_stack.append(.{ .break_label = end_label, .continue_label = loop_label });
        const body_terminated = try self.lowerStatements(instructions, node.body);
        _ = self.loop_stack.pop();
        if (!body_terminated) {
            try instructions.append(.{ .jump = .{ .label = loop_label } });
        }
        try instructions.append(.{ .label = .{ .id = end_label } });
        return false;
    }

    pub fn lowerExpr(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), expr: *model.Expr) anyerror!u32 {
        return switch (expr.*) {
            .integer => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .const_int = .{ .dst = dst, .value = node.value } });
                break :blk dst;
            },
            .float => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .const_float = .{ .dst = dst, .value = node.value } });
                break :blk dst;
            },
            .boolean => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .const_bool = .{ .dst = dst, .value = node.value } });
                break :blk dst;
            },
            .null_ptr => |node| blk: {
                _ = node;
                const dst = self.freshRegister();
                try instructions.append(.{ .const_null_ptr = .{ .dst = dst } });
                break :blk dst;
            },
            .function_ref => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .const_function = .{
                    .dst = dst,
                    .function_id = node.function_id,
                    .representation = switch (node.representation) {
                        .callable_value => .callable_value,
                        .native_callback => .native_callback,
                    },
                } });
                break :blk dst;
            },
            .callback => |node| blk: {
                const function_id = try self.lowerCallbackExpr(node);
                const dst = self.freshRegister();
                if (node.captures.len == 0) {
                    try instructions.append(.{ .const_function = .{
                        .dst = dst,
                        .function_id = function_id,
                        .representation = .callable_value,
                    } });
                } else {
                    var captures = std.array_list.Managed(u32).init(self.allocator);
                    defer captures.deinit();
                    for (node.captures) |capture| {
                        const reg = self.freshRegister();
                        if (capture.by_ref) {
                            if (self.isBoxedLocal(capture.source_local_id)) {
                                try instructions.append(.{ .load_local = .{ .dst = reg, .local = capture.source_local_id } });
                            } else {
                                try instructions.append(.{ .local_ptr = .{ .dst = reg, .local = capture.source_local_id } });
                            }
                        } else {
                            try instructions.append(.{ .load_local = .{ .dst = reg, .local = capture.source_local_id } });
                        }
                        try captures.append(reg);
                    }
                    try instructions.append(.{ .const_closure = .{
                        .dst = dst,
                        .function_id = function_id,
                        .captures = try captures.toOwnedSlice(),
                    } });
                }
                break :blk dst;
            },
            .call_value => |node| blk: {
                const callee = try self.lowerExpr(instructions, node.callee);
                var args = std.array_list.Managed(u32).init(self.allocator);
                defer args.deinit();
                for (node.args) |arg| try args.append(try self.lowerExpr(instructions, arg));
                const dst = if (node.ty.kind == .void) null else self.freshRegister();
                try instructions.append(.{ .call_value = .{
                    .callee = callee,
                    .args = try args.toOwnedSlice(),
                    .param_types = try lowerResolvedTypeSlice(self.allocator, self.program, node.param_types),
                    .return_type = try lowerResolvedType(self.program, node.ty),
                    .dst = dst,
                } });
                break :blk dst orelse return error.UnsupportedExecutableFeature;
            },
            .namespace_ref => |node| blk: {
                if (std.mem.indexOfScalar(u8, node.path, '.')) |index| {
                    const type_name = node.path[0..index];
                    const field_name = node.path[index + 1 ..];
                    if (findTypeFieldDefaultExpr(self.program, type_name, field_name)) |default_value| {
                        break :blk try self.lowerExpr(instructions, default_value);
                    }
                }
                return error.UnsupportedExecutableFeature;
            },
            .array => |node| blk: {
                const len_reg = self.freshRegister();
                try instructions.append(.{ .const_int = .{
                    .dst = len_reg,
                    .value = @as(i64, @intCast(node.elements.len)),
                } });
                const dst = self.freshRegister();
                try instructions.append(.{ .alloc_array = .{ .dst = dst, .len = len_reg } });
                for (node.elements, 0..) |element, index| {
                    const index_reg = self.freshRegister();
                    try instructions.append(.{ .const_int = .{
                        .dst = index_reg,
                        .value = @as(i64, @intCast(index)),
                    } });
                    const value_reg = try self.lowerExpr(instructions, element);
                    try instructions.append(.{ .array_set = .{
                        .array = dst,
                        .index = index_reg,
                        .src = value_reg,
                    } });
                }
                break :blk dst;
            },
            .native_state => |node| blk: {
                const type_name = node.ty.name orelse return error.UnsupportedExecutableFeature;
                const src = try self.lowerExpr(instructions, node.value);
                const dst = self.freshRegister();
                try instructions.append(.{ .alloc_native_state = .{
                    .dst = dst,
                    .src = src,
                    .type_name = type_name,
                    .type_id = nativeStateTypeId(type_name),
                } });
                break :blk dst;
            },
            .native_user_data => |node| blk: {
                break :blk try self.lowerExpr(instructions, node.state);
            },
            .native_recover => |node| blk: {
                const state = try self.lowerExpr(instructions, node.value);
                const type_name = node.ty.name orelse return error.UnsupportedExecutableFeature;
                const dst = self.freshRegister();
                try instructions.append(.{ .recover_native_state = .{
                    .dst = dst,
                    .state = state,
                    .type_name = type_name,
                    .type_id = nativeStateTypeId(type_name),
                } });
                break :blk dst;
            },
            .index => |node| blk: {
                const array_reg = try self.lowerExpr(instructions, node.object);
                const index_reg = try self.lowerExpr(instructions, node.index);
                const dst = self.freshRegister();
                try instructions.append(.{ .array_get = .{
                    .dst = dst,
                    .array = array_reg,
                    .index = index_reg,
                    .ty = try lowerResolvedType(self.program, node.ty),
                } });
                break :blk dst;
            },
            .unary => |node| blk: {
                const src = try self.lowerExpr(instructions, node.operand);
                const operand_ty = model.hir.exprType(node.operand.*);
                const dst = self.freshRegister();
                switch (node.op) {
                    .negate => {
                        _ = try lowerExecutableNumericType(self.program, operand_ty);
                        try instructions.append(.{ .unary = .{
                            .dst = dst,
                            .src = src,
                            .op = .negate,
                        } });
                    },
                    .not => {
                        _ = try lowerExecutableBooleanType(self.program, operand_ty);
                        try instructions.append(.{ .unary = .{
                            .dst = dst,
                            .src = src,
                            .op = .not,
                        } });
                    },
                }
                break :blk dst;
            },
            .string => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .const_string = .{ .dst = dst, .value = node.value } });
                break :blk dst;
            },
            .construct => |node| blk: {
                const type_decl = findTypeDeclByName(self.program, node.ty.name orelse return error.UnsupportedExecutableFeature) orelse return error.UnsupportedExecutableFeature;
                const dst = self.freshRegister();
                try instructions.append(.{ .alloc_struct = .{
                    .dst = dst,
                    .type_name = type_decl.name,
                } });

                var filled = try self.allocator.alloc(bool, type_decl.fields.len);
                defer self.allocator.free(filled);
                @memset(filled, false);
                var next_index: usize = 0;

                for (node.fields) |field_init| {
                    const field_index = try resolveConstructFieldIndex(type_decl, filled, &next_index, field_init);
                    if (field_index >= type_decl.fields.len) return error.UnsupportedExecutableFeature;
                    if (filled[field_index]) return error.UnsupportedExecutableFeature;

                    const field_decl = type_decl.fields[field_index];
                    const field_value = try self.lowerExpr(instructions, field_init.value);
                    const ptr_reg = self.freshRegister();
                    const field_ty = try lowerResolvedType(self.program, field_decl.ty);
                    try instructions.append(.{ .field_ptr = .{
                        .dst = ptr_reg,
                        .base = dst,
                        .base_type_name = type_decl.name,
                        .field_index = @as(u32, @intCast(field_index)),
                        .field_ty = field_ty,
                    } });
                    if (field_ty.kind == .ffi_struct) {
                        try instructions.append(.{ .copy_indirect = .{
                            .dst_ptr = ptr_reg,
                            .src_ptr = field_value,
                            .type_name = field_ty.name orelse return error.UnsupportedExecutableFeature,
                        } });
                    } else {
                        try instructions.append(.{ .store_indirect = .{
                            .ptr = ptr_reg,
                            .src = field_value,
                            .ty = field_ty,
                        } });
                    }
                    filled[field_index] = true;
                }

                switch (node.fill_mode) {
                    .defaults => {
                        for (type_decl.fields, 0..) |field_decl, index| {
                            if (filled[index]) continue;
                            if (fieldDeclIsTypeConstant(field_decl, type_decl.name)) continue;
                            const default_value = field_decl.default_value orelse return error.UnsupportedExecutableFeature;
                            const field_value = try self.lowerExpr(instructions, default_value);
                            const ptr_reg = self.freshRegister();
                            const field_ty = try lowerResolvedType(self.program, field_decl.ty);
                            try instructions.append(.{ .field_ptr = .{
                                .dst = ptr_reg,
                                .base = dst,
                                .base_type_name = type_decl.name,
                                .field_index = @as(u32, @intCast(index)),
                                .field_ty = field_ty,
                            } });
                            if (field_ty.kind == .ffi_struct) {
                                try instructions.append(.{ .copy_indirect = .{
                                    .dst_ptr = ptr_reg,
                                    .src_ptr = field_value,
                                    .type_name = field_ty.name orelse return error.UnsupportedExecutableFeature,
                                } });
                            } else {
                                try instructions.append(.{ .store_indirect = .{
                                    .ptr = ptr_reg,
                                    .src = field_value,
                                    .ty = field_ty,
                                } });
                            }
                        }
                    },
                    .zeroed_ffi_c_layout => {},
                }

                break :blk dst;
            },
            .call => |node| blk: {
                if (node.function_id == null) return error.UnsupportedExecutableFeature;
                if (node.ty.kind == .void) return error.UnsupportedExecutableFeature;
                var args = std.array_list.Managed(u32).init(self.allocator);
                defer args.deinit();
                for (node.args) |arg| try args.append(try self.lowerExpr(instructions, arg));
                const dst = self.freshRegister();
                try instructions.append(.{ .call = .{
                    .callee = node.function_id.?,
                    .args = try args.toOwnedSlice(),
                    .dst = dst,
                } });
                break :blk dst;
            },
            .local => |node| blk: {
                const dst = self.freshRegister();
                if (self.isBoxedLocal(node.local_id)) {
                    const ptr = self.freshRegister();
                    try instructions.append(.{ .load_local = .{ .dst = ptr, .local = node.local_id } });
                    try instructions.append(.{ .load_indirect = .{ .dst = dst, .ptr = ptr, .ty = try lowerResolvedType(self.program, node.ty) } });
                } else {
                    try instructions.append(.{ .load_local = .{ .dst = dst, .local = node.local_id } });
                }
                break :blk dst;
            },
            .parent_view => |node| blk: {
                const base = try self.lowerExpr(instructions, node.object);
                if (node.offset == 0) break :blk base;
                const dst = self.freshRegister();
                try instructions.append(.{ .subobject_ptr = .{
                    .dst = dst,
                    .base = base,
                    .offset = node.offset,
                } });
                break :blk dst;
            },
            .field => |node| blk: {
                const object_reg = try self.lowerExpr(instructions, node.object);
                const field_ty = try lowerResolvedType(self.program, node.ty);
                if (model.hir.exprType(node.object.*).kind == .native_state_view) {
                    const dst = self.freshRegister();
                    try instructions.append(.{ .native_state_field_get = .{
                        .dst = dst,
                        .state = object_reg,
                        .field_index = node.field_index,
                        .field_ty = field_ty,
                    } });
                    break :blk dst;
                }
                const field_ptr = self.freshRegister();
                try instructions.append(.{ .field_ptr = .{
                    .dst = field_ptr,
                    .base = object_reg,
                    .base_type_name = node.container_type_name,
                    .field_index = node.field_index,
                    .field_ty = field_ty,
                } });
                if (field_ty.kind == .ffi_struct) break :blk field_ptr;
                const dst = self.freshRegister();
                try instructions.append(.{ .load_indirect = .{
                    .dst = dst,
                    .ptr = field_ptr,
                    .ty = field_ty,
                } });
                break :blk dst;
            },
            .binary => |node| blk: {
                const lhs = try self.lowerExpr(instructions, node.lhs);
                switch (node.op) {
                    .logical_and, .logical_or => break :blk try self.lowerLogicalBinaryExpr(instructions, node, lhs),
                    else => {},
                }

                const rhs = try self.lowerExpr(instructions, node.rhs);
                const dst = self.freshRegister();
                switch (node.op) {
                    .add => {
                        _ = try lowerExecutableNumericType(self.program, model.hir.exprType(node.lhs.*));
                        try instructions.append(.{ .add = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                    },
                    .subtract => {
                        _ = try lowerExecutableNumericType(self.program, model.hir.exprType(node.lhs.*));
                        try instructions.append(.{ .subtract = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                    },
                    .multiply => {
                        _ = try lowerExecutableNumericType(self.program, model.hir.exprType(node.lhs.*));
                        try instructions.append(.{ .multiply = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                    },
                    .divide => {
                        _ = try lowerExecutableNumericType(self.program, model.hir.exprType(node.lhs.*));
                        try instructions.append(.{ .divide = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                    },
                    .modulo => {
                        _ = try lowerExecutableNumericType(self.program, model.hir.exprType(node.lhs.*));
                        try instructions.append(.{ .modulo = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                    },
                    .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => {
                        _ = try lowerExecutableCompareOperandType(self.program, model.hir.exprType(node.lhs.*), node.op);
                        try instructions.append(.{ .compare = .{
                            .dst = dst,
                            .lhs = lhs,
                            .rhs = rhs,
                            .op = lowerCompareOp(node.op),
                        } });
                    },
                    .logical_and, .logical_or => unreachable,
                }
                break :blk dst;
            },
            .conditional => |node| try self.lowerConditionalExpr(instructions, node),
        };
    }

    fn lowerLogicalBinaryExpr(
        self: *Lowerer,
        instructions: *std.array_list.Managed(ir.Instruction),
        node: model.hir.BinaryExpr,
        lhs: u32,
    ) anyerror!u32 {
        _ = try lowerExecutableBooleanType(self.program, model.hir.exprType(node.lhs.*));
        _ = try lowerExecutableBooleanType(self.program, model.hir.exprType(node.rhs.*));

        const result_local = try self.freshHiddenLocal(.{ .kind = .boolean });
        const rhs_label = self.freshLabel();
        const short_label = self.freshLabel();
        const end_label = self.freshLabel();

        try instructions.append(.{ .branch = .{
            .condition = lhs,
            .true_label = if (node.op == .logical_and) rhs_label else short_label,
            .false_label = if (node.op == .logical_and) short_label else rhs_label,
        } });

        try instructions.append(.{ .label = .{ .id = short_label } });
        const short_value = self.freshRegister();
        try instructions.append(.{ .const_bool = .{
            .dst = short_value,
            .value = node.op == .logical_or,
        } });
        try instructions.append(.{ .store_local = .{ .local = result_local, .src = short_value } });
        try instructions.append(.{ .jump = .{ .label = end_label } });

        try instructions.append(.{ .label = .{ .id = rhs_label } });
        const rhs = try self.lowerExpr(instructions, node.rhs);
        try instructions.append(.{ .store_local = .{ .local = result_local, .src = rhs } });
        try instructions.append(.{ .jump = .{ .label = end_label } });

        try instructions.append(.{ .label = .{ .id = end_label } });
        const dst = self.freshRegister();
        try instructions.append(.{ .load_local = .{ .dst = dst, .local = result_local } });
        return dst;
    }

    fn lowerConditionalExpr(
        self: *Lowerer,
        instructions: *std.array_list.Managed(ir.Instruction),
        node: model.hir.ConditionalExpr,
    ) anyerror!u32 {
        _ = try lowerExecutableBooleanType(self.program, model.hir.exprType(node.condition.*));
        const result_ty = try lowerResolvedType(self.program, node.ty);
        const result_local = try self.freshHiddenLocal(result_ty);

        const condition_reg = try self.lowerExpr(instructions, node.condition);
        const then_label = self.freshLabel();
        const else_label = self.freshLabel();
        const end_label = self.freshLabel();

        try instructions.append(.{ .branch = .{
            .condition = condition_reg,
            .true_label = then_label,
            .false_label = else_label,
        } });

        try instructions.append(.{ .label = .{ .id = then_label } });
        const then_value = try self.lowerExpr(instructions, node.then_expr);
        try self.storeValueToLocal(instructions, result_local, result_ty, then_value);
        try instructions.append(.{ .jump = .{ .label = end_label } });

        try instructions.append(.{ .label = .{ .id = else_label } });
        const else_value = try self.lowerExpr(instructions, node.else_expr);
        try self.storeValueToLocal(instructions, result_local, result_ty, else_value);
        try instructions.append(.{ .jump = .{ .label = end_label } });

        try instructions.append(.{ .label = .{ .id = end_label } });
        const dst = self.freshRegister();
        try instructions.append(.{ .load_local = .{ .dst = dst, .local = result_local } });
        return dst;
    }

    fn storeValueToLocal(
        self: *Lowerer,
        instructions: *std.array_list.Managed(ir.Instruction),
        local: u32,
        ty: ir.ValueType,
        src: u32,
    ) !void {
        if (self.isBoxedLocal(local)) {
            const ptr = self.freshRegister();
            try instructions.append(.{ .load_local = .{ .dst = ptr, .local = local } });
            try instructions.append(.{ .store_indirect = .{ .ptr = ptr, .src = src, .ty = ty } });
            return;
        }
        if (ty.kind == .ffi_struct) {
            const dst_ptr = self.freshRegister();
            try instructions.append(.{ .load_local = .{ .dst = dst_ptr, .local = local } });
            try instructions.append(.{ .copy_indirect = .{
                .dst_ptr = dst_ptr,
                .src_ptr = src,
                .type_name = ty.name orelse return error.UnsupportedExecutableFeature,
            } });
            return;
        }
        try instructions.append(.{ .store_local = .{ .local = local, .src = src } });
    }
};

fn lowerCompareOp(op: model.hir.BinaryOp) ir.CompareOp {
    return switch (op) {
        .equal => .equal,
        .not_equal => .not_equal,
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        else => unreachable,
    };
}

test "lowers sparse FFI construction by zero-filling omitted fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const field_value = try allocator.create(model.Expr);
    field_value.* = .{ .integer = .{
        .value = 7,
        .span = .{ .start = 0, .end = 0 },
    } };

    const construct_value = try allocator.create(model.Expr);
    construct_value.* = .{ .construct = .{
        .type_name = "Example",
        .fields = &.{.{
            .field_name = "b",
            .field_index = 1,
            .value = field_value,
            .span = .{ .start = 0, .end = 0 },
        }},
        .fill_mode = .zeroed_ffi_c_layout,
        .ty = .{ .kind = .named, .name = "Example" },
        .span = .{ .start = 0, .end = 0 },
    } };

    const program = model.Program{
        .imports = &.{},
        .annotations = &.{},
        .capabilities = &.{},
        .constructs = &.{},
        .types = &.{.{
            .name = "Example",
            .fields = &.{
                .{ .name = "a", .owner_type_name = "Example", .storage = .mutable, .slot_index = 0, .ty = .{ .kind = .integer, .name = "U8" }, .explicit_type = true, .default_value = null, .annotations = &.{}, .span = .{ .start = 0, .end = 0 } },
                .{ .name = "b", .owner_type_name = "Example", .storage = .mutable, .slot_index = 1, .ty = .{ .kind = .integer, .name = "U8" }, .explicit_type = true, .default_value = null, .annotations = &.{}, .span = .{ .start = 0, .end = 0 } },
                .{ .name = "c", .owner_type_name = "Example", .storage = .mutable, .slot_index = 2, .ty = .{ .kind = .integer, .name = "U8" }, .explicit_type = true, .default_value = null, .annotations = &.{}, .span = .{ .start = 0, .end = 0 } },
            },
            .ffi = .{ .ffi_struct = .{ .layout = "c", .span = .{ .start = 0, .end = 0 } } },
            .span = .{ .start = 0, .end = 0 },
        }},
        .forms = &.{},
        .functions = &.{.{
            .id = 0,
            .name = "entry",
            .is_main = true,
            .execution = .runtime,
            .is_extern = false,
            .foreign = null,
            .annotations = &.{},
            .params = &.{},
            .locals = &.{.{ .id = 0, .name = "value", .ty = .{ .kind = .named, .name = "Example" }, .span = .{ .start = 0, .end = 0 } }},
            .return_type = .{ .kind = .void },
            .body = &.{
                .{ .let_stmt = .{ .local_id = 0, .ty = .{ .kind = .named, .name = "Example" }, .explicit_type = false, .value = construct_value, .span = .{ .start = 0, .end = 0 } } },
                .{ .return_stmt = .{ .value = null, .span = .{ .start = 0, .end = 0 } } },
            },
            .span = .{ .start = 0, .end = 0 },
        }},
        .entry_index = 0,
    };

    const lowered = try lowerProgram(allocator, program);
    const instructions = lowered.functions[0].instructions;

    var saw_field_b = false;
    var touched_other_field = false;
    for (instructions) |instruction| {
        if (instruction != .field_ptr) continue;
        if (instruction.field_ptr.field_index == 1) {
            saw_field_b = true;
        } else {
            touched_other_field = true;
        }
    }

    try std.testing.expect(saw_field_b);
    try std.testing.expect(!touched_other_field);
}
