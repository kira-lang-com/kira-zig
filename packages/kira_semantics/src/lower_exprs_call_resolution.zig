const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const function_types = @import("function_types.zig");
const comptime_eval = @import("lower_exprs_comptime.zig");
const async_spine = @import("lower_exprs_async.zig");
const parent = @import("lower_exprs.zig");
const lowerExpr = parent.lowerExpr;
const lowerExpectedValue = parent.lowerExpectedValue;
const lowerImplicitSelfFieldExpr = parent.lowerImplicitSelfFieldExpr;
const lowerImplicitSelfMethodCall = parent.lowerImplicitSelfMethodCall;
const lowerParentQualifiedFieldExpr = parent.lowerParentQualifiedFieldExpr;
const lowerParentQualifiedMethodCall = parent.lowerParentQualifiedMethodCall;
const resolveFieldType = parent.resolveFieldType;
const resolveFieldContainerType = parent.resolveFieldContainerType;
const resolveMethodMember = parent.resolveMethodMember;
const resolveMethodMemberOrNull = parent.resolveMethodMemberOrNull;
const buildDispatchedMethodCallExpr = parent.buildDispatchedMethodCallExpr;
const functionTypeFromHeader = parent.functionTypeFromHeader;
const lowerCallArgument = parent.lowerCallArgument;
const trailingCallbackType = parent.trailingCallbackType;
const lowerTrailingCallbackValue = parent.lowerTrailingCallbackValue;
const lowerBuilderBlock = parent.lowerBuilderBlock;
const isCallableValueExpr = parent.isCallableValueExpr;
const flattenCalleeName = parent.flattenCalleeName;
const flattenMemberExpr = parent.flattenMemberExpr;
const qualifiedLeaf = parent.qualifiedLeaf;
const lowerComptimeCall = comptime_eval.lowerComptimeCall;

const base = @import("lower_exprs_calls.zig");
const lowerStringMethodOrNull = base.lowerStringMethodOrNull;
const isAliasingAggregateRead = base.isAliasingAggregateRead;
const rejectAliasedArrayField = base.rejectAliasedArrayField;
const lowerStructLiteralExpr = base.lowerStructLiteralExpr;
const lowerTypeConstruction = base.lowerTypeConstruction;
const fieldHasRequiredAnnotation = base.fieldHasRequiredAnnotation;
const isTypeConstantField = base.isTypeConstantField;
const resolveTypeConstructionFieldIndex = base.resolveTypeConstructionFieldIndex;
const buildContentArgs = base.buildContentArgs;
const emitSlotViaArg = base.emitSlotViaArg;
const typeHasField = base.typeHasField;
const contentArg = base.contentArg;
const calleeIdentifierName = base.calleeIdentifierName;
const findContentField = base.findContentField;
const localOrImportedTypeFieldCount = base.localOrImportedTypeFieldCount;
const requiredExplicitArgCount = base.requiredExplicitArgCount;

pub fn lowerResolvedCall(
    ctx: *shared.Context,
    lowered: *model.Expr,
    node: syntax.ast.CallExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
    callee_name: []const u8,
    callee_leaf: []const u8,
) !void {
    const imported_qualified = if (function_headers != null)
        shared.importedQualifiedName(ctx, imports, callee_name)
    else
        null;
    const exact_function_header = if (function_headers) |headers| shared.findFunctionHeader(ctx, headers, callee_name) else null;
    const exact_qualified_function_header = if (function_headers) |headers|
        if (imported_qualified) |qualified| shared.findFunctionHeader(ctx, headers, qualified) else null
    else
        null;
    const is_qualified_callee = std.mem.indexOfScalar(u8, callee_name, '.') != null;
    const has_local_type = if (ctx.type_headers) |headers|
        headers.get(callee_name) != null or headers.get(callee_leaf) != null
    else
        false;
    const has_imported_type = ctx.imported_globals.findType(callee_name) != null or ctx.imported_globals.findType(callee_leaf) != null;
    const qualified_type_fits = if (is_qualified_callee)
        if (localOrImportedTypeFieldCount(ctx, callee_name, callee_leaf)) |field_count| node.args.len <= field_count else false
    else
        false;
    // Bare-callee precedence must be the same in every package: a visible type (e.g. a
    // Widget form's node type) wins over a same-named FUNCTION from another package, exactly
    // as it does in the root package. Only the current package's OWN function outranks the
    // type. (Previously a dependency package preferred any bare function header, so
    // `Text(...)` inside a library resolved to a transitive package's 4-arg `Text` function
    // while the same code in the root app resolved to the imported `Text` widget.)
    const own_scoped_function = if (function_headers) |headers| blk: {
        if (ctx.current_package) |package_name| {
            if (std.mem.indexOfScalar(u8, callee_name, '.') == null) {
                const scoped = std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ package_name, callee_name }) catch break :blk false;
                break :blk headers.get(scoped) != null;
            }
        }
        break :blk false;
    } else false;
    const should_prefer_type = if (has_local_type or has_imported_type)
        if (is_qualified_callee)
            exact_function_header == null and exact_qualified_function_header == null and qualified_type_fits
        else
            !own_scoped_function
    else
        false;
    if (should_prefer_type) {
        const content_args = try buildContentArgs(ctx, callee_name, callee_leaf, node);
        lowered.* = try lowerTypeConstruction(ctx, callee_name, callee_leaf, content_args orelse node.args, &.{}, node.span, imports, scope, function_headers);
        return;
    }

    if (function_headers) |headers| {
        const header = (if (imported_qualified) |qualified| shared.findFunctionHeader(ctx, headers, qualified) else null) orelse
            shared.findFunctionHeader(ctx, headers, callee_name) orelse
            shared.findFunctionHeader(ctx, headers, callee_leaf) orelse blk: {
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
            if (resolved_header.is_comptime) {
                if (try lowerComptimeCall(ctx, node, resolved_header)) |folded| {
                    lowered.* = folded;
                    return;
                }
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM147",
                    .title = "comptime function was not evaluated",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The comptime function '{s}' must be evaluated during compilation and cannot be emitted as a runtime call.", .{callee_name}),
                    .labels = &.{diagnostics.primaryLabel(node.span, "runtime call to comptime function")},
                    .help = "Use a comptime function form the compiler can fold or generate before backend lowering.",
                });
                return error.DiagnosticsEmitted;
            }
            const trailing_callback_type = try trailingCallbackType(ctx, node, resolved_header.params);
            const explicit_param_count = resolved_header.params.len - (if (trailing_callback_type != null) @as(usize, 1) else 0);
            const required_arg_count = requiredExplicitArgCount(resolved_header.param_defaults, explicit_param_count);
            if (node.args.len < required_arg_count or node.args.len > explicit_param_count) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM042",
                    .title = "wrong number of arguments",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The call to '{s}' expected between {d} and {d} explicit argument(s) but received {d}.", .{ callee_name, required_arg_count, explicit_param_count, node.args.len }),
                    .labels = &.{
                        diagnostics.primaryLabel(node.span, "call uses the wrong number of arguments"),
                    },
                    .help = "Update the call so it matches the function signature exactly.",
                });
                return error.DiagnosticsEmitted;
            }
            var args = std.array_list.Managed(*model.Expr).init(ctx.allocator);
            var index: usize = 0;
            while (index < explicit_param_count) : (index += 1) {
                if (index < node.args.len) {
                    const arg = node.args[index];
                    try args.append(try lowerCallArgument(ctx, arg.value, resolved_header.params[index], shared.paramOwnership(resolved_header, index), callee_name, imports, scope, headers, node.span));
                    continue;
                }
                const default_expr = resolved_header.param_defaults[index] orelse return error.DiagnosticsEmitted;
                try args.append(try lowerCallArgument(ctx, default_expr, resolved_header.params[index], shared.paramOwnership(resolved_header, index), callee_name, imports, scope, headers, node.span));
            }
            if (trailing_callback_type) |callback_type| {
                try args.append(try lowerTrailingCallbackValue(ctx, node, callback_type, imports, scope, headers));
            }
            lowered.* = .{ .call = .{
                .callee_name = callee_name,
                .function_id = resolved_header.id,
                .args = try args.toOwnedSlice(),
                .trailing_builder = if (trailing_callback_type == null and node.trailing_builder != null) try lowerBuilderBlock(ctx, node.trailing_builder.?, imports, scope, function_headers) else null,
                .ty = resolved_header.return_type,
                .span = node.span,
            } };
            return;
        }
    }

    const can_fallback_to_leaf_type = !is_qualified_callee or qualified_type_fits;

    if (ctx.type_headers) |headers| {
        if (headers.get(callee_name) != null or (can_fallback_to_leaf_type and headers.get(callee_leaf) != null)) {
            // A declaration with `@Content` fields routes its trailing `{ ... }` block into those
            // fields (single `Widget`, `[Widget]` list, or named fills) as ordinary field args.
            const content_args = try buildContentArgs(ctx, callee_name, callee_leaf, node);
            lowered.* = try lowerTypeConstruction(ctx, callee_name, callee_leaf, content_args orelse node.args, &.{}, node.span, imports, scope, function_headers);
            return;
        }
    }

    if (ctx.imported_globals.findType(callee_name) != null or (can_fallback_to_leaf_type and ctx.imported_globals.findType(callee_leaf) != null)) {
        lowered.* = try lowerTypeConstruction(ctx, callee_name, callee_leaf, node.args, &.{}, node.span, imports, scope, function_headers);
        return;
    }

    if (ctx.imported_globals.hasCallable(callee_name)) {
        if (node.trailing_callback != null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM081",
                .title = "call does not accept a trailing callback",
                .message = "This callable is not declared with a typed final callback parameter, so trailing callback syntax cannot bind here.",
                .labels = &.{diagnostics.primaryLabel(node.span, "trailing callback cannot bind here")},
                .help = "Use a direct function or method that declares the callback parameter explicitly, or pass an ordinary argument.",
            });
            return error.DiagnosticsEmitted;
        }
        var args = std.array_list.Managed(*model.Expr).init(ctx.allocator);
        for (node.args) |arg| try args.append(try lowerExpr(ctx, arg.value, imports, scope, function_headers));
        lowered.* = .{ .call = .{
            .callee_name = callee_name,
            .function_id = null,
            .args = try args.toOwnedSlice(),
            .trailing_builder = if (node.trailing_builder) |builder| try lowerBuilderBlock(ctx, builder, imports, scope, function_headers) else null,
            .ty = .{ .kind = .unknown },
            .span = node.span,
        } };
        return;
    }

    if (std.mem.indexOfScalar(u8, callee_name, '.')) |root_end| {
        if (shared.isImportedRoot(ctx, callee_name[0..root_end], imports)) {
            if (function_headers) |headers| {
                const type_field_count = localOrImportedTypeFieldCount(ctx, callee_name, callee_leaf);
                const namespaced_type_fits = if (type_field_count) |field_count|
                    node.args.len <= field_count
                else
                    false;
                const namespaced_qualified = shared.importedQualifiedName(ctx, imports, callee_name);
                const namespaced_header = (if (namespaced_qualified) |qualified| shared.findFunctionHeader(ctx, headers, qualified) else null) orelse
                    shared.findFunctionHeader(ctx, headers, callee_name) orelse
                    (if (!namespaced_type_fits) shared.findFunctionHeader(ctx, headers, callee_leaf) else null);
                if (namespaced_header) |resolved_header| {
                    const trailing_callback_type = try trailingCallbackType(ctx, node, resolved_header.params);
                    const explicit_param_count = resolved_header.params.len - (if (trailing_callback_type != null) @as(usize, 1) else 0);
                    const required_arg_count = requiredExplicitArgCount(resolved_header.param_defaults, explicit_param_count);
                    if (node.args.len < required_arg_count or node.args.len > explicit_param_count) {
                        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                            .severity = .@"error",
                            .code = "KSEM042",
                            .title = "wrong number of arguments",
                            .message = try std.fmt.allocPrint(ctx.allocator, "The call to '{s}' expected between {d} and {d} explicit argument(s) but received {d}.", .{ callee_name, required_arg_count, explicit_param_count, node.args.len }),
                            .labels = &.{diagnostics.primaryLabel(node.span, "call uses the wrong number of arguments")},
                            .help = "Update the call so it matches the function signature exactly.",
                        });
                        return error.DiagnosticsEmitted;
                    }
                    var args = std.array_list.Managed(*model.Expr).init(ctx.allocator);
                    var index: usize = 0;
                    while (index < explicit_param_count) : (index += 1) {
                        if (index < node.args.len) {
                            const arg = node.args[index];
                            try args.append(try lowerCallArgument(ctx, arg.value, resolved_header.params[index], shared.paramOwnership(resolved_header, index), callee_name, imports, scope, headers, node.span));
                            continue;
                        }
                        const default_expr = resolved_header.param_defaults[index] orelse return error.DiagnosticsEmitted;
                        try args.append(try lowerCallArgument(ctx, default_expr, resolved_header.params[index], shared.paramOwnership(resolved_header, index), callee_name, imports, scope, headers, node.span));
                    }
                    if (trailing_callback_type) |callback_type| {
                        try args.append(try lowerTrailingCallbackValue(ctx, node, callback_type, imports, scope, headers));
                    }
                    lowered.* = .{ .call = .{
                        .callee_name = callee_name,
                        .function_id = resolved_header.id,
                        .args = try args.toOwnedSlice(),
                        .trailing_builder = if (trailing_callback_type == null and node.trailing_builder != null) try lowerBuilderBlock(ctx, node.trailing_builder.?, imports, scope, function_headers) else null,
                        .ty = resolved_header.return_type,
                        .span = node.span,
                    } };
                    return;
                }
            }
        }
    }

    if (function_headers) |headers| {
        if (try lowerImplicitSelfMethodCall(ctx, node, imports, scope, headers)) |call_expr| {
            lowered.* = call_expr;
            return;
        }
    }

    if (function_headers != null and isCallableValueExpr(node.callee, scope)) {
        const callee = try lowerExpr(ctx, node.callee, imports, scope, function_headers);
        if (try function_types.parseSignature(ctx.allocator, model.hir.exprType(callee.*))) |signature| {
            if (node.trailing_builder != null or node.trailing_callback != null) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM082",
                    .title = "callable value does not accept a trailing builder",
                    .message = "Trailing blocks currently attach only to direct calls with known final callback parameters or builder-aware call sites.",
                    .labels = &.{diagnostics.primaryLabel(node.span, "trailing block cannot bind here")},
                    .help = "Call the value with ordinary arguments, or call a direct function or method that declares the callback parameter explicitly.",
                });
                return error.DiagnosticsEmitted;
            }
            if (node.args.len != signature.params.len) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM042",
                    .title = "wrong number of arguments",
                    .message = try std.fmt.allocPrint(ctx.allocator, "This callable value expected {d} argument(s) but received {d}.", .{ signature.params.len, node.args.len }),
                    .labels = &.{diagnostics.primaryLabel(node.span, "call uses the wrong number of arguments")},
                    .help = "Update the call so it matches the callable value type exactly.",
                });
                return error.DiagnosticsEmitted;
            }
            var args = std.array_list.Managed(*model.Expr).init(ctx.allocator);
            for (node.args, 0..) |arg, index| {
                try args.append(try lowerCallArgument(
                    ctx,
                    arg.value,
                    signature.params[index],
                    if (index < signature.param_ownership.len) signature.param_ownership[index] else .owned,
                    "callable value",
                    imports,
                    scope,
                    function_headers.?,
                    node.span,
                ));
            }
            lowered.* = .{ .call_value = .{
                .callee = callee,
                .args = try args.toOwnedSlice(),
                .param_types = signature.params,
                .param_ownership = signature.param_ownership,
                .ty = signature.result,
                .span = node.span,
            } };
            return;
        }
        if (node.callee.* == .member) {
            try diagnostics.Emitter.init(ctx.allocator, ctx.diagnostics).err(.{
                .code = "KSEM092",
                .title = "member is not callable",
                .message = "This member access resolves to a field, but the field does not have a function type.",
                .span = node.span,
                .label = "member call target is not a function-typed field",
                .help = "Call only methods or fields declared with a function type such as `(RawPtr) -> Void`.",
            });
            return error.DiagnosticsEmitted;
        }
    }

    _ = try shared.resolveLocalOrCapture(ctx, scope.*, callee_leaf, node.span);

    if (std.mem.indexOfScalar(u8, callee_name, '.')) |root_end| {
        if (!shared.isImportedRoot(ctx, callee_name[0..root_end], imports)) {
            if (ctx.missingImportForSymbol(callee_name[0..root_end])) |module| {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM027",
                    .title = "invalid namespaced reference",
                    .message = try std.fmt.allocPrint(ctx.allocator, "'{s}' is defined in module '{s}', which this file does not import.", .{ callee_name[0..root_end], module }),
                    .labels = &.{diagnostics.primaryLabel(node.span, "namespace root is not visible in this file")},
                    .help = try std.fmt.allocPrint(ctx.allocator, "Add `import {s}` to this file (imports are per-file).", .{module}),
                });
                return error.DiagnosticsEmitted;
            }
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
        if (node.trailing_callback != null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM081",
                .title = "call does not accept a trailing callback",
                .message = "This namespaced call is not declared with a typed final callback parameter, so trailing callback syntax cannot bind here.",
                .labels = &.{diagnostics.primaryLabel(node.span, "trailing callback cannot bind here")},
                .help = "Use a direct function or method that declares the callback parameter explicitly, or pass an ordinary argument.",
            });
            return error.DiagnosticsEmitted;
        }
        var args = std.array_list.Managed(*model.Expr).init(ctx.allocator);
        for (node.args) |arg| try args.append(try lowerExpr(ctx, arg.value, imports, scope, function_headers));
        lowered.* = .{ .call = .{
            .callee_name = callee_name,
            .function_id = null,
            .args = try args.toOwnedSlice(),
            .trailing_builder = if (node.trailing_builder) |builder| try lowerBuilderBlock(ctx, builder, imports, scope, function_headers) else null,
            .ty = .{ .kind = .unknown },
            .span = node.span,
        } };
        return;
    }

    if (ctx.missingImportForSymbol(callee_leaf) orelse ctx.missingImportForSymbol(callee_name)) |module| {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM010",
            .title = "unknown call target",
            .message = try std.fmt.allocPrint(ctx.allocator, "'{s}' is defined in module '{s}', which this file does not import.", .{ callee_name, module }),
            .labels = &.{diagnostics.primaryLabel(node.span, "function is not visible in this file")},
            .help = try std.fmt.allocPrint(ctx.allocator, "Add `import {s}` to this file (imports are per-file).", .{module}),
        });
        return error.DiagnosticsEmitted;
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
