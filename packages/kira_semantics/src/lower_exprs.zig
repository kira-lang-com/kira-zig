const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");

pub fn lowerBlockStatements(
    ctx: *shared.Context,
    block: syntax.ast.Block,
    imports: []const model.Import,
    scope: *model.Scope,
    locals: *std.array_list.Managed(model.LocalSymbol),
    next_local_id: *u32,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) anyerror![]model.Statement {
    var statements = std.array_list.Managed(model.Statement).init(ctx.allocator);
    for (block.statements) |statement| {
        try statements.append(try lowerStatement(ctx, statement, imports, scope, locals, next_local_id, function_headers));
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
) anyerror!model.Statement {
    return switch (statement) {
        .let_stmt => |node| blk: {
            try shared.validateAnnotationPlacement(ctx, node.annotations, .field_decl, null);
            const value = if (node.value) |expr| try lowerExpr(ctx, expr, imports, scope, function_headers) else null;
            const ty = try resolveLoweredValueType(ctx, node.type_expr, value, node.span);
            const local_id = next_local_id.*;
            next_local_id.* += 1;
            try scope.put(ctx.allocator, node.name, .{ .id = local_id, .ty = ty });
            try locals.append(.{
                .id = local_id,
                .name = try ctx.allocator.dupe(u8, node.name),
                .ty = ty,
                .span = node.span,
            });
            break :blk .{ .let_stmt = .{
                .local_id = local_id,
                .ty = ty,
                .explicit_type = node.type_expr != null,
                .value = value,
                .span = node.span,
            } };
        },
        .assign_stmt => |node| blk: {
            const target = try lowerAssignmentTarget(ctx, node.target, imports, scope, function_headers);
            const value = try lowerExpectedValue(ctx, node.value, model.hir.exprType(target.*), imports, scope, function_headers, node.span);
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
        .if_stmt => |node| .{ .if_stmt = .{
            .condition = try lowerExpr(ctx, node.condition, imports, scope, function_headers),
            .then_body = try lowerBlockStatements(ctx, node.then_block, imports, scope, locals, next_local_id, function_headers),
            .else_body = if (node.else_block) |else_block| try lowerBlockStatements(ctx, else_block, imports, scope, locals, next_local_id, function_headers) else null,
            .span = node.span,
        } },
        .for_stmt => |node| .{ .for_stmt = .{
            .binding_name = try ctx.allocator.dupe(u8, node.binding_name),
            .iterator = try lowerExpr(ctx, node.iterator, imports, scope, function_headers),
            .body = try lowerBlockStatements(ctx, node.body, imports, scope, locals, next_local_id, function_headers),
            .span = node.span,
        } },
        .switch_stmt => |node| blk: {
            var cases = std.array_list.Managed(model.SwitchCase).init(ctx.allocator);
            for (node.cases) |case_node| {
                try cases.append(.{
                    .pattern = try lowerExpr(ctx, case_node.pattern, imports, scope, function_headers),
                    .body = try lowerBlockStatements(ctx, case_node.body, imports, scope, locals, next_local_id, function_headers),
                    .span = case_node.span,
                });
            }
            break :blk .{ .switch_stmt = .{
                .subject = try lowerExpr(ctx, node.subject, imports, scope, function_headers),
                .cases = try cases.toOwnedSlice(),
                .default_body = if (node.default_block) |default_block| try lowerBlockStatements(ctx, default_block, imports, scope, locals, next_local_id, function_headers) else null,
                .span = node.span,
            } };
        },
        .return_stmt => |node| .{ .return_stmt = .{
            .value = if (node.value) |expr| try lowerExpr(ctx, expr, imports, scope, function_headers) else null,
            .span = node.span,
        } },
    };
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
            lowered.* = .{ .array = .{
                .elements = try elements.toOwnedSlice(),
                .span = node.span,
            } };
        },
        .identifier => |node| {
            const name = node.name.segments[0].text;
            if (scope.get(name)) |binding| {
                lowered.* = .{ .local = .{
                    .local_id = binding.id,
                    .name = try ctx.allocator.dupe(u8, name),
                    .ty = binding.ty,
                    .span = node.span,
                } };
            } else if (shared.isImportedRoot(name, imports)) {
                lowered.* = .{ .namespace_ref = .{
                    .root = try ctx.allocator.dupe(u8, name),
                    .path = try ctx.allocator.dupe(u8, name),
                    .span = node.span,
                } };
            } else {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM012",
                    .title = "unknown local name",
                    .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not find a local binding named '{s}'.", .{name}),
                    .labels = &.{
                        diagnostics.primaryLabel(node.span, "unknown local name"),
                    },
                    .help = "Declare the value with `let` before using it, or qualify imported names.",
                });
                return error.DiagnosticsEmitted;
            }
        },
        .member => |node| {
            const flattened = try flattenMemberExpr(ctx.allocator, expr);
            if (shared.isImportedRoot(flattened.root, imports) and scope.get(flattened.root) == null) {
                lowered.* = .{ .namespace_ref = .{
                    .root = flattened.root,
                    .path = flattened.path,
                    .span = node.span,
                } };
                return lowered;
            }
            if (scope.get(flattened.root) == null) {
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
            const maybe_owner_type = resolveFieldContainerType(ctx, model.hir.exprType(object.*));
            if (maybe_owner_type == null) {
                _ = try resolveFieldType(ctx, model.hir.exprType(object.*), node.member, node.span);
                return error.DiagnosticsEmitted;
            }
            const owner_type = maybe_owner_type.?;
            const field_type = try resolveFieldType(ctx, model.hir.exprType(object.*), node.member, node.span);
            lowered.* = .{ .field = .{
                .object = object,
                .field_name = try ctx.allocator.dupe(u8, node.member),
                .owner_type = owner_type,
                .ty = field_type,
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
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM033",
                .title = "conditional expression is not lowered yet",
                .message = "The frontend can parse conditional expressions, but the semantic lowering pass does not support them yet.",
                .labels = &.{
                    diagnostics.primaryLabel(node.span, "conditional expression lowering is not implemented"),
                },
                .help = "Use `if` statements for executable code for now, or keep this expression in check-only frontend coverage.",
            });
            return error.DiagnosticsEmitted;
        },
        .call => |node| try lowerCallExpr(ctx, lowered, node, imports, scope, function_headers),
    }
    return lowered;
}

fn lowerCallExpr(
    ctx: *shared.Context,
    lowered: *model.Expr,
    node: syntax.ast.CallExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    const callee_name = try flattenCalleeName(ctx.allocator, node.callee);
    const callee_leaf = qualifiedLeaf(callee_name);

    if (std.mem.eql(u8, callee_name, "print")) {
        var args = std.array_list.Managed(*model.Expr).init(ctx.allocator);
        for (node.args) |arg| try args.append(try lowerExpr(ctx, arg.value, imports, scope, function_headers));
        if (args.items.len != 1) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM007",
                .title = "wrong number of arguments to print",
                .message = "The builtin `print` expects exactly one argument.",
                .labels = &.{
                    diagnostics.primaryLabel(node.span, "print call has the wrong number of arguments"),
                },
                .help = "Call `print(value);` with exactly one value.",
            });
            return error.DiagnosticsEmitted;
        }
        const arg_ty = model.hir.exprType(args.items[0].*);
        if (arg_ty.kind != .integer and arg_ty.kind != .string) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM008",
                .title = "unsupported print argument type",
                .message = "The current Kira runtime can only print integers and strings.",
                .labels = &.{
                    diagnostics.primaryLabel(node.span, "unsupported argument type for print"),
                },
                .help = "Pass an integer or string to `print`.",
            });
            return error.DiagnosticsEmitted;
        }
        lowered.* = .{ .call = .{
            .callee_name = callee_name,
            .function_id = null,
            .args = try args.toOwnedSlice(),
            .ty = .{ .kind = .void },
            .span = node.span,
        } };
        return;
    }

    if (function_headers) |headers| {
        const header = headers.get(callee_name) orelse headers.get(callee_leaf) orelse blk: {
            if (ctx.imported_globals.findFunction(callee_leaf)) |function_decl| {
                break :blk shared.FunctionHeader{
                    .id = 0,
                    .params = function_decl.params,
                    .execution = function_decl.execution,
                    .return_type = function_decl.return_type,
                    .is_extern = function_decl.is_extern,
                    .foreign = function_decl.foreign,
                    .span = .{ .start = 0, .end = 0 },
                };
            }
            break :blk null;
        };
        if (header) |resolved_header| {
            if (node.args.len != resolved_header.params.len) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM042",
                    .title = "wrong number of arguments",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The call to '{s}' expected {d} argument(s) but received {d}.", .{ callee_name, resolved_header.params.len, node.args.len }),
                    .labels = &.{
                        diagnostics.primaryLabel(node.span, "call uses the wrong number of arguments"),
                    },
                    .help = "Update the call so it matches the function signature exactly.",
                });
                return error.DiagnosticsEmitted;
            }
            var args = std.array_list.Managed(*model.Expr).init(ctx.allocator);
            for (node.args, 0..) |arg, index| {
                try args.append(try lowerCallArgument(ctx, arg.value, resolved_header.params[index], imports, scope, headers, node.span));
            }
            lowered.* = .{ .call = .{
                .callee_name = callee_name,
                .function_id = resolved_header.id,
                .args = try args.toOwnedSlice(),
                .ty = resolved_header.return_type,
                .span = node.span,
            } };
            return;
        }
    }

    if (ctx.imported_globals.hasCallable(callee_name)) {
        var args = std.array_list.Managed(*model.Expr).init(ctx.allocator);
        for (node.args) |arg| try args.append(try lowerExpr(ctx, arg.value, imports, scope, function_headers));
        lowered.* = .{ .call = .{
            .callee_name = callee_name,
            .function_id = null,
            .args = try args.toOwnedSlice(),
            .ty = .{ .kind = .unknown },
            .span = node.span,
        } };
        return;
    }

    if (std.mem.indexOfScalar(u8, callee_name, '.')) |root_end| {
        if (!shared.isImportedRoot(callee_name[0..root_end], imports)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM027",
                .title = "invalid namespaced reference",
                .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not resolve the namespace root '{s}'.", .{callee_name[0..root_end]}),
                .labels = &.{
                    diagnostics.primaryLabel(node.span, "unknown namespace root"),
                },
                .help = "Import the module first or use a local function name.",
            });
            return error.DiagnosticsEmitted;
        }
        var args = std.array_list.Managed(*model.Expr).init(ctx.allocator);
        for (node.args) |arg| try args.append(try lowerExpr(ctx, arg.value, imports, scope, function_headers));
        lowered.* = .{ .call = .{
            .callee_name = callee_name,
            .function_id = null,
            .args = try args.toOwnedSlice(),
            .ty = .{ .kind = .unknown },
            .span = node.span,
        } };
        return;
    }

    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM010",
        .title = "unknown call target",
        .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not find a function named '{s}'.", .{callee_name}),
        .labels = &.{
            diagnostics.primaryLabel(node.span, "unknown function call"),
        },
        .help = "Declare the function before calling it, or import the module that provides the symbol.",
    });
    return error.DiagnosticsEmitted;
}

fn lowerCallArgument(
    ctx: *shared.Context,
    syntax_arg: *syntax.ast.Expr,
    expected_type: model.ResolvedType,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
    call_span: source_pkg.Span,
) !*model.Expr {
    return lowerExpectedValue(ctx, syntax_arg, expected_type, imports, scope, function_headers, call_span);
}

fn lowerExpectedValue(
    ctx: *shared.Context,
    syntax_arg: *syntax.ast.Expr,
    expected_type: model.ResolvedType,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
    span: source_pkg.Span,
) !*model.Expr {
    if (shared.callbackInfo(ctx, expected_type)) |callback_info| {
        return lowerCallbackArgument(ctx, syntax_arg, expected_type, callback_info, function_headers);
    }

    if (shared.isPointerLike(ctx, expected_type) and isNullPointerLiteral(syntax_arg.*)) {
        const lowered = try ctx.allocator.create(model.Expr);
        lowered.* = .{ .null_ptr = .{
            .ty = expected_type,
            .span = exprSpan(syntax_arg.*),
        } };
        return lowered;
    }

    const lowered = try lowerExpr(ctx, syntax_arg, imports, scope, function_headers);
    const actual_type = model.hir.exprType(lowered.*);
    if (!canPassArgument(ctx, expected_type, actual_type)) {
        try shared.emitTypeMismatch(ctx.allocator, ctx.diagnostics, span, expected_type, actual_type);
        return error.DiagnosticsEmitted;
    }
    return lowered;
}

fn lowerAssignmentTarget(
    ctx: *shared.Context,
    expr: *syntax.ast.Expr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !*model.Expr {
    return switch (expr.*) {
        .identifier, .member => try lowerExpr(ctx, expr, imports, scope, function_headers),
        else => blk: {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM046",
                .title = "invalid assignment target",
                .message = "Assignments can only target locals or fields.",
                .labels = &.{
                    diagnostics.primaryLabel(exprSpan(expr.*), "this expression cannot appear on the left side of '='"),
                },
                .help = "Assign to a local name or a field reference.",
            });
            break :blk error.DiagnosticsEmitted;
        },
    };
}

fn lowerCallbackArgument(
    ctx: *shared.Context,
    syntax_arg: *syntax.ast.Expr,
    expected_type: model.ResolvedType,
    callback_info: model.CallbackInfo,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !*model.Expr {
    const name = try flattenCalleeName(ctx.allocator, syntax_arg);
    const header = function_headers.get(name) orelse {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM043",
            .title = "unknown callback target",
            .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not find a function named '{s}' for this callback argument.", .{name}),
            .labels = &.{
                diagnostics.primaryLabel(exprSpan(syntax_arg.*), "callback target is not a known function"),
            },
            .help = "Pass a named function that matches the callback signature.",
        });
        return error.DiagnosticsEmitted;
    };

    if (header.execution == .runtime) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM044",
            .title = "runtime callbacks are not supported here",
            .message = "Callbacks passed to native FFI must currently resolve to native or extern functions.",
            .labels = &.{
                diagnostics.primaryLabel(exprSpan(syntax_arg.*), "runtime function cannot be converted to a native callback"),
            },
            .help = "Mark the callback target with @Native or use an extern callback symbol.",
        });
        return error.DiagnosticsEmitted;
    }

    if (header.params.len != callback_info.params.len or !shared.canAssignExactly(header.return_type, callback_info.result)) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM045",
            .title = "invalid callback signature",
            .message = "The callback target does not match the required callback signature.",
            .labels = &.{
                diagnostics.primaryLabel(exprSpan(syntax_arg.*), "callback signature does not match"),
            },
            .help = "Match the callback parameter and result types exactly.",
        });
        return error.DiagnosticsEmitted;
    }
    for (header.params, 0..) |param_type, index| {
        if (!shared.canAssignExactly(param_type, callback_info.params[index])) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM045",
                .title = "invalid callback signature",
                .message = "The callback target does not match the required callback signature.",
                .labels = &.{
                    diagnostics.primaryLabel(exprSpan(syntax_arg.*), "callback signature does not match"),
                },
                .help = "Match the callback parameter and result types exactly.",
            });
            return error.DiagnosticsEmitted;
        }
    }

    const lowered = try ctx.allocator.create(model.Expr);
    lowered.* = .{ .function_ref = .{
        .function_id = header.id,
        .name = name,
        .ty = expected_type,
        .span = exprSpan(syntax_arg.*),
    } };
    return lowered;
}

fn canPassArgument(ctx: *const shared.Context, expected: model.ResolvedType, actual: model.ResolvedType) bool {
    if (shared.canAssign(expected, actual)) return true;
    if (expected.kind == .c_string and actual.kind == .string) return true;
    if (shared.isPointerLike(ctx, expected) and actual.kind == .raw_ptr) return true;
    if (expected.kind == .raw_ptr and actual.kind == .named) {
        if (shared.namedTypeInfo(ctx, actual)) |info| {
            return switch (info) {
                .ffi_struct => true,
                .alias => |value| canPassArgument(ctx, expected, value.target),
                else => false,
            };
        }
    }
    if (expected.kind == .named and actual.kind == .named) {
        if (shared.namedTypeInfo(ctx, expected)) |info| {
            return switch (info) {
                .alias => |value| canPassArgument(ctx, value.target, actual),
                .pointer => |value| std.mem.eql(u8, value.target_name, actual.name orelse ""),
                else => false,
            };
        }
    }
    return false;
}

fn resolveFieldType(
    ctx: *shared.Context,
    object_type: model.ResolvedType,
    field_name: []const u8,
    span: source_pkg.Span,
) !model.ResolvedType {
    const container_type = resolveFieldContainerType(ctx, object_type) orelse {
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
        return error.DiagnosticsEmitted;
    };

    for (shared.namedTypeFields(ctx, container_type)) |field_decl| {
        if (std.mem.eql(u8, field_decl.name, field_name)) return field_decl.ty;
    }

    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM048",
        .title = "unknown field",
        .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' does not declare a field named '{s}'.", .{
            container_type.name orelse "<anonymous>",
            field_name,
        }),
        .labels = &.{
            diagnostics.primaryLabel(span, "field name is not declared on this type"),
        },
        .help = "Check the field spelling or use a type that declares the field.",
    });
    return error.DiagnosticsEmitted;
}

fn resolveFieldContainerType(ctx: *shared.Context, ty: model.ResolvedType) ?model.ResolvedType {
    return switch (ty.kind) {
        .named => if (shared.namedTypeInfo(ctx, ty)) |info|
            switch (info) {
                .ffi_struct => ty,
                .pointer => |value| .{ .kind = .named, .name = value.target_name },
                .alias => |value| resolveFieldContainerType(ctx, value.target),
                else => if (shared.namedTypeFields(ctx, ty).len > 0) ty else null,
            }
        else if (shared.namedTypeFields(ctx, ty).len > 0)
            ty
        else
            null,
        else => null,
    };
}

fn isNullPointerLiteral(expr: syntax.ast.Expr) bool {
    return switch (expr) {
        .integer => |node| node.value == 0,
        else => false,
    };
}

fn exprSpan(expr: syntax.ast.Expr) source_pkg.Span {
    return switch (expr) {
        .integer => |node| node.span,
        .float => |node| node.span,
        .string => |node| node.span,
        .bool => |node| node.span,
        .identifier => |node| node.span,
        .array => |node| node.span,
        .unary => |node| node.span,
        .binary => |node| node.span,
        .conditional => |node| node.span,
        .member => |node| node.span,
        .call => |node| node.span,
    };
}

fn qualifiedLeaf(name: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[index + 1 ..];
}

pub fn resolveSyntaxExprType(ctx: *shared.Context, expr: *syntax.ast.Expr, span: source_pkg.Span) !model.ResolvedType {
    _ = ctx;
    _ = span;
    return switch (expr.*) {
        .integer => .{ .kind = .integer },
        .float => .{ .kind = .float },
        .string => .{ .kind = .string },
        .bool => .{ .kind = .boolean },
        .array => .{ .kind = .array },
        else => .{ .kind = .unknown },
    };
}

pub fn resolveLoweredValueType(ctx: *shared.Context, explicit_type_expr: ?*syntax.ast.TypeExpr, value_expr: ?*model.Expr, span: source_pkg.Span) !model.ResolvedType {
    if (explicit_type_expr) |type_expr| {
        const explicit_type = shared.typeFromSyntax(type_expr.*);
        if (value_expr) |expr| {
            const actual = model.hir.exprType(expr.*);
            if (!(shared.canAssign(explicit_type, actual) or canPassArgument(ctx, explicit_type, actual))) {
                try shared.emitTypeMismatch(ctx.allocator, ctx.diagnostics, span, explicit_type, actual);
                return error.DiagnosticsEmitted;
            }
        }
        return explicit_type;
    }
    if (value_expr) |expr| return model.hir.exprType(expr.*);
    try shared.emitAmbiguousInference(ctx.allocator, ctx.diagnostics, span);
    return error.DiagnosticsEmitted;
}

pub fn resolveValueType(ctx: *shared.Context, explicit_type_expr: ?*syntax.ast.TypeExpr, value_expr: ?*syntax.ast.Expr, span: source_pkg.Span) !model.ResolvedType {
    if (explicit_type_expr) |type_expr| {
        const explicit_type = shared.typeFromSyntax(type_expr.*);
        if (value_expr) |expr| {
            const inferred = try resolveSyntaxExprType(ctx, expr, span);
            if (!(shared.canAssign(explicit_type, inferred) or canPassArgument(ctx, explicit_type, inferred))) {
                try shared.emitTypeMismatch(ctx.allocator, ctx.diagnostics, span, explicit_type, inferred);
                return error.DiagnosticsEmitted;
            }
        }
        return explicit_type;
    }
    if (value_expr) |expr| return resolveSyntaxExprType(ctx, expr, span);
    try shared.emitAmbiguousInference(ctx.allocator, ctx.diagnostics, span);
    return error.DiagnosticsEmitted;
}

pub fn resolveFunctionReturnType(ctx: *shared.Context, explicit_return_type: model.ResolvedType, body: []const model.Statement) !model.ResolvedType {
    var inferred: ?model.ResolvedType = null;
    for (body) |statement| {
        if (statement != .return_stmt) continue;
        const return_stmt = statement.return_stmt;
        const actual = if (return_stmt.value) |expr| model.hir.exprType(expr.*) else model.ResolvedType{ .kind = .void };
        if (explicit_return_type.kind != .unknown) {
            if (!shared.canAssignExactly(explicit_return_type, actual)) {
                try shared.emitTypeMismatch(ctx.allocator, ctx.diagnostics, return_stmt.span, explicit_return_type, actual);
                return error.DiagnosticsEmitted;
            }
            continue;
        }
        if (inferred == null) {
            inferred = actual;
        } else if (!inferred.?.eql(actual)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM030",
                .title = "function return type is ambiguous",
                .message = "Kira found return statements with different inferred types.",
                .labels = &.{
                    diagnostics.primaryLabel(return_stmt.span, "return type changes here"),
                },
                .help = "Add an explicit return type to the function.",
            });
            return error.DiagnosticsEmitted;
        }
    }
    if (explicit_return_type.kind != .unknown) return explicit_return_type;
    return inferred orelse .{ .kind = .void };
}

fn resolveBinaryType(ctx: *shared.Context, op: syntax.ast.BinaryOp, lhs: *model.Expr, rhs: *model.Expr, span: source_pkg.Span) !model.ResolvedType {
    const lhs_ty = model.hir.exprType(lhs.*);
    const rhs_ty = model.hir.exprType(rhs.*);
    return switch (op) {
        .add, .subtract, .multiply, .divide, .modulo => blk: {
            if (lhs_ty.eql(rhs_ty) and (lhs_ty.kind == .integer or lhs_ty.kind == .float)) break :blk lhs_ty;
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM013",
                .title = "invalid binary operator types",
                .message = "Arithmetic operators require both operands to use the same numeric type.",
                .labels = &.{
                    diagnostics.primaryLabel(span, "operands do not use compatible numeric types"),
                },
                .help = "Make both operands integers or both operands floats, or add an explicit type declaration where coercion is allowed.",
            });
            return error.DiagnosticsEmitted;
        },
        .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => blk: {
            if (lhs_ty.eql(rhs_ty)) break :blk .{ .kind = .boolean };
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM028",
                .title = "comparison requires matching types",
                .message = "Comparison operators require both sides to have the same type.",
                .labels = &.{
                    diagnostics.primaryLabel(span, "comparison uses incompatible operand types"),
                },
                .help = "Make both operands the same type before comparing them.",
            });
            return error.DiagnosticsEmitted;
        },
        .logical_and, .logical_or => blk: {
            if (lhs_ty.kind == .boolean and rhs_ty.kind == .boolean) break :blk .{ .kind = .boolean };
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM034",
                .title = "logical operators require booleans",
                .message = "Logical `&&` and `||` require both operands to be boolean values.",
                .labels = &.{
                    diagnostics.primaryLabel(span, "logical operands are not both booleans"),
                },
                .help = "Ensure both sides resolve to `Bool` before using a logical operator.",
            });
            return error.DiagnosticsEmitted;
        },
    };
}

fn flattenCalleeName(allocator: std.mem.Allocator, expr: *syntax.ast.Expr) ![]const u8 {
    return switch (expr.*) {
        .identifier => |node| allocator.dupe(u8, node.name.segments[0].text),
        .member => flattenMemberExprPath(allocator, expr),
        else => allocator.dupe(u8, "<expr>"),
    };
}

fn flattenMemberExpr(allocator: std.mem.Allocator, expr: *syntax.ast.Expr) !struct { root: []const u8, path: []const u8 } {
    const path = try flattenMemberExprPath(allocator, expr);
    const root_end = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
    return .{
        .root = try allocator.dupe(u8, path[0..root_end]),
        .path = path,
    };
}

fn flattenMemberExprPath(allocator: std.mem.Allocator, expr: *syntax.ast.Expr) ![]const u8 {
    return switch (expr.*) {
        .member => |node| blk: {
            const left = try flattenMemberExprPath(allocator, node.object);
            break :blk try std.fmt.allocPrint(allocator, "{s}.{s}", .{ left, node.member });
        },
        .identifier => |node| allocator.dupe(u8, node.name.segments[0].text),
        else => allocator.dupe(u8, "<expr>"),
    };
}
