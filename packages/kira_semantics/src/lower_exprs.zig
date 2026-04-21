const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const function_types = @import("function_types.zig");
const calls = @import("lower_exprs_calls.zig");
const members = @import("lower_exprs_members.zig");
const native_state = @import("lower_exprs_native_state.zig");
const types = @import("lower_exprs_types.zig");

pub const lowerStructLiteralExpr = calls.lowerStructLiteralExpr;
pub const lowerTypeConstruction = calls.lowerTypeConstruction;
pub const isTypeConstantField = calls.isTypeConstantField;
pub const resolveTypeConstructionFieldIndex = calls.resolveTypeConstructionFieldIndex;
pub const lowerCallExpr = calls.lowerCallExpr;
pub const lowerNativeStateExpr = native_state.lowerNativeStateExpr;
pub const lowerNativeUserDataExpr = native_state.lowerNativeUserDataExpr;
pub const lowerNativeRecoverExpr = native_state.lowerNativeRecoverExpr;

pub const lowerImplicitSelfFieldExpr = members.lowerImplicitSelfFieldExpr;
pub const lowerImplicitSelfMethodCall = members.lowerImplicitSelfMethodCall;
pub const makeSelfLocalExpr = members.makeSelfLocalExpr;
pub const makeParentViewExpr = members.makeParentViewExpr;
pub const lowerParentQualifiedFieldExpr = members.lowerParentQualifiedFieldExpr;
pub const lowerParentQualifiedMethodCall = members.lowerParentQualifiedMethodCall;
pub const parentQualifierName = members.parentQualifierName;
pub const resolveParentView = members.resolveParentView;
pub const resolveParentViewOrNullNoDiag = members.resolveParentViewOrNullNoDiag;
pub const resolveFieldMemberOrNull = members.resolveFieldMemberOrNull;
pub const resolveFieldMember = members.resolveFieldMember;
pub const resolveMethodMemberOrNull = members.resolveMethodMemberOrNull;
pub const resolveMethodMember = members.resolveMethodMember;
pub const adjustMethodReceiver = members.adjustMethodReceiver;
pub const buildResolvedMethodCallExpr = members.buildResolvedMethodCallExpr;
pub const lowerResolvedMethodCall = members.lowerResolvedMethodCall;
pub const trailingCallbackType = members.trailingCallbackType;
pub const lowerTrailingCallbackValue = members.lowerTrailingCallbackValue;
pub const lowerCallbackBlockValue = members.lowerCallbackBlockValue;
pub const statementBlockFromBuilder = members.statementBlockFromBuilder;
pub const statementFromBuilderItem = members.statementFromBuilderItem;

pub const functionTypeFromResolvedSignature = types.functionTypeFromResolvedSignature;
pub const functionTypeFromHeader = types.functionTypeFromHeader;
pub const isCallableValueExpr = types.isCallableValueExpr;
pub const lowerCallArgument = types.lowerCallArgument;
pub const lowerExpectedValue = types.lowerExpectedValue;
pub const lowerAssignmentTarget = types.lowerAssignmentTarget;
pub const lowerCallbackArgument = types.lowerCallbackArgument;
pub const canPassArgument = types.canPassArgument;
pub const callbackTypesCompatible = types.callbackTypesCompatible;
pub const resolveFieldType = types.resolveFieldType;
pub const resolveFieldContainerType = types.resolveFieldContainerType;
pub const isNullPointerLiteral = types.isNullPointerLiteral;
pub const exprSpan = types.exprSpan;
pub const qualifiedLeaf = types.qualifiedLeaf;
pub const resolveSyntaxExprType = types.resolveSyntaxExprType;
pub const resolveLoweredValueType = types.resolveLoweredValueType;
pub const resolveValueType = types.resolveValueType;
pub const syntaxExprMatchesExplicitType = types.syntaxExprMatchesExplicitType;
pub const resolveFunctionReturnType = types.resolveFunctionReturnType;
pub const resolveBinaryType = types.resolveBinaryType;
pub const resolveConditionalType = types.resolveConditionalType;
pub const resolveArrayLiteralType = types.resolveArrayLiteralType;
pub const resolveSyntaxArrayLiteralType = types.resolveSyntaxArrayLiteralType;
pub const resolveArrayElementType = types.resolveArrayElementType;
pub const flattenCalleeName = types.flattenCalleeName;
pub const flattenMemberExpr = types.flattenMemberExpr;
pub const flattenMemberExprPath = types.flattenMemberExprPath;

pub fn lowerBlockStatements(
    ctx: *shared.Context,
    block: syntax.ast.Block,
    imports: []const model.Import,
    scope: *model.Scope,
    locals: *std.array_list.Managed(model.LocalSymbol),
    next_local_id: *u32,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
    loop_depth: usize,
) anyerror![]model.Statement {
    var statements = std.array_list.Managed(model.Statement).init(ctx.allocator);
    for (block.statements) |statement| {
        try statements.append(try lowerStatement(ctx, statement, imports, scope, locals, next_local_id, function_headers, loop_depth));
    }
    return statements.toOwnedSlice();
}

pub fn lowerStatement(
    ctx: *shared.Context,
    statement: syntax.ast.Statement,
    imports: []const model.Import,
    scope: *model.Scope,
    locals: *std.array_list.Managed(model.LocalSymbol),
    next_local_id: *u32,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
    loop_depth: usize,
) anyerror!model.Statement {
    return switch (statement) {
        .let_stmt => |node| blk: {
            try shared.validateAnnotationPlacement(ctx, node.annotations, .field_decl, null);
            const declaration = try types.lowerLocalDeclaration(ctx, node, imports, scope, function_headers);
            const local_id = next_local_id.*;
            next_local_id.* += 1;
            try scope.put(ctx.allocator, node.name, .{
                .id = local_id,
                .ty = declaration.ty,
                .storage = @enumFromInt(@intFromEnum(node.storage)),
                .initialized = declaration.initialized,
                .decl_span = node.span,
            });
            try locals.append(.{
                .id = local_id,
                .name = try ctx.allocator.dupe(u8, node.name),
                .ty = declaration.ty,
                .span = node.span,
            });
            break :blk .{ .let_stmt = .{
                .local_id = local_id,
                .ty = declaration.ty,
                .explicit_type = node.type_expr != null,
                .value = declaration.value,
                .span = node.span,
            } };
        },
        .assign_stmt => |node| blk: {
            const target = try lowerAssignmentTarget(ctx, node.target, imports, scope, function_headers);
            const value = try lowerExpectedValue(ctx, node.value, model.hir.exprType(target.*), imports, scope, function_headers, node.span);
            try markInitializedFromAssignment(scope, target.*);
            break :blk .{ .assign_stmt = .{
                .target = target,
                .value = value,
                .span = node.span,
            } };
        },
        .expr_stmt => |node| .{ .expr_stmt = .{
            .expr = try lowerExpr(ctx, node.expr, imports, scope, function_headers),
            .span = node.span,
        } },
        .if_stmt => |node| blk: {
            const condition = try lowerExpr(ctx, node.condition, imports, scope, function_headers);
            var then_scope = try cloneScope(ctx.allocator, scope.*);
            defer then_scope.deinit(ctx.allocator);
            const then_body = try lowerBlockStatements(ctx, node.then_block, imports, &then_scope, locals, next_local_id, function_headers, loop_depth);

            var else_scope: ?model.Scope = null;
            defer if (else_scope) |*value| value.deinit(ctx.allocator);
            const else_body = if (node.else_block) |else_block| else_body: {
                var branch_scope = try cloneScope(ctx.allocator, scope.*);
                const lowered_else = try lowerBlockStatements(ctx, else_block, imports, &branch_scope, locals, next_local_id, function_headers, loop_depth);
                else_scope = branch_scope;
                break :else_body lowered_else;
            } else null;

            mergeIfInitialization(scope, then_scope, else_scope);
            break :blk .{ .if_stmt = .{
                .condition = condition,
                .then_body = then_body,
                .else_body = else_body,
                .span = node.span,
            } };
        },
        .for_stmt => |node| blk: {
            const iterator = try lowerExpr(ctx, node.iterator, imports, scope, function_headers);
            const binding_ty = try resolveArrayElementType(ctx, model.hir.exprType(iterator.*), node.span);
            if (iterator.* == .array and iterator.array.elements.len == 0 and binding_ty.kind == .unknown) {
                var empty_body_scope = try cloneScope(ctx.allocator, scope.*);
                defer empty_body_scope.deinit(ctx.allocator);
                break :blk .{ .for_stmt = .{
                    .binding_name = try ctx.allocator.dupe(u8, node.binding_name),
                    .binding_local_id = 0,
                    .binding_ty = binding_ty,
                    .iterator = iterator,
                    .body = try lowerBlockStatements(ctx, node.body, imports, &empty_body_scope, locals, next_local_id, function_headers, loop_depth + 1),
                    .span = node.span,
                } };
            }
            const local_id = next_local_id.*;
            next_local_id.* += 1;

            var body_scope = try cloneScope(ctx.allocator, scope.*);
            defer body_scope.deinit(ctx.allocator);
            try body_scope.put(ctx.allocator, node.binding_name, .{
                .id = local_id,
                .ty = binding_ty,
                .storage = .immutable,
                .initialized = true,
                .decl_span = node.span,
            });
            try locals.append(.{
                .id = local_id,
                .name = try ctx.allocator.dupe(u8, node.binding_name),
                .ty = binding_ty,
                .span = node.span,
            });
            break :blk .{ .for_stmt = .{
                .binding_name = try ctx.allocator.dupe(u8, node.binding_name),
                .binding_local_id = local_id,
                .binding_ty = binding_ty,
                .iterator = iterator,
                .body = try lowerBlockStatements(ctx, node.body, imports, &body_scope, locals, next_local_id, function_headers, loop_depth + 1),
                .span = node.span,
            } };
        },
        .while_stmt => |node| blk: {
            var body_scope = try cloneScope(ctx.allocator, scope.*);
            defer body_scope.deinit(ctx.allocator);
            break :blk .{ .while_stmt = .{
                .condition = try lowerExpr(ctx, node.condition, imports, scope, function_headers),
                .body = try lowerBlockStatements(ctx, node.body, imports, &body_scope, locals, next_local_id, function_headers, loop_depth + 1),
                .span = node.span,
            } };
        },
        .break_stmt => |node| blk: {
            if (loop_depth == 0) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM075",
                    .title = "break requires a loop",
                    .message = "`break` can only appear inside a `for` or `while` loop.",
                    .labels = &.{diagnostics.primaryLabel(node.span, "break appears outside a loop")},
                    .help = "Move this `break` into a loop body or remove it.",
                });
                return error.DiagnosticsEmitted;
            }
            break :blk .{ .break_stmt = .{ .span = node.span } };
        },
        .continue_stmt => |node| blk: {
            if (loop_depth == 0) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM076",
                    .title = "continue requires a loop",
                    .message = "`continue` can only appear inside a `for` or `while` loop.",
                    .labels = &.{diagnostics.primaryLabel(node.span, "continue appears outside a loop")},
                    .help = "Move this `continue` into a loop body or remove it.",
                });
                return error.DiagnosticsEmitted;
            }
            break :blk .{ .continue_stmt = .{ .span = node.span } };
        },
        .switch_stmt => |node| blk: {
            const subject = try lowerExpr(ctx, node.subject, imports, scope, function_headers);
            var cases = std.array_list.Managed(model.SwitchCase).init(ctx.allocator);
            var case_scopes = std.array_list.Managed(model.Scope).init(ctx.allocator);
            defer {
                for (case_scopes.items) |*case_scope| case_scope.deinit(ctx.allocator);
                case_scopes.deinit();
            }
            for (node.cases) |case_node| {
                var case_scope = try cloneScope(ctx.allocator, scope.*);
                try cases.append(.{
                    .pattern = try lowerExpr(ctx, case_node.pattern, imports, scope, function_headers),
                    .body = try lowerBlockStatements(ctx, case_node.body, imports, &case_scope, locals, next_local_id, function_headers, loop_depth),
                    .span = case_node.span,
                });
                try case_scopes.append(case_scope);
            }
            var default_scope: ?model.Scope = null;
            defer if (default_scope) |*value| value.deinit(ctx.allocator);
            const default_body = if (node.default_block) |default_block| default_body: {
                var branch_scope = try cloneScope(ctx.allocator, scope.*);
                const lowered_default = try lowerBlockStatements(ctx, default_block, imports, &branch_scope, locals, next_local_id, function_headers, loop_depth);
                default_scope = branch_scope;
                break :default_body lowered_default;
            } else null;
            mergeSwitchInitialization(scope, case_scopes.items, default_scope);
            break :blk .{ .switch_stmt = .{
                .subject = subject,
                .cases = try cases.toOwnedSlice(),
                .default_body = default_body,
                .span = node.span,
            } };
        },
        .return_stmt => |node| .{ .return_stmt = .{
            .value = if (node.value) |expr| try lowerExpr(ctx, expr, imports, scope, function_headers) else null,
            .span = node.span,
        } },
    };
}

fn markInitializedFromAssignment(scope: *model.Scope, target: model.Expr) !void {
    switch (target) {
        .local => |node| {
            var iterator = scope.entries.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.id != node.local_id) continue;
                entry.value_ptr.initialized = true;
                return;
            }
        },
        else => {},
    }
}

fn cloneScope(allocator: std.mem.Allocator, scope: model.Scope) !model.Scope {
    var cloned = model.Scope{};
    var iterator = scope.entries.iterator();
    while (iterator.next()) |entry| {
        try cloned.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
    return cloned;
}

fn mergeIfInitialization(scope: *model.Scope, then_scope: model.Scope, else_scope: ?model.Scope) void {
    const resolved_else = else_scope orelse return;
    var iterator = scope.entries.iterator();
    while (iterator.next()) |entry| {
        const then_binding = then_scope.get(entry.key_ptr.*) orelse continue;
        const else_binding = resolved_else.get(entry.key_ptr.*) orelse continue;
        if (then_binding.id != entry.value_ptr.id or else_binding.id != entry.value_ptr.id) continue;
        entry.value_ptr.initialized = entry.value_ptr.initialized or (then_binding.initialized and else_binding.initialized);
    }
}

fn mergeSwitchInitialization(scope: *model.Scope, case_scopes: []const model.Scope, default_scope: ?model.Scope) void {
    const resolved_default = default_scope orelse return;
    var iterator = scope.entries.iterator();
    while (iterator.next()) |entry| {
        const default_binding = resolved_default.get(entry.key_ptr.*) orelse continue;
        if (default_binding.id != entry.value_ptr.id or !default_binding.initialized) continue;

        var initialized_in_all_cases = true;
        for (case_scopes) |case_scope| {
            const case_binding = case_scope.get(entry.key_ptr.*) orelse {
                initialized_in_all_cases = false;
                break;
            };
            if (case_binding.id != entry.value_ptr.id or !case_binding.initialized) {
                initialized_in_all_cases = false;
                break;
            }
        }
        if (initialized_in_all_cases) entry.value_ptr.initialized = true;
    }
}

fn emitUnknownLocalName(ctx: *shared.Context, name: []const u8, span: source_pkg.Span) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM012",
        .title = "unknown local name",
        .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not find a local binding named '{s}'.", .{name}),
        .labels = &.{diagnostics.primaryLabel(span, "unknown local name")},
        .help = "Declare the value before using it, or qualify imported names.",
    });
}

fn emitUninitializedLocalUse(
    ctx: *shared.Context,
    name: []const u8,
    use_span: source_pkg.Span,
    decl_span: source_pkg.Span,
) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM086",
        .title = "local is not initialized",
        .message = try std.fmt.allocPrint(ctx.allocator, "The local declaration '{s}' does not have a value yet.", .{name}),
        .labels = &.{
            diagnostics.primaryLabel(use_span, "local is read before it has been initialized"),
            diagnostics.secondaryLabel(decl_span, "declaration appears here"),
        },
        .help = "Assign to the local before reading it, or add an initializer expression to the declaration.",
    });
}

pub fn lowerBuilderBlock(
    ctx: *shared.Context,
    builder: syntax.ast.BuilderBlock,
    imports: []const model.Import,
    scope: ?*model.Scope,
) anyerror!model.BuilderBlock {
    var empty_scope = model.Scope{};
    defer empty_scope.deinit(ctx.allocator);
    const active_scope = if (scope) |actual| actual else &empty_scope;

    var items = std.array_list.Managed(model.BuilderItem).init(ctx.allocator);
    for (builder.items) |item| {
        switch (item) {
            .expr => |value| try items.append(.{ .expr = .{
                .expr = try lowerExpr(ctx, value.expr, imports, active_scope, null),
                .span = value.span,
            } }),
            .if_item => |value| try items.append(.{ .if_item = .{
                .condition = try lowerExpr(ctx, value.condition, imports, active_scope, null),
                .then_block = try lowerBuilderBlock(ctx, value.then_block, imports, active_scope),
                .else_block = if (value.else_block) |else_block| try lowerBuilderBlock(ctx, else_block, imports, active_scope) else null,
                .span = value.span,
            } }),
            .for_item => |value| try items.append(.{ .for_item = .{
                .binding_name = try ctx.allocator.dupe(u8, value.binding_name),
                .iterator = try lowerExpr(ctx, value.iterator, imports, active_scope, null),
                .body = try lowerBuilderBlock(ctx, value.body, imports, active_scope),
                .span = value.span,
            } }),
            .switch_item => |value| blk: {
                var cases = std.array_list.Managed(model.BuilderSwitchCase).init(ctx.allocator);
                for (value.cases) |case_node| {
                    try cases.append(.{
                        .pattern = try lowerExpr(ctx, case_node.pattern, imports, active_scope, null),
                        .body = try lowerBuilderBlock(ctx, case_node.body, imports, active_scope),
                        .span = case_node.span,
                    });
                }
                try items.append(.{ .switch_item = .{
                    .subject = try lowerExpr(ctx, value.subject, imports, active_scope, null),
                    .cases = try cases.toOwnedSlice(),
                    .default_block = if (value.default_block) |default_block| try lowerBuilderBlock(ctx, default_block, imports, active_scope) else null,
                    .span = value.span,
                } });
                break :blk;
            },
        }
    }

    return .{
        .items = try items.toOwnedSlice(),
        .span = builder.span,
    };
}

pub fn lowerExpr(
    ctx: *shared.Context,
    expr: *syntax.ast.Expr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) anyerror!*model.Expr {
    const lowered = try ctx.allocator.create(model.Expr);
    switch (expr.*) {
        .integer => |node| lowered.* = .{ .integer = .{ .value = node.value, .span = node.span } },
        .float => |node| lowered.* = .{ .float = .{ .value = node.value, .span = node.span } },
        .string => |node| lowered.* = .{ .string = .{ .value = node.value, .span = node.span } },
        .bool => |node| lowered.* = .{ .boolean = .{ .value = node.value, .span = node.span } },
        .array => |node| {
            var elements = std.array_list.Managed(*model.Expr).init(ctx.allocator);
            for (node.elements) |element| try elements.append(try lowerExpr(ctx, element, imports, scope, function_headers));
            const array_ty = try resolveArrayLiteralType(ctx, elements.items, node.span);
            lowered.* = .{ .array = .{
                .elements = try elements.toOwnedSlice(),
                .ty = array_ty,
                .span = node.span,
            } };
        },
        .callback => |node| {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM084",
                .title = "callback literal needs an explicit function type",
                .message = "Standalone callback literals need an expected function type from a declaration, field, argument, or return position.",
                .labels = &.{diagnostics.primaryLabel(node.span, "callback literal has no expected function type")},
                .help = "Add an explicit function type such as `let cb: (Int) -> Void = { value in ... }`.",
            });
            return error.DiagnosticsEmitted;
        },
        .struct_literal => |node| {
            lowered.* = try lowerStructLiteralExpr(ctx, node, imports, scope, function_headers);
        },
        .native_state => |node| {
            lowered.* = try lowerNativeStateExpr(ctx, node, imports, scope, function_headers);
        },
        .native_user_data => |node| {
            lowered.* = try lowerNativeUserDataExpr(ctx, node, imports, scope, function_headers);
        },
        .native_recover => |node| {
            lowered.* = try lowerNativeRecoverExpr(ctx, node, imports, scope, function_headers);
        },
        .identifier => |node| {
            const name = node.name.segments[0].text;
            if (scope.get(name)) |binding| {
                if (!binding.initialized) {
                    try emitUninitializedLocalUse(ctx, name, node.span, binding.decl_span);
                    return error.DiagnosticsEmitted;
                }
                lowered.* = .{ .local = .{
                    .local_id = binding.id,
                    .name = try ctx.allocator.dupe(u8, name),
                    .ty = binding.ty,
                    .storage = binding.storage,
                    .span = node.span,
                } };
            } else if (shared.isImportedRoot(name, imports)) {
                lowered.* = .{ .namespace_ref = .{
                    .root = try ctx.allocator.dupe(u8, name),
                    .path = try ctx.allocator.dupe(u8, name),
                    .span = node.span,
                } };
            } else if (function_headers) |headers| {
                if (headers.get(name)) |header| {
                    lowered.* = .{ .function_ref = .{
                        .representation = .callable_value,
                        .function_id = header.id,
                        .name = try ctx.allocator.dupe(u8, name),
                        .ty = try functionTypeFromHeader(ctx.allocator, header),
                        .span = node.span,
                    } };
                } else if (ctx.imported_globals.findFunction(name)) |function_decl| {
                    lowered.* = .{ .function_ref = .{
                        .representation = .callable_value,
                        .function_id = 0,
                        .name = try ctx.allocator.dupe(u8, function_decl.name),
                        .ty = try functionTypeFromResolvedSignature(ctx.allocator, function_decl.params, function_decl.return_type),
                        .span = node.span,
                    } };
                } else if (try lowerImplicitSelfFieldExpr(ctx, scope, name, node.span)) |field_expr| {
                    lowered.* = field_expr;
                } else {
                    try emitUnknownLocalName(ctx, name, node.span);
                    return error.DiagnosticsEmitted;
                }
            } else if (try lowerImplicitSelfFieldExpr(ctx, scope, name, node.span)) |field_expr| {
                lowered.* = field_expr;
            } else {
                try emitUnknownLocalName(ctx, name, node.span);
                return error.DiagnosticsEmitted;
            }
        },
        .member => |node| {
            if (try lowerParentQualifiedFieldExpr(ctx, node, imports, scope, function_headers)) |field_expr| {
                lowered.* = field_expr;
                return lowered;
            }
            const flattened = try flattenMemberExpr(ctx.allocator, expr);
            const root_is_type = (ctx.type_headers != null and (ctx.type_headers.?.get(flattened.root) != null)) or
                ctx.imported_globals.findType(flattened.root) != null;
            if ((shared.isImportedRoot(flattened.root, imports) or root_is_type) and scope.get(flattened.root) == null) {
                if (function_headers) |headers| {
                    if (headers.get(flattened.path)) |header| {
                        lowered.* = .{ .function_ref = .{
                            .representation = .callable_value,
                            .function_id = header.id,
                            .name = try ctx.allocator.dupe(u8, flattened.path),
                            .ty = try functionTypeFromHeader(ctx.allocator, header),
                            .span = node.span,
                        } };
                        return lowered;
                    }
                }
                // Try to resolve the type of a constant field access like TypeName.fieldName
                var ns_ty: model.ResolvedType = .{ .kind = .unknown };
                const root_type: model.ResolvedType = .{ .kind = .named, .name = flattened.root };
                if (shared.namedTypeHeader(ctx, root_type)) |header| {
                    for (header.fields) |field| {
                        if (std.mem.eql(u8, field.name, node.member)) {
                            ns_ty = field.ty;
                            break;
                        }
                    }
                }
                lowered.* = .{ .namespace_ref = .{
                    .root = flattened.root,
                    .path = flattened.path,
                    .ty = ns_ty,
                    .span = node.span,
                } };
                return lowered;
            }
            if (scope.get(flattened.root) == null) {
                if (node.object.* == .identifier) {
                    if (try lowerImplicitSelfFieldExpr(ctx, scope, flattened.root, exprSpan(node.object.*))) |object_value| {
                        const object = try ctx.allocator.create(model.Expr);
                        object.* = object_value;
                        const object_type = resolveFieldContainerType(ctx, model.hir.exprType(object.*)) orelse return error.DiagnosticsEmitted;
                        const resolved_field = try resolveFieldMember(ctx, model.hir.exprType(object.*), node.member, node.span);
                        lowered.* = .{ .field = .{
                            .object = object,
                            .container_type_name = try ctx.allocator.dupe(u8, object_type.name orelse return error.DiagnosticsEmitted),
                            .field_name = try ctx.allocator.dupe(u8, node.member),
                            .field_index = resolved_field.slot_index,
                            .ty = resolved_field.ty,
                            .storage = resolved_field.storage,
                            .span = node.span,
                        } };
                        return lowered;
                    }
                }
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM027",
                    .title = "invalid namespaced reference",
                    .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not resolve the namespace root '{s}'.", .{flattened.root}),
                    .labels = &.{
                        diagnostics.primaryLabel(node.span, "unknown namespace root"),
                    },
                    .help = "Import the module first or use a local name instead.",
                });
                return error.DiagnosticsEmitted;
            }

            const object = try lowerExpr(ctx, node.object, imports, scope, function_headers);
            const object_type = resolveFieldContainerType(ctx, model.hir.exprType(object.*)) orelse return error.DiagnosticsEmitted;
            const resolved_field = try resolveFieldMember(ctx, model.hir.exprType(object.*), node.member, node.span);
            lowered.* = .{ .field = .{
                .object = object,
                .container_type_name = try ctx.allocator.dupe(u8, object_type.name orelse return error.DiagnosticsEmitted),
                .field_name = try ctx.allocator.dupe(u8, node.member),
                .field_index = resolved_field.slot_index,
                .ty = resolved_field.ty,
                .storage = resolved_field.storage,
                .span = node.span,
            } };
        },
        .index => |node| {
            const object = try lowerExpr(ctx, node.object, imports, scope, function_headers);
            const index = try lowerExpr(ctx, node.index, imports, scope, function_headers);
            const index_ty = model.hir.exprType(index.*);
            if (index_ty.kind != .integer) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM077",
                    .title = "array index must be an integer",
                    .message = "Index expressions currently require an integer index.",
                    .labels = &.{diagnostics.primaryLabel(exprSpan(node.index.*), "index is not an integer")},
                    .help = "Use an `Int` or fixed-width integer value inside `[...]`.",
                });
                return error.DiagnosticsEmitted;
            }
            const element_ty = try resolveArrayElementType(ctx, model.hir.exprType(object.*), node.span);
            lowered.* = .{ .index = .{
                .object = object,
                .index = index,
                .ty = element_ty,
                .span = node.span,
            } };
        },
        .unary => |node| {
            const operand = try lowerExpr(ctx, node.operand, imports, scope, function_headers);
            const operand_type = model.hir.exprType(operand.*);
            lowered.* = .{ .unary = .{
                .op = @enumFromInt(@intFromEnum(node.op)),
                .operand = operand,
                .ty = switch (node.op) {
                    .negate => operand_type,
                    .not => .{ .kind = .boolean },
                },
                .span = node.span,
            } };
        },
        .binary => |node| {
            const lhs = try lowerExpr(ctx, node.lhs, imports, scope, function_headers);
            const rhs = try lowerExpr(ctx, node.rhs, imports, scope, function_headers);
            const ty = try resolveBinaryType(ctx, node.op, lhs, rhs, node.span);
            lowered.* = .{ .binary = .{
                .op = switch (node.op) {
                    .add => .add,
                    .subtract => .subtract,
                    .multiply => .multiply,
                    .divide => .divide,
                    .modulo => .modulo,
                    .equal => .equal,
                    .not_equal => .not_equal,
                    .less => .less,
                    .less_equal => .less_equal,
                    .greater => .greater,
                    .greater_equal => .greater_equal,
                    .logical_and => .logical_and,
                    .logical_or => .logical_or,
                },
                .lhs = lhs,
                .rhs = rhs,
                .ty = ty,
                .span = node.span,
            } };
        },
        .conditional => |node| {
            const condition = try lowerExpr(ctx, node.condition, imports, scope, function_headers);
            if (model.hir.exprType(condition.*).kind != .boolean) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM049",
                    .title = "conditional expression requires a boolean condition",
                    .message = "The condition in a `? :` expression must resolve to `Bool`.",
                    .labels = &.{
                        diagnostics.primaryLabel(exprSpan(node.condition.*), "condition is not a boolean"),
                    },
                    .help = "Make the condition resolve to `Bool` before using a conditional expression.",
                });
                return error.DiagnosticsEmitted;
            }

            const then_expr = try lowerExpr(ctx, node.then_expr, imports, scope, function_headers);
            const else_expr = try lowerExpr(ctx, node.else_expr, imports, scope, function_headers);
            const ty = try resolveConditionalType(ctx, model.hir.exprType(then_expr.*), model.hir.exprType(else_expr.*), node.span);
            lowered.* = .{ .conditional = .{
                .condition = condition,
                .then_expr = then_expr,
                .else_expr = else_expr,
                .ty = ty,
                .span = node.span,
            } };
        },
        .call => |node| try lowerCallExpr(ctx, lowered, node, imports, scope, function_headers),
    }
    return lowered;
}
