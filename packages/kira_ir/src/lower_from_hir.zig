const std = @import("std");
const ir = @import("ir.zig");
const source = @import("kira_source");
const model = @import("kira_semantics_model");
const runtime_abi = @import("kira_runtime_abi");
const program_impl = @import("lower_from_hir_program.zig");
const type_impl = @import("lower_from_hir_types.zig");
const statement_impl = @import("lower_from_hir_statements.zig");
const namespace_ref_impl = @import("lower_from_hir_namespace_refs.zig");
const places_impl = @import("lower_from_hir_places.zig");
const function_impl = @import("lower_from_hir_functions.zig");
const callback_impl = @import("lower_from_hir_callbacks.zig");
const expr_stmt_impl = @import("lower_from_hir_expr_statements.zig");

const FunctionLoweringState = function_impl.FunctionLoweringState;

pub const lowerTypeDecls = program_impl.lowerTypeDecls;
pub const lowerEnumTypeDecls = program_impl.lowerEnumTypeDecls;
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
pub const functionIdByName = program_impl.functionIdByName;
pub const lowerNamespaceRefExpr = namespace_ref_impl.lowerNamespaceRefExpr;
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
    return lowerProgramWithOptions(allocator, program, .{});
}

pub const LowerProgramOptions = struct {
    worker_count_override: ?usize = null,
    include_tests: bool = false,
    /// Optional sink for locating an `error.UnsupportedExecutableFeature` /
    /// `error.UnsupportedType` failure. When set, the lowerer records the span
    /// and kind of the HIR construct it was lowering at the moment it gave up,
    /// so the KIR001 diagnostic can point at the real expression instead of the
    /// entry file. Left null by callers that don't surface diagnostics.
    unsupported_out: ?*UnsupportedFeature = null,
};

/// Where an unsupported-feature lowering failure happened. `construct` is the
/// HIR node kind (e.g. "virtual_call", "match_stmt"); `span` locates it in the
/// originating source. Both empty/null when the failure had no node in scope.
pub const UnsupportedFeature = struct {
    span: ?source.Span = null,
    construct: []const u8 = "",
};

/// Span of an HIR expression, regardless of variant — every `Expr` payload
/// carries a `span`, so an `inline else` projects it without a per-variant arm.
fn exprSpan(expr: *const model.Expr) source.Span {
    return switch (expr.*) {
        inline else => |node| node.span,
    };
}

/// Span of an HIR statement; see `exprSpan`.
fn statementSpan(statement: model.Statement) source.Span {
    return switch (statement) {
        inline else => |node| node.span,
    };
}

/// Record the construct the lowerer failed on into `out`, first (innermost)
/// writer wins so a failing callback body keeps its own span rather than the
/// enclosing function's. No-op for errors that are not unsupported-feature
/// failures, so unrelated errors (OOM, plan mismatch) don't claim a location.
pub fn recordUnsupported(out: ?*UnsupportedFeature, span: ?source.Span, construct: []const u8, err: anyerror) void {
    const capture = out orelse return;
    switch (err) {
        error.UnsupportedExecutableFeature, error.UnsupportedType => {},
        else => return,
    }
    if (capture.span != null or capture.construct.len != 0) return;
    capture.span = span;
    capture.construct = construct;
}

pub fn lowerProgramWithOptions(allocator: std.mem.Allocator, program: model.Program, options: LowerProgramOptions) !ir.Program {
    var reachable = std.AutoHashMapUnmanaged(u32, void){};
    defer reachable.deinit(allocator);
    try markReachableFunction(allocator, program, &reachable, program.functions[program.entry_index].id);
    if (options.include_tests) {
        for (program.tests) |test_case| {
            try markReachableFunctionByName(allocator, program, &reachable, test_case.test_function);
            try markReachableFunctionByName(allocator, program, &reachable, test_case.expect_function);
        }
        // The synthesized pure-Kira test driver (when present) is the entry the
        // test runner invokes by name; keep it (and everything it calls) live.
        // No-op when the driver was not synthesized.
        try markReachableFunctionByName(allocator, program, &reachable, "__kira_test_main");
    }

    const constructs = try lowerConstructs(allocator, program);
    const construct_implementations = try lowerConstructImplementations(allocator, program);
    const types = try lowerTypeDecls(allocator, program, reachable);
    const enums = try lowerEnumTypeDecls(allocator, program, reachable);

    const plans = try function_impl.buildFunctionPlans(allocator, program, reachable);
    const batches = if (function_impl.shouldParallelLower(options, plans.len))
        try function_impl.lowerFunctionPlansParallel(allocator, program, plans, options)
    else
        try function_impl.lowerFunctionPlansSerial(allocator, program, plans, options.unsupported_out);
    defer allocator.free(batches);

    var function_count: usize = 0;
    for (batches) |batch| function_count += 1 + batch.generated_functions.len;
    const functions = try allocator.alloc(ir.Function, function_count);

    var entry_index: ?usize = null;
    var primary_index: usize = 0;
    const entry_function_id = program.functions[program.entry_index].id;
    for (batches) |batch| {
        if (batch.primary.id == entry_function_id) entry_index = primary_index;
        functions[primary_index] = batch.primary;
        primary_index += 1;
    }
    var generated_index = primary_index;
    for (batches) |batch| {
        for (batch.generated_functions) |function_decl| {
            functions[generated_index] = function_decl;
            generated_index += 1;
        }
    }

    return .{
        .constructs = constructs,
        .construct_implementations = construct_implementations,
        .types = types,
        .enums = enums,
        .functions = functions,
        .entry_index = entry_index orelse {
            if (options.unsupported_out) |capture| capture.construct = "program entry point";
            return error.UnsupportedExecutableFeature;
        },
    };
}

fn markReachableFunctionByName(
    allocator: std.mem.Allocator,
    program: model.Program,
    reachable: *std.AutoHashMapUnmanaged(u32, void),
    name: []const u8,
) !void {
    for (program.functions) |function_decl| {
        if (std.mem.eql(u8, function_decl.name, name)) {
            try markReachableFunction(allocator, program, reachable, function_decl.id);
            return;
        }
    }
}

pub fn lowerOwnershipModeSlice(allocator: std.mem.Allocator, modes: []const model.OwnershipMode) ![]const ir.OwnershipMode {
    const lowered = try allocator.alloc(ir.OwnershipMode, modes.len);
    for (modes, 0..) |mode, index| lowered[index] = lowerOwnershipMode(mode);
    return lowered;
}

fn lowerCaptureOwnershipSlice(allocator: std.mem.Allocator, captures: []const model.Capture) ![]const ir.OwnershipMode {
    const lowered = try allocator.alloc(ir.OwnershipMode, captures.len);
    for (captures, 0..) |capture, index| lowered[index] = lowerOwnershipMode(capture.ownership);
    return lowered;
}

pub fn lowerOwnershipMode(mode: model.OwnershipMode) ir.OwnershipMode {
    return @enumFromInt(@intFromEnum(mode));
}

const lowerResolvedTypeSlice = type_impl.lowerResolvedTypeSlice;

pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    program: model.Program,
    state: *FunctionLoweringState,
    execution: runtime_abi.FunctionExecution,
    function_name: []const u8,
    next_register: u32,
    next_label: u32,
    next_local: u32,
    hidden_local_types: std.array_list.Managed(ir.ValueType),
    loop_stack: std.array_list.Managed(LoopLabels),
    boxed_locals: []const bool,
    local_remap: ?[]const u32 = null,
    /// The HIR construct currently being lowered, updated on entry to
    /// `lowerExpr`/`lowerStatement`. Read by the `errdefer` in `lowerFunction`
    /// to attribute an unsupported-feature failure to the right source span.
    current_span: ?source.Span = null,
    current_construct: []const u8 = "",

    pub const LoopLabels = struct {
        break_label: u32,
        continue_label: u32,
    };

    pub fn freshRegister(self: *Lowerer) u32 {
        const reg = self.next_register;
        self.next_register += 1;
        return reg;
    }

    pub fn freshLabel(self: *Lowerer) u32 {
        const label = self.next_label;
        self.next_label += 1;
        return label;
    }

    pub fn freshHiddenLocal(self: *Lowerer, ty: ir.ValueType) !u32 {
        const local = self.next_local;
        self.next_local += 1;
        try self.hidden_local_types.append(ty);
        return local;
    }

    pub fn mapLocal(self: *const Lowerer, local: u32) u32 {
        if (self.local_remap) |remap| return callback_impl.remapLocalId(remap, local);
        return local;
    }

    pub fn isBoxedLocal(self: *Lowerer, local: u32) bool {
        const mapped = self.mapLocal(local);
        return mapped < self.boxed_locals.len and self.boxed_locals[mapped];
    }

    pub fn isBoxedStorageLocal(self: *Lowerer, local: u32) bool {
        return local < self.boxed_locals.len and self.boxed_locals[local];
    }

    pub fn lowerStatements(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), statements: []const model.Statement) !bool {
        for (statements) |statement| {
            if (try self.lowerStatement(instructions, statement)) return true;
        }
        return false;
    }

    fn lowerStatement(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), statement: model.Statement) !bool {
        self.current_span = statementSpan(statement);
        self.current_construct = @tagName(statement);
        switch (statement) {
            .let_stmt => |node| {
                const local_id = self.mapLocal(node.local_id);
                if (node.is_reborrow) {
                    // Reborrow (`var r = t` over a borrow): bind the local as a
                    // non-owning alias of the source pointer. No box, no clone — both
                    // bindings reference the same storage, mutations are shared, and
                    // the alias is not freed at scope exit (the borrow's owner frees).
                    if (node.value) |value| {
                        const reg = try self.lowerExpr(instructions, value);
                        try instructions.append(.{ .store_local = .{ .local = local_id, .src = reg, .borrow = true } });
                    }
                    return false;
                }
                if (self.isBoxedLocal(node.local_id)) {
                    try self.initializeBoxedLocal(instructions, local_id, try lowerResolvedType(self.program, node.ty), null);
                }
                if (node.value) |value| {
                    const reg = try self.lowerExpr(instructions, value);
                    if (self.isBoxedLocal(node.local_id)) {
                        try self.storeValueToLocal(instructions, local_id, try lowerResolvedType(self.program, node.ty), reg);
                        return false;
                    }
                    if ((try lowerResolvedType(self.program, node.ty)).kind == .ffi_struct) {
                        const dst_ptr = self.freshRegister();
                        try instructions.append(.{ .load_local = .{ .dst = dst_ptr, .local = local_id } });
                        try instructions.append(.{ .copy_indirect = .{
                            .dst_ptr = dst_ptr,
                            .src_ptr = reg,
                            .type_name = node.ty.name orelse return error.UnsupportedExecutableFeature,
                        } });
                    } else {
                        try instructions.append(.{ .store_local = .{ .local = local_id, .src = reg } });
                    }
                }
                return false;
            },
            .assign_stmt => |node| {
                try lowerAssignmentStatement(self, instructions, self.program, node);
                return false;
            },
            .expr_stmt => |node| {
                try expr_stmt_impl.lowerExprStatement(self, instructions, node.expr);
                return false;
            },
            .if_stmt => |node| return statement_impl.lowerIfStatement(self, instructions, node),
            .for_stmt => |node| return statement_impl.lowerForStatement(self, instructions, node),
            .while_stmt => |node| return statement_impl.lowerWhileStatement(self, instructions, node),
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
            .match_stmt => |node| return statement_impl.lowerMatchStatement(self, instructions, node),
            .switch_stmt => |node| return statement_impl.lowerSwitchStatement(self, instructions, node),
            .return_stmt => |node| {
                const src = if (node.value) |value| try self.lowerReturnExpr(instructions, value) else null;
                try instructions.append(.{ .ret = .{ .src = src } });
                return true;
            },
        }
    }

    fn lowerReturnExpr(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), expr: *model.Expr) anyerror!u32 {
        if (expr.* == .local and !self.isBoxedLocal(expr.local.local_id)) {
            const dst = self.freshRegister();
            try instructions.append(.{ .load_local = .{
                .dst = dst,
                .local = self.mapLocal(expr.local.local_id),
                .ownership = .move,
            } });
            return dst;
        }
        if (expr.* == .field) {
            const field_ty = try lowerResolvedType(self.program, expr.field.ty);
            if (field_ty.kind == .ffi_struct) {
                const ptr = try self.lowerExpr(instructions, expr);
                const dst = self.freshRegister();
                try instructions.append(.{ .load_indirect = .{
                    .dst = dst,
                    .ptr = ptr,
                    .ty = field_ty,
                } });
                return dst;
            }
        }
        return self.lowerExpr(instructions, expr);
    }

    pub fn lowerExpr(self: *Lowerer, instructions: *std.array_list.Managed(ir.Instruction), expr: *model.Expr) anyerror!u32 {
        self.current_span = exprSpan(expr);
        self.current_construct = @tagName(expr.*);
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
                const function_id = try callback_impl.lowerCallbackExpr(self, node);
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
                        const source_local = self.mapLocal(capture.source_local_id);
                        if (capture.by_ref) {
                            if (self.isBoxedLocal(capture.source_local_id)) {
                                try instructions.append(.{ .load_local = .{ .dst = reg, .local = source_local } });
                            } else {
                                try instructions.append(.{ .local_ptr = .{ .dst = reg, .local = source_local } });
                            }
                        } else {
                            try instructions.append(.{ .load_local = .{ .dst = reg, .local = source_local, .ownership = lowerOwnershipMode(capture.ownership) } });
                        }
                        try captures.append(reg);
                    }
                    try instructions.append(.{ .const_closure = .{
                        .dst = dst,
                        .function_id = function_id,
                        .captures = try captures.toOwnedSlice(),
                        .capture_ownership = try lowerCaptureOwnershipSlice(self.allocator, node.captures),
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
                    .param_ownership = try lowerOwnershipModeSlice(self.allocator, node.param_ownership),
                    .return_type = try lowerResolvedType(self.program, node.ty),
                    .dst = dst,
                } });
                break :blk dst orelse return error.UnsupportedExecutableFeature;
            },
            .virtual_call => |node| blk: {
                const receiver = try self.lowerExpr(instructions, node.receiver);
                var args = std.array_list.Managed(u32).init(self.allocator);
                defer args.deinit();
                for (node.args) |arg| try args.append(try self.lowerExpr(instructions, arg));
                const dst = if (node.ty.kind == .void) null else self.freshRegister();
                try instructions.append(.{ .call_virtual = .{
                    .receiver = receiver,
                    .static_type_name = node.static_type_name,
                    .method_name = node.method_name,
                    .args = try args.toOwnedSlice(),
                    .return_ty = try lowerResolvedType(self.program, node.ty),
                    .dst = dst,
                } });
                break :blk dst orelse return error.UnsupportedExecutableFeature;
            },
            .namespace_ref => |node| blk: {
                if (try lowerNamespaceRefExpr(self, instructions, node.path)) |lowered| {
                    break :blk lowered;
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
                try instructions.append(.{ .alloc_array = .{
                    .dst = dst,
                    .len = len_reg,
                    .ty = try lowerResolvedType(self.program, node.ty),
                } });
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
            .builder_array => |node| try expr_stmt_impl.lowerBuilderArrayExpr(self, instructions, node),
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
            .native_state_free => |node| blk: {
                const state = try self.lowerExpr(instructions, node.state);
                try instructions.append(.{ .free_native_state = .{
                    .state = state,
                } });
                const dst = self.freshRegister();
                try instructions.append(.{ .const_null_ptr = .{ .dst = dst } });
                break :blk dst;
            },
            .c_string_to_string => |node| blk: {
                const src = try self.lowerExpr(instructions, node.value);
                const dst = self.freshRegister();
                try instructions.append(.{ .c_string_to_string = .{
                    .dst = dst,
                    .src = src,
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
                    .bit_not => {
                        _ = try lowerExecutableIntegerType(self.program, operand_ty);
                        try instructions.append(.{ .unary = .{
                            .dst = dst,
                            .src = src,
                            .op = .bit_not,
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
            .construct_enum_variant => |node| blk: {
                const dst = self.freshRegister();
                try instructions.append(.{ .alloc_enum = .{
                    .dst = dst,
                    .enum_type_name = node.enum_name,
                    .discriminant = node.discriminant,
                    .payload_src = if (node.payload) |payload| try self.lowerExpr(instructions, payload) else null,
                } });
                break :blk dst;
            },
            .call => |node| blk: {
                if (node.function_id == null) return error.UnsupportedExecutableFeature;
                if (node.ty.kind == .void) return error.UnsupportedExecutableFeature;
                // Persist `borrow mut` array-element arguments after the call (see the
                // statement-call path); other arguments lower by value unchanged.
                var writebacks = places_impl.WritebackList.init(self.allocator);
                defer writebacks.deinit();
                const arg_regs = try places_impl.lowerDirectCallArgs(self, instructions, node.args, node.function_id.?, &writebacks);
                const dst = self.freshRegister();
                try instructions.append(.{ .call = .{
                    .callee = node.function_id.?,
                    .args = arg_regs,
                    .dst = dst,
                } });
                try places_impl.emitWritebacks(instructions, &writebacks);
                break :blk dst;
            },
            .local => |node| blk: {
                const dst = self.freshRegister();
                const local_id = self.mapLocal(node.local_id);
                if (self.isBoxedLocal(node.local_id)) {
                    const ptr = self.freshRegister();
                    try instructions.append(.{ .load_local = .{ .dst = ptr, .local = local_id } });
                    try instructions.append(.{ .load_indirect = .{ .dst = dst, .ptr = ptr, .ty = try lowerResolvedType(self.program, node.ty) } });
                } else {
                    try instructions.append(.{ .load_local = .{ .dst = dst, .local = local_id, .ownership = lowerOwnershipMode(node.ownership) } });
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
            .array_len => |node| blk: {
                const array_reg = try self.lowerExpr(instructions, node.object);
                const dst = self.freshRegister();
                try instructions.append(.{ .array_len = .{
                    .dst = dst,
                    .array = array_reg,
                } });
                break :blk dst;
            },
            .string_len => |node| blk: {
                const string_reg = try self.lowerExpr(instructions, node.object);
                const dst = self.freshRegister();
                try instructions.append(.{ .string_len = .{
                    .dst = dst,
                    .string = string_reg,
                } });
                break :blk dst;
            },
            .field => |node| blk: {
                // Peephole: `arr[i].f` reading a *scalar* field of an array
                // element. Lowering `arr[i]` the normal way emits a deep-cloning
                // `array_get` (the VM copies the whole element per access) only to
                // read one scalar back out — the dominant per-frame cost in the
                // layout engine, where every node field read cloned a ~40-field
                // LayoutNode. Borrow the element in place instead: the alias is
                // consumed immediately by the field load below, so the array is
                // never mutated while the borrow is live. The native backend
                // already returns the element pointer here, so this removes only a
                // VM-side clone and preserves vm/llvm/hybrid parity. Restricted to
                // a scalar field of a managed-struct element.
                if (node.object.* == .index and
                    model.hir.exprType(node.object.*).kind != .native_state_view)
                {
                    const peek_field_ty = try lowerResolvedType(self.program, node.ty);
                    if (peek_field_ty.kind != .ffi_struct) {
                        const inner = node.object.index;
                        const elem_ty = try lowerResolvedType(self.program, inner.ty);
                        if (elem_ty.kind == .ffi_struct) {
                            const array_reg = try self.lowerExpr(instructions, inner.object);
                            const index_reg = try self.lowerExpr(instructions, inner.index);
                            const elem_reg = self.freshRegister();
                            try instructions.append(.{ .array_get = .{
                                .dst = elem_reg,
                                .array = array_reg,
                                .index = index_reg,
                                .ty = elem_ty,
                                .borrow = true,
                            } });
                            const peek_field_ptr = self.freshRegister();
                            try instructions.append(.{ .field_ptr = .{
                                .dst = peek_field_ptr,
                                .base = elem_reg,
                                .base_type_name = node.container_type_name,
                                .field_index = node.field_index,
                                .field_ty = peek_field_ty,
                            } });
                            const peek_dst = self.freshRegister();
                            try instructions.append(.{ .load_indirect = .{
                                .dst = peek_dst,
                                .ptr = peek_field_ptr,
                                .ty = peek_field_ty,
                            } });
                            break :blk peek_dst;
                        }
                    }
                }
                const object_reg = try self.lowerExpr(instructions, node.object);
                const field_ty = try lowerResolvedType(self.program, node.ty);
                if (model.hir.exprType(node.object.*).kind == .native_state_view) {
                    const dst = self.freshRegister();
                    try instructions.append(.{ .native_state_field_get = .{
                        .dst = dst,
                        .state = object_reg,
                        .field_index = node.field_index,
                        .field_ty = field_ty,
                        .moved = node.moved,
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
                    .moved = node.moved,
                } });
                break :blk dst;
            },
            .binary => |node| blk: {
                const lhs = try self.lowerExpr(instructions, node.lhs);
                switch (node.op) {
                    .logical_and, .logical_or => break :blk try expr_stmt_impl.lowerLogicalBinaryExpr(self, instructions, node, lhs),
                    else => {},
                }

                const rhs = try self.lowerExpr(instructions, node.rhs);
                const dst = self.freshRegister();
                switch (node.op) {
                    .add => {
                        // `+` accepts numerics and (string, string) concatenation.
                        const add_ty = model.hir.exprType(node.lhs.*);
                        if (add_ty.kind != .string) {
                            _ = try lowerExecutableNumericType(self.program, add_ty);
                        }
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
                        const op_ty = model.hir.exprType(node.lhs.*);
                        _ = try lowerExecutableNumericType(self.program, op_ty);
                        try instructions.append(.{ .divide = .{ .dst = dst, .lhs = lhs, .rhs = rhs, .unsigned = isUnsignedIntType(op_ty) } });
                    },
                    .modulo => {
                        const op_ty = model.hir.exprType(node.lhs.*);
                        _ = try lowerExecutableNumericType(self.program, op_ty);
                        try instructions.append(.{ .modulo = .{ .dst = dst, .lhs = lhs, .rhs = rhs, .unsigned = isUnsignedIntType(op_ty) } });
                    },
                    .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => {
                        const op_ty = model.hir.exprType(node.lhs.*);
                        _ = try lowerExecutableIntegerType(self.program, op_ty);
                        const bit_op: ir.BitOp = switch (node.op) {
                            .bit_and => .bit_and,
                            .bit_or => .bit_or,
                            .bit_xor => .bit_xor,
                            .shift_left => .shift_left,
                            .shift_right => .shift_right,
                            else => unreachable,
                        };
                        try instructions.append(.{ .bitwise = .{
                            .dst = dst,
                            .lhs = lhs,
                            .rhs = rhs,
                            .op = bit_op,
                            .unsigned = isUnsignedIntType(op_ty),
                        } });
                    },
                    .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => {
                        const op_ty = model.hir.exprType(node.lhs.*);
                        const operand_vt = try lowerExecutableCompareOperandType(self.program, op_ty, node.op);
                        const normalized = try expr_stmt_impl.normalizeCompareOperands(self, instructions, operand_vt, lhs, rhs);
                        try instructions.append(.{ .compare = .{
                            .dst = dst,
                            .lhs = normalized.lhs,
                            .rhs = normalized.rhs,
                            .op = lowerCompareOp(node.op),
                            .unsigned = isUnsignedIntType(op_ty),
                        } });
                    },
                    .logical_and, .logical_or => unreachable,
                }
                break :blk dst;
            },
            .cast => |node| blk: {
                const src = try self.lowerExpr(instructions, node.operand);
                const target_vt = try lowerResolvedType(self.program, node.ty);
                const dst = self.freshRegister();
                try instructions.append(.{ .convert = .{ .dst = dst, .src = src, .target = target_vt.kind } });
                break :blk dst;
            },
            .conditional => |node| try expr_stmt_impl.lowerConditionalExpr(self, instructions, node),
        };
    }

    pub fn storeValueToLocal(
        self: *Lowerer,
        instructions: *std.array_list.Managed(ir.Instruction),
        local: u32,
        ty: ir.ValueType,
        src: u32,
    ) !void {
        if (self.isBoxedStorageLocal(local)) {
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

    pub fn initializeBoxedLocal(
        self: *Lowerer,
        instructions: *std.array_list.Managed(ir.Instruction),
        local: u32,
        ty: ir.ValueType,
        initial_value: ?u32,
    ) !void {
        const cell_local = try self.freshHiddenLocal(ty);
        const ptr = self.freshRegister();
        try instructions.append(.{ .local_ptr = .{ .dst = ptr, .local = cell_local } });
        try instructions.append(.{ .store_local = .{ .local = local, .src = ptr } });
        if (initial_value) |src| {
            try instructions.append(.{ .store_indirect = .{ .ptr = ptr, .src = src, .ty = ty } });
        }
    }
};

// An integer type is unsigned iff its spelled name begins with 'U' (U8..U64).
// Bare `Int` and I8..I64 are signed. Non-integer types are never "unsigned" here.
fn isUnsignedIntType(ty: model.ResolvedType) bool {
    if (ty.kind != .integer) return false;
    const name = ty.name orelse return false;
    return name.len > 0 and name[0] == 'U';
}

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

test {
    _ = @import("lower_from_hir_tests.zig");
}
