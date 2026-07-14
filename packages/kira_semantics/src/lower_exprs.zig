const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const function_types = @import("function_types.zig");
const calls = @import("lower_exprs_calls.zig");
const call_dispatch = @import("lower_exprs_call_dispatch.zig");
const builder = @import("lower_exprs_builder.zig");
const members = @import("lower_exprs_members.zig");
const native_state = @import("lower_exprs_native_state.zig");
const matches = @import("lower_stmts_match.zig");
const attempts = @import("lower_stmts_attempt.zig");
const scope_flow = @import("lower_exprs_scope_flow.zig");
const types = @import("lower_exprs_types.zig");
const enum_variants = @import("lower_exprs_enum_variants.zig");
const implicit_members = @import("lower_exprs_implicit_members.zig");
const async_spine = @import("lower_exprs_async.zig");

pub const lowerStructLiteralExpr = calls.lowerStructLiteralExpr;
pub const lowerTypeConstruction = calls.lowerTypeConstruction;
pub const isTypeConstantField = calls.isTypeConstantField;
pub const resolveTypeConstructionFieldIndex = calls.resolveTypeConstructionFieldIndex;
pub const lowerCallExpr = call_dispatch.lowerCallExpr;
pub const lowerNativeStateExpr = native_state.lowerNativeStateExpr;
pub const lowerNativeUserDataExpr = native_state.lowerNativeUserDataExpr;
pub const lowerNativeRecoverExpr = native_state.lowerNativeRecoverExpr;
pub const lowerNativeStateFreeExpr = native_state.lowerNativeStateFreeExpr;
pub const lowerMatchStatement = matches.lowerMatchStatement;
pub const rejectOutstandingMovedFields = types.rejectOutstandingMovedFields;

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
pub const buildDispatchedMethodCallExpr = members.buildDispatchedMethodCallExpr;
pub const lowerResolvedMethodCall = members.lowerResolvedMethodCall;
pub const lowerVirtualMethodCall = members.lowerVirtualMethodCall;
pub const trailingCallbackType = members.trailingCallbackType;
pub const lowerTrailingCallbackValue = members.lowerTrailingCallbackValue;
pub const lowerCallbackBlockValue = members.lowerCallbackBlockValue;
pub const statementBlockFromBuilder = members.statementBlockFromBuilder;
pub const statementFromBuilderItem = members.statementFromBuilderItem;

pub const functionTypeFromResolvedSignature = types.functionTypeFromResolvedSignature;
pub const functionTypeFromHeader = types.functionTypeFromHeader;
pub const isCallableValueExpr = types.isCallableValueExpr;
pub const lowerCallArgument = types.lowerCallArgument;
pub const lowerOwnershipExpr = types.lowerOwnershipExpr;
pub const lowerExpectedValue = types.lowerExpectedValue;
pub const lowerAssignmentTarget = types.lowerAssignmentTarget;
pub const commitAssignmentTarget = types.commitAssignmentTarget;
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
pub const lowerBuilderBlock = builder.lowerBuilderBlock;
const emitUseAfterMove = types.emitUseAfterMove;
pub const lowerEnumVariantExprExpected = enum_variants.lowerEnumVariantExprExpected;
const core = @import("lower_exprs_core.zig");
pub const lowerExpr = core.lowerExpr;

pub fn tryLowerCountMemberExpr(object: *model.Expr, member_name: []const u8, span: source_pkg.Span) ?model.Expr {
    if (!std.mem.eql(u8, member_name, "count")) return null;
    return switch (model.hir.exprType(object.*).kind) {
        .array => .{ .array_len = .{
            .object = object,
            .span = span,
        } },
        .string => .{ .string_len = .{
            .object = object,
            .span = span,
        } },
        else => null,
    };
}

pub fn emitMemberAccessRequiresStructuredType(
    ctx: *shared.Context,
    span: source_pkg.Span,
) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM047",
        .title = "field access requires a structured type",
        .message = "This member access does not resolve to a Kira or FFI struct value.",
        .labels = &.{
            diagnostics.primaryLabel(span, "field access target is not a struct or pointer-to-struct"),
        },
        .help = "Access fields on a named struct value or a pointer-to-struct type.",
    });
}

pub fn lowerBlockStatements(
    ctx: *shared.Context,
    block: syntax.ast.Block,
    imports: []const model.Import,
    scope: *model.Scope,
    locals: *std.array_list.Managed(model.LocalSymbol),
    next_local_id: *u32,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
    loop_depth: usize,
    expected_return_type: model.ResolvedType,
) anyerror![]model.Statement {
    var statements = std.array_list.Managed(model.Statement).init(ctx.allocator);
    for (block.statements) |statement| {
        // `attempt` desugars to one or more `match` statements, so it is expanded here where
        // multiple lowered statements can be appended (HIR has no block statement).
        if (statement == .attempt_stmt) {
            const lowered = try attempts.lowerAttempt(ctx, statement.attempt_stmt, imports, scope, locals, next_local_id, function_headers, loop_depth, expected_return_type);
            try statements.appendSlice(lowered);
            continue;
        }
        try statements.append(try lowerStatement(ctx, statement, imports, scope, locals, next_local_id, function_headers, loop_depth, expected_return_type));
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
    expected_return_type: model.ResolvedType,
) anyerror!model.Statement {
    return switch (statement) {
        .let_stmt => |node| blk: {
            try shared.validateAnnotationPlacement(ctx, node.annotations, .field_decl, null);
            const declaration = try types.lowerLocalDeclaration(ctx, node, imports, scope, function_headers);
            const local_id = next_local_id.*;
            next_local_id.* += 1;
            // Rust reborrow: `var r = t` where `t` is a `borrow mut` (`&mut`) rebinds
            // `r` as a mutable alias of the same storage rather than copying it — the
            // engine's `var result = tree` pattern. Restricted to `borrow mut`: a shared
            // `borrow` (`&`) keeps value-copy semantics (you cannot mutate through `&`),
            // which existing code relies on to get an independent, mutable, owned copy.
            const is_reborrow = if (declaration.value) |value| switch (value.*) {
                .local => |local_read| if (scope.get(local_read.name)) |source|
                    source.ownership == .borrow_mut
                else
                    false,
                else => false,
            } else false;
            const local_ownership: model.OwnershipMode = if (is_reborrow) .borrow_mut else .owned;
            // A binding initialized from `Task { ... }` is a task handle: only
            // `.await` / `.requestCancel()` / `.detach()` may read it (KSEM158).
            const is_task_handle = if (node.value) |init_expr|
                init_expr.* == .call and async_spine.isTaskSpawn(init_expr.call)
            else
                false;
            try scope.put(ctx.allocator, node.name, .{
                .id = local_id,
                .ty = declaration.ty,
                .storage = @enumFromInt(@intFromEnum(node.storage)),
                .ownership = local_ownership,
                .initialized = declaration.initialized,
                .is_task_handle = is_task_handle,
                .decl_span = node.span,
            });
            try locals.append(.{
                .id = local_id,
                .name = try ctx.allocator.dupe(u8, node.name),
                .ty = declaration.ty,
                .ownership = local_ownership,
                .span = node.span,
            });
            break :blk .{ .let_stmt = .{
                .local_id = local_id,
                .ty = declaration.ty,
                .explicit_type = node.type_expr != null,
                .value = declaration.value,
                .is_reborrow = is_reborrow,
                .span = node.span,
            } };
        },
        .assign_stmt => |node| blk: {
            const target = try lowerAssignmentTarget(ctx, node.target, imports, scope, function_headers);
            const value = try lowerExpectedValue(ctx, node.value, model.hir.exprType(target.*), imports, scope, function_headers, node.span);
            commitAssignmentTarget(scope, node.target);
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
            var then_scope = try scope_flow.cloneScope(ctx.allocator, scope.*);
            defer then_scope.deinit(ctx.allocator);
            const then_body = try lowerBlockStatements(ctx, node.then_block, imports, &then_scope, locals, next_local_id, function_headers, loop_depth, expected_return_type);

            var else_scope: ?model.Scope = null;
            defer if (else_scope) |*value| value.deinit(ctx.allocator);
            const else_body = if (node.else_block) |else_block| else_body: {
                var branch_scope = try scope_flow.cloneScope(ctx.allocator, scope.*);
                const lowered_else = try lowerBlockStatements(ctx, else_block, imports, &branch_scope, locals, next_local_id, function_headers, loop_depth, expected_return_type);
                else_scope = branch_scope;
                break :else_body lowered_else;
            } else null;

            try scope_flow.mergeIfState(ctx.allocator, scope, then_scope, else_scope);
            break :blk .{ .if_stmt = .{
                .condition = condition,
                .then_body = then_body,
                .else_body = else_body,
                .span = node.span,
            } };
        },
        .for_stmt => |node| blk: {
            if (node.range_end) |range_end_ast| {
                // Numeric range `for i in start..end`: bind `i` to each integer in
                // [start, end). Both bounds must be integers; the loop variable is
                // an immutable `Int`, lowered to the same counter loop as array
                // iteration (minus the element fetch).
                const start_expr = try lowerExpr(ctx, node.iterator, imports, scope, function_headers);
                const end_expr = try lowerExpr(ctx, range_end_ast, imports, scope, function_headers);
                if (model.hir.exprType(start_expr.*).kind != .integer or model.hir.exprType(end_expr.*).kind != .integer) {
                    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM119",
                        .title = "range bounds must be integers",
                        .message = "A `for i in start..end` loop requires integer `start` and `end` bounds.",
                        .labels = &.{diagnostics.primaryLabel(node.span, "range bound is not an integer")},
                        .help = "Use integer expressions for both bounds, e.g. `for i in 0..count`.",
                    });
                    return error.DiagnosticsEmitted;
                }
                const binding_ty: model.ResolvedType = .{ .kind = .integer };
                const local_id = next_local_id.*;
                next_local_id.* += 1;

                var body_scope = try scope_flow.cloneScope(ctx.allocator, scope.*);
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
                    .ownership = .owned,
                    .span = node.span,
                });
                const lowered: model.Statement = .{ .for_stmt = .{
                    .binding_name = try ctx.allocator.dupe(u8, node.binding_name),
                    .binding_local_id = local_id,
                    .binding_ty = binding_ty,
                    .iterator = start_expr,
                    .range_end = end_expr,
                    .body = try lowerBlockStatements(ctx, node.body, imports, &body_scope, locals, next_local_id, function_headers, loop_depth + 1, expected_return_type),
                    .span = node.span,
                } };
                try scope_flow.mergeLoopState(ctx.allocator, scope, body_scope);
                break :blk lowered;
            }
            const iterator = try lowerExpr(ctx, node.iterator, imports, scope, function_headers);
            const binding_ty = try resolveArrayElementType(ctx, model.hir.exprType(iterator.*), node.span);
            const binding_ownership: model.OwnershipMode = if (shared.containsConstructAnyStorage(ctx, binding_ty)) .borrow_read else .owned;
            if (iterator.* == .array and iterator.array.elements.len == 0 and binding_ty.kind == .unknown) {
                var empty_body_scope = try scope_flow.cloneScope(ctx.allocator, scope.*);
                defer empty_body_scope.deinit(ctx.allocator);
                break :blk .{ .for_stmt = .{
                    .binding_name = try ctx.allocator.dupe(u8, node.binding_name),
                    .binding_local_id = 0,
                    .binding_ty = binding_ty,
                    .iterator = iterator,
                    .body = try lowerBlockStatements(ctx, node.body, imports, &empty_body_scope, locals, next_local_id, function_headers, loop_depth + 1, expected_return_type),
                    .span = node.span,
                } };
            }
            const local_id = next_local_id.*;
            next_local_id.* += 1;

            var body_scope = try scope_flow.cloneScope(ctx.allocator, scope.*);
            defer body_scope.deinit(ctx.allocator);
            try body_scope.put(ctx.allocator, node.binding_name, .{
                .id = local_id,
                .ty = binding_ty,
                .storage = .immutable,
                .ownership = binding_ownership,
                .initialized = true,
                .decl_span = node.span,
            });
            try locals.append(.{
                .id = local_id,
                .name = try ctx.allocator.dupe(u8, node.binding_name),
                .ty = binding_ty,
                .ownership = binding_ownership,
                .span = node.span,
            });
            const lowered: model.Statement = .{ .for_stmt = .{
                .binding_name = try ctx.allocator.dupe(u8, node.binding_name),
                .binding_local_id = local_id,
                .binding_ty = binding_ty,
                .iterator = iterator,
                .body = try lowerBlockStatements(ctx, node.body, imports, &body_scope, locals, next_local_id, function_headers, loop_depth + 1, expected_return_type),
                .span = node.span,
            } };
            try scope_flow.mergeLoopState(ctx.allocator, scope, body_scope);
            break :blk lowered;
        },
        .while_stmt => |node| blk: {
            var body_scope = try scope_flow.cloneScope(ctx.allocator, scope.*);
            defer body_scope.deinit(ctx.allocator);
            const lowered: model.Statement = .{ .while_stmt = .{
                .condition = try lowerExpr(ctx, node.condition, imports, scope, function_headers),
                .body = try lowerBlockStatements(ctx, node.body, imports, &body_scope, locals, next_local_id, function_headers, loop_depth + 1, expected_return_type),
                .span = node.span,
            } };
            try scope_flow.mergeLoopState(ctx.allocator, scope, body_scope);
            break :blk lowered;
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
        .match_stmt => |node| .{ .match_stmt = try lowerMatchStatement(
            ctx,
            node,
            imports,
            scope,
            locals,
            next_local_id,
            function_headers,
            loop_depth,
            expected_return_type,
        ) },
        .switch_stmt => |node| blk: {
            const subject = try lowerExpr(ctx, node.subject, imports, scope, function_headers);
            var cases = std.array_list.Managed(model.SwitchCase).init(ctx.allocator);
            var case_scopes = std.array_list.Managed(model.Scope).init(ctx.allocator);
            defer {
                for (case_scopes.items) |*case_scope| case_scope.deinit(ctx.allocator);
                case_scopes.deinit();
            }
            for (node.cases) |case_node| {
                var case_scope = try scope_flow.cloneScope(ctx.allocator, scope.*);
                try cases.append(.{
                    .pattern = try lowerExpr(ctx, case_node.pattern, imports, scope, function_headers),
                    .body = try lowerBlockStatements(ctx, case_node.body, imports, &case_scope, locals, next_local_id, function_headers, loop_depth, expected_return_type),
                    .span = case_node.span,
                });
                try case_scopes.append(case_scope);
            }
            var default_scope: ?model.Scope = null;
            defer if (default_scope) |*value| value.deinit(ctx.allocator);
            const default_body = if (node.default_block) |default_block| default_body: {
                var branch_scope = try scope_flow.cloneScope(ctx.allocator, scope.*);
                const lowered_default = try lowerBlockStatements(ctx, default_block, imports, &branch_scope, locals, next_local_id, function_headers, loop_depth, expected_return_type);
                default_scope = branch_scope;
                break :default_body lowered_default;
            } else null;
            try scope_flow.mergeSwitchState(ctx.allocator, scope, case_scopes.items, default_scope);
            break :blk .{ .switch_stmt = .{
                .subject = subject,
                .cases = try cases.toOwnedSlice(),
                .default_body = default_body,
                .span = node.span,
            } };
        },
        .return_stmt => |node| .{ .return_stmt = .{
            .value = if (node.value) |expr|
                if (expected_return_type.kind == .unknown)
                    try lowerExpr(ctx, expr, imports, scope, function_headers)
                else
                    try lowerExpectedValue(ctx, expr, expected_return_type, imports, scope, function_headers, node.span)
            else
                null,
            .span = node.span,
        } },
        // `attempt` is expanded in `lowerBlockStatements` (it may yield multiple statements),
        // so it should never reach the single-statement lowering path.
        .attempt_stmt => |node| {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM139",
                .title = "attempt is not valid here",
                .message = "An `attempt { ... } handle { ... }` block may only appear as a statement in a block body.",
                .labels = &.{diagnostics.primaryLabel(node.span, "attempt is not valid in this position")},
                .help = "Move the `attempt` into a function or block body.",
            });
            return error.DiagnosticsEmitted;
        },
    };
}

pub fn markInitializedFromAssignment(scope: *model.Scope, target: model.Expr) !void {
    switch (target) {
        .local => |node| {
            var iterator = scope.entries.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.id != node.local_id) continue;
                entry.value_ptr.initialized = true;
                entry.value_ptr.clearMoveState();
                return;
            }
        },
        else => {},
    }
}

pub fn emitUnknownLocalName(ctx: *shared.Context, name: []const u8, span: source_pkg.Span) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM012",
        .title = "unknown local name",
        .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not find a local binding named '{s}'.", .{name}),
        .labels = &.{diagnostics.primaryLabel(span, "unknown local name")},
        .help = "Declare the value before using it, or qualify imported names.",
    });
}

pub fn emitUninitializedLocalUse(
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
