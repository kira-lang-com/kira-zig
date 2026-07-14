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
const parent = @import("lower_exprs.zig");
const tryLowerCountMemberExpr = parent.tryLowerCountMemberExpr;
const emitMemberAccessRequiresStructuredType = parent.emitMemberAccessRequiresStructuredType;
const emitUnknownLocalName = parent.emitUnknownLocalName;
const emitUninitializedLocalUse = parent.emitUninitializedLocalUse;

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

pub fn lowerExpr(
    ctx: *shared.Context,
    expr: *syntax.ast.Expr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) anyerror!*model.Expr {
    ctx.lower_depth += 1;
    defer ctx.lower_depth -= 1;
    try shared.checkLoweringDepth(ctx, shared.exprSpan(expr.*));
    if (try enum_variants.lowerEnumVariantExpr(ctx, expr, .{ .kind = .unknown }, imports, scope, function_headers)) |enum_expr| {
        return enum_expr;
    }
    const lowered = try ctx.allocator.create(model.Expr);
    switch (expr.*) {
        .integer => |node| lowered.* = .{ .integer = .{ .value = node.value, .span = node.span } },
        .float => |node| lowered.* = .{ .float = .{ .value = node.value, .span = node.span } },
        .string => |node| lowered.* = .{ .string = .{ .value = node.value, .span = node.span } },
        .bool => |node| lowered.* = .{ .boolean = .{ .value = node.value, .span = node.span } },
        .array => |node| {
            var elements = std.array_list.Managed(*model.Expr).init(ctx.allocator);
            for (node.elements) |element| {
                const lowered_element = try lowerExpr(ctx, element, imports, scope, function_headers);
                // An Any field read as an array element is a partial move out of
                // its owner (`[content]` forwarding a single content field into an
                // array-content widget — the editor SurfaceBox case).
                shared.markAnyFieldMovedIntoOwned(ctx, scope, lowered_element, exprSpan(element.*));
                try elements.append(lowered_element);
            }
            const array_ty = try resolveArrayLiteralType(ctx, elements.items, node.span);
            lowered.* = .{ .array = .{
                .elements = try elements.toOwnedSlice(),
                .ty = array_ty,
                .span = node.span,
            } };
        },
        .builder_array => |node| {
            // A content-block expression (`{ Text(...); child; For(...) { ... } }`)
            // reaching the generic expression path has no expected type to anchor
            // its element type. Content blocks must be anchored by an annotation
            // (`let x: [some Widget] = {...}`) or a receiving field/argument type;
            // an unanchored one cannot know what it owns and is rejected here. The
            // anchored routes lower through `lowerExpectedValue` and never arrive.
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM160",
                .title = "content block needs a type anchor",
                .message = "This content block has no expected type, so Kira cannot infer the element type of the children it produces.",
                .labels = &.{diagnostics.primaryLabel(node.span, "content block has no anchoring type")},
                .help = "Anchor it with an annotation such as `let header: [some Widget] = { ... }`, or place it where a field or argument supplies the expected array type.",
            });
            return error.DiagnosticsEmitted;
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
        .native_state_free => |node| {
            lowered.* = try lowerNativeStateFreeExpr(ctx, node, imports, scope, function_headers);
        },
        .ownership => |node| {
            return try lowerOwnershipExpr(ctx, node, imports, scope, function_headers);
        },
        .identifier => |node| {
            const name = node.name.segments[0].text;
            if (try shared.resolveLocalOrCapture(ctx, scope.*, name, node.span)) |resolution| {
                const binding = resolution.binding;
                if (!binding.initialized) {
                    try emitUninitializedLocalUse(ctx, name, node.span, binding.decl_span);
                    return error.DiagnosticsEmitted;
                }
                if (binding.moved) {
                    try emitUseAfterMove(ctx, name, node.span, binding.move_span);
                    return error.DiagnosticsEmitted;
                }
                if (binding.is_task_handle and !ctx.allow_task_handle_read) {
                    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM158",
                        .title = "task handle can only be awaited, cancelled, or detached",
                        .message = "A `Task { ... }` handle is opaque: join it with `.await`, cancel it with `.requestCancel()`, or release it with `.detach()`. It cannot be used as a plain value.",
                        .labels = &.{diagnostics.primaryLabel(node.span, "task handle used as a plain value")},
                        .help = "Write `handle.await` to get the task's result.",
                    });
                    return error.DiagnosticsEmitted;
                }
                lowered.* = .{ .local = .{
                    .local_id = binding.id,
                    .name = try ctx.allocator.dupe(u8, name),
                    .ty = binding.ty,
                    .storage = binding.storage,
                    .span = node.span,
                } };
            } else if (shared.isImportedRoot(ctx, name, imports)) {
                lowered.* = .{ .namespace_ref = .{
                    .root = try ctx.allocator.dupe(u8, name),
                    .path = try ctx.allocator.dupe(u8, name),
                    .span = node.span,
                } };
            } else if (function_headers) |headers| {
                if (shared.findFunctionHeader(ctx, headers, name)) |header| {
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
        .implicit_member => |node| {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM166",
                .title = "implicit member needs a type anchor",
                .message = "This implicit member has no expected result type, so Kira cannot determine its declaration namespace.",
                .labels = &.{diagnostics.primaryLabel(node.span, "implicit member has no anchoring type")},
                .help = "Add an explicit type annotation or pass the expression where an argument, field, or return type supplies the expected type.",
            });
            return error.DiagnosticsEmitted;
        },
        .member => |node| {
            if (std.mem.eql(u8, node.member, "await")) {
                // `handle.await` joins a deferred task: the first drive runs the
                // spawned call and yields its result (lower_exprs_async.zig).
                return async_spine.lowerTaskAwait(ctx, lowered, node, imports, scope, function_headers);
            }
            if (try lowerParentQualifiedFieldExpr(ctx, node, imports, scope, function_headers)) |field_expr| {
                lowered.* = field_expr;
                return lowered;
            }
            const flattened = try flattenMemberExpr(ctx.allocator, expr);
            if (std.mem.eql(u8, flattened.root, "<expr>")) {
                const object = try lowerExpr(ctx, node.object, imports, scope, function_headers);
                if (tryLowerCountMemberExpr(object, node.member, node.span)) |count_expr| {
                    lowered.* = count_expr;
                    return lowered;
                }
                const object_type = resolveFieldContainerType(ctx, model.hir.exprType(object.*)) orelse {
                    try emitMemberAccessRequiresStructuredType(ctx, node.span);
                    return error.DiagnosticsEmitted;
                };
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
            const root_is_type = (ctx.type_headers != null and (ctx.type_headers.?.get(flattened.root) != null)) or
                ctx.imported_globals.findType(flattened.root) != null;
            if ((shared.isImportedRoot(ctx, flattened.root, imports) or root_is_type) and scope.get(flattened.root) == null) {
                if (function_headers) |headers| {
                    if (headers.get(flattened.path)) |header| {
                        if (header.is_accessor) {
                            lowered.* = .{ .call = .{
                                .callee_name = try ctx.allocator.dupe(u8, flattened.path),
                                .function_id = header.id,
                                .args = &.{},
                                .ty = header.return_type,
                                .span = node.span,
                            } };
                            return lowered;
                        }
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
                        if (tryLowerCountMemberExpr(object, node.member, node.span)) |count_expr| {
                            lowered.* = count_expr;
                            return lowered;
                        }
                        const object_type = resolveFieldContainerType(ctx, model.hir.exprType(object.*)) orelse {
                            try emitMemberAccessRequiresStructuredType(ctx, node.span);
                            return error.DiagnosticsEmitted;
                        };
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
            if (tryLowerCountMemberExpr(object, node.member, node.span)) |count_expr| {
                lowered.* = count_expr;
                return lowered;
            }
            // A computed-property accessor (`widget.node`) runs the Widget->Node bridge.
            if (try members.tryLowerComputedAccessor(ctx, object, node.member, node.span, scope)) |accessor| {
                lowered.* = accessor.*;
                return lowered;
            }
            const object_type = resolveFieldContainerType(ctx, model.hir.exprType(object.*)) orelse {
                try emitMemberAccessRequiresStructuredType(ctx, node.span);
                return error.DiagnosticsEmitted;
            };
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
            const element_ty = try types.resolveIndexElementType(ctx, model.hir.exprType(object.*), node.span);
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
                    .bit_not => operand_type,
                    .not => .{ .kind = .boolean },
                },
                .span = node.span,
            } };
        },
        .binary => |node| {
            const lhs = try lowerExpr(ctx, node.lhs, imports, scope, function_headers);
            if (try lowerBinaryOperatorMethod(ctx, node, lhs, imports, scope, function_headers)) |operator_call| {
                lowered.* = operator_call;
                return lowered;
            }
            const rhs = if (implicit_members.isImplicit(node.rhs) and function_headers != null)
                try lowerExpectedValue(ctx, node.rhs, model.hir.exprType(lhs.*), imports, scope, function_headers.?, node.span)
            else
                try lowerExpr(ctx, node.rhs, imports, scope, function_headers);
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
                    .bit_and => .bit_and,
                    .bit_or => .bit_or,
                    .bit_xor => .bit_xor,
                    .shift_left => .shift_left,
                    .shift_right => .shift_right,
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
        // A `try` expression is only meaningful as the initializer of a `let` binding or an
        // expression statement inside an `attempt` block, where it is desugared before lowering.
        // Any `try` reaching general expression lowering is in an unsupported position.
        .try_expr => |node| {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM133",
                .title = "'try' is not valid here",
                .message = "`try` may only be used as a `let` initializer or expression statement inside an `attempt { ... }` block.",
                .labels = &.{diagnostics.primaryLabel(node.span, "`try` is not valid in this position")},
                .help = "Wrap the failing call in an `attempt { ... } handle { ... }` block, and use `try` as `let x = try call()` or as a statement `try call()`.",
            });
            return error.DiagnosticsEmitted;
        },
        .quote => |node| {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KMAC016",
                .title = "'quote' is only valid in a comptime macro",
                .message = "`quote { ... }` may only appear inside a `comptime macro` expand body; it is consumed by macro expansion.",
                .labels = &.{diagnostics.primaryLabel(node.span, "`quote` is not valid here")},
                .help = "Move this `quote` into a `comptime macro` declaration's `expand` function.",
            });
            return error.DiagnosticsEmitted;
        },
    }
    return lowered;
}

fn lowerBinaryOperatorMethod(
    ctx: *shared.Context,
    node: syntax.ast.BinaryExpr,
    lhs: *model.Expr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !?model.Expr {
    const method_name = binaryOperatorMethodName(node.op) orelse return null;
    const lhs_type = model.hir.exprType(lhs.*);
    if (lhs_type.kind != .named and lhs_type.kind != .native_state_view) return null;

    const resolved_method = (try resolveMethodMemberOrNull(ctx, lhs_type, method_name, node.span)) orelse return null;
    const args = try ctx.allocator.alloc(syntax.ast.CallArg, 1);
    args[0] = .{
        .label = null,
        .value = node.rhs,
        .span = exprSpan(node.rhs.*),
    };
    const fake_call = syntax.ast.CallExpr{
        .callee = node.lhs,
        .args = args,
        .trailing_builder = null,
        .trailing_callback = null,
        .span = node.span,
    };
    const lowered = try buildDispatchedMethodCallExpr(ctx, resolved_method, lhs, lhs_type, fake_call, imports, scope, function_headers);
    return lowered.*;
}

fn binaryOperatorMethodName(op: syntax.ast.BinaryOp) ?[]const u8 {
    return switch (op) {
        .add => "add",
        .subtract => "subtract",
        .multiply => "multiply",
        .divide => "divide",
        else => null,
    };
}
