const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const function_types = @import("function_types.zig");
const comptime_eval = @import("lower_exprs_comptime.zig");
const async_spine = @import("lower_exprs_async.zig");
const resolution = @import("lower_exprs_call_resolution.zig");
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

pub fn lowerCallExpr(
    ctx: *shared.Context,
    lowered: *model.Expr,
    node: syntax.ast.CallExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    // A `name!(...)` macro call must have been removed by the macro-expansion pass. Reaching here
    // means no declarative macro of that name was in scope.
    if (node.is_macro) {
        const macro_name = if (node.callee.* == .identifier and node.callee.identifier.name.segments.len == 1)
            node.callee.identifier.name.segments[0].text
        else
            "<expression>";
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KMAC001",
            .title = "unknown macro",
            .message = try std.fmt.allocPrint(ctx.allocator, "no declarative macro named '{s}' is in scope.", .{macro_name}),
            .labels = &.{diagnostics.primaryLabel(node.span, "this macro is not declared")},
            .help = "Declare it with `macro <name>(...) { expand { ... } }`, or remove the `!` to call a function.",
        });
        return error.DiagnosticsEmitted;
    }
    if (async_spine.isTaskSpawn(node)) {
        return async_spine.lowerTaskSpawn(ctx, lowered, node, imports, scope, function_headers);
    }
    if (async_spine.isTaskYield(node) and scope.get("taskYield") == null and (function_headers == null or shared.findFunctionHeader(ctx, function_headers.?, "taskYield") == null)) {
        return async_spine.lowerTaskYield(ctx, lowered, node);
    }
    if (async_spine.isTaskSleep(node) and scope.get("taskSleep") == null and (function_headers == null or shared.findFunctionHeader(ctx, function_headers.?, "taskSleep") == null)) {
        return async_spine.lowerTaskSleep(ctx, lowered, node, imports, scope, function_headers);
    }
    if (node.callee.* == .member) {
        const member = node.callee.member;
        if (async_spine.isHandleNoopMethod(member)) {
            return async_spine.lowerHandleNoop(ctx, lowered, node, member, imports, scope, function_headers);
        }
        if (try lowerParentQualifiedMethodCall(ctx, node, imports, scope, function_headers)) |call_expr| {
            lowered.* = call_expr;
            return;
        }
        const flattened_member = try flattenMemberExpr(ctx.allocator, node.callee);
        const is_static_callable = scope.get(flattened_member.root) == null and
            function_headers != null and
            shared.findFunctionHeader(ctx, function_headers.?, flattened_member.path) != null;
        if (is_static_callable) {
            if (ctx.form_families != null and ctx.form_families.?.get(flattened_member.root) != null) {
                const receiver = try ctx.allocator.create(model.Expr);
                receiver.* = try lowerTypeConstruction(ctx, flattened_member.root, flattened_member.root, &.{}, &.{}, node.span, imports, scope, function_headers);
                const receiver_type = model.hir.exprType(receiver.*);
                if (try resolveMethodMemberOrNull(ctx, receiver_type, member.member, node.span)) |resolved_method| {
                    const dispatched = try buildDispatchedMethodCallExpr(ctx, resolved_method, receiver, receiver_type, node, imports, scope, function_headers);
                    lowered.* = dispatched.*;
                    return;
                }
            }
        } else if (shared.isImportedRoot(ctx, flattened_member.root, imports) and scope.get(flattened_member.root) == null) {
            // Imported namespace calls such as `Foundation.Text(...)` are not instance methods.
            // Fall through so ordinary function resolution has a chance before constructor
            // fallback examines the leaf type name.
        } else {
            const object = try lowerExpr(ctx, member.object, imports, scope, function_headers);
            const object_type = model.hir.exprType(object.*);
            if (object_type.kind == .array and std.mem.eql(u8, member.member, "append")) {
                if (node.args.len != 1) {
                    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM042",
                        .title = "wrong number of arguments",
                        .message = "Array append expects exactly one value.",
                        .labels = &.{diagnostics.primaryLabel(node.span, "append call has the wrong number of arguments")},
                        .help = "Call `array.append(value)` with exactly one element.",
                    });
                    return error.DiagnosticsEmitted;
                }
                const element_type = if (object_type.name) |name| try shared.resolvedTypeFromText(name) else model.ResolvedType{ .kind = .unknown };
                const value = try lowerCallArgument(ctx, node.args[0].value, element_type, .owned, "array.append", imports, scope, function_headers orelse return error.DiagnosticsEmitted, node.span);
                const args = try ctx.allocator.alloc(*model.Expr, 2);
                args[0] = object;
                args[1] = value;
                lowered.* = .{ .call = .{
                    .callee_name = "array.append",
                    .function_id = null,
                    .args = args,
                    .ty = .{ .kind = .void },
                    .span = node.span,
                } };
                return;
            }
            if (object_type.kind == .array) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM101",
                    .title = "unsupported array method",
                    .message = try std.fmt.allocPrint(ctx.allocator, "Array method '{s}' is not supported.", .{member.member}),
                    .labels = &.{diagnostics.primaryLabel(node.span, "unsupported array method")},
                    .help = "Use `array.append(value)` for growth; resizing, pop, and remove are not part of the supported array surface.",
                });
                return error.DiagnosticsEmitted;
            }
            if (object_type.kind == .string) {
                if (try lowerStringMethodOrNull(ctx, object, member.member, node, imports, scope, function_headers)) |string_method| {
                    lowered.* = string_method;
                    return;
                }
            }
            if (object_type.kind != .native_state_view) {
                if (try resolveMethodMemberOrNull(ctx, object_type, member.member, node.span)) |resolved_method| {
                    const dispatched = try buildDispatchedMethodCallExpr(ctx, resolved_method, object, object_type, node, imports, scope, function_headers);
                    lowered.* = dispatched.*;
                    return;
                }
            }
        }
    }

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
        if (arg_ty.kind == .named) {
            if (shared.namedTypeHeader(ctx, arg_ty)) |type_header| {
                if (type_header.is_printable) {
                    const method_key = try std.fmt.allocPrint(ctx.allocator, "{s}.onPrint", .{arg_ty.name.?});
                    const header = function_headers.?.get(method_key) orelse return error.DiagnosticsEmitted;
                    const lowered_receiver = args.items[0];
                    const lowered_call = try ctx.allocator.create(model.Expr);
                    const call_args = try ctx.allocator.alloc(*model.Expr, 1);
                    call_args[0] = lowered_receiver;
                    lowered_call.* = .{ .call = .{
                        .callee_name = method_key,
                        .function_id = header.id,
                        .args = call_args,
                        .ty = header.return_type,
                        .span = node.span,
                    } };
                    args.items[0] = lowered_call;
                }
            }
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

    // `floatToBits(x)` / `bitsToFloat(x)` — bit-reinterpret between a Float and
    // its raw bits (Kira Float is f64, so the bit pattern is a U64). Unlike the
    // numeric casts below these preserve the exact bit pattern, and like them they
    // are builtins, not user-callable functions, so an un-shadowed call is always
    // the builtin.
    if (scope.get(callee_name) == null) reinterpret_cast: {
        const is_ftb = std.mem.eql(u8, callee_name, "floatToBits");
        const is_btf = std.mem.eql(u8, callee_name, "bitsToFloat");
        if (!is_ftb and !is_btf) break :reinterpret_cast;
        if (node.args.len != 1 or node.args[0].label != null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM118",
                .title = "invalid bit reinterpret",
                .message = try std.fmt.allocPrint(ctx.allocator, "`{s}(...)` takes exactly one positional argument.", .{callee_name}),
                .labels = &.{diagnostics.primaryLabel(node.span, "reinterpret call has the wrong arguments")},
                .help = "Write it as `floatToBits(value)` or `bitsToFloat(value)` with a single argument.",
            });
            return error.DiagnosticsEmitted;
        }
        const operand = try lowerExpr(ctx, node.args[0].value, imports, scope, function_headers);
        const operand_ty = model.hir.exprType(operand.*);
        const want_float_operand = is_btf;
        const ok = if (want_float_operand) operand_ty.kind == .integer else operand_ty.kind == .float;
        if (!ok) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM118",
                .title = "invalid bit reinterpret",
                .message = if (is_ftb)
                    try std.fmt.allocPrint(ctx.allocator, "`floatToBits(...)` expects a `Float` value.", .{})
                else
                    try std.fmt.allocPrint(ctx.allocator, "`bitsToFloat(...)` expects an integer value.", .{}),
                .labels = &.{diagnostics.primaryLabel(node.span, "operand has the wrong type")},
                .help = "floatToBits takes a Float and returns U64 bits; bitsToFloat takes U64 bits and returns a Float.",
            });
            return error.DiagnosticsEmitted;
        }
        const target_type = if (is_ftb)
            (shared.numericCastTargetType("U64") orelse unreachable)
        else
            (shared.numericCastTargetType("Float") orelse unreachable);
        lowered.* = .{ .cast = .{
            .operand = operand,
            .ty = target_type,
            .span = node.span,
            .reinterpret = true,
        } };
        return;
    }

    // `String(x)` — deterministic scalar -> String conversion, joining the cast
    // family (a primitive type name used as a call). `String` is not a
    // user-callable function, so an un-shadowed call is always this cast.
    // Integers render base-10, Bool as "true"/"false", Float matching the
    // per-backend `print(float)` output.
    if (scope.get(callee_name) == null and std.mem.eql(u8, callee_name, "String")) {
        if (node.args.len != 1 or node.args[0].label != null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM118",
                .title = "invalid String conversion",
                .message = try std.fmt.allocPrint(ctx.allocator, "`String(...)` converts a single scalar value to a String and takes exactly one positional argument.", .{}),
                .labels = &.{diagnostics.primaryLabel(node.span, "String conversion has the wrong arguments")},
                .help = "Write it as `String(value)` with a single Int, Bool, or Float value.",
            });
            return error.DiagnosticsEmitted;
        }
        const operand = try lowerExpr(ctx, node.args[0].value, imports, scope, function_headers);
        const operand_ty = model.hir.exprType(operand.*);
        const source_kind: model.hir.StringFromScalarSource = switch (operand_ty.kind) {
            .integer => .integer,
            .float => .float,
            .boolean => .boolean,
            else => {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM118",
                    .title = "invalid String conversion",
                    .message = try std.fmt.allocPrint(ctx.allocator, "`String(...)` can only convert `Int`, `Bool`, or `Float` values.", .{}),
                    .labels = &.{diagnostics.primaryLabel(node.span, "operand is not a scalar value")},
                    .help = "Pass an `Int`, `Bool`, or `Float` expression to `String(...)`.",
                });
                return error.DiagnosticsEmitted;
            },
        };
        lowered.* = .{ .string_from_scalar = .{
            .operand = operand,
            .source_kind = source_kind,
            .span = node.span,
        } };
        return;
    }

    // `Int(x)` / `Float(x)` / width-specific (`U64(x)`, `I32(x)`, `F32(x)`, …)
    // numeric casts. Recognized before ordinary function and constructor
    // resolution: these are primitive type names, not user-callable functions,
    // so a call against an un-shadowed one is always a cast.
    if (scope.get(callee_name) == null) numeric_cast: {
        const target_type = shared.numericCastTargetType(callee_name) orelse break :numeric_cast;
        if (node.args.len != 1 or node.args[0].label != null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM118",
                .title = "invalid numeric cast",
                .message = try std.fmt.allocPrint(ctx.allocator, "`{s}(...)` is a numeric cast and takes exactly one positional argument.", .{callee_name}),
                .labels = &.{diagnostics.primaryLabel(node.span, "cast call has the wrong arguments")},
                .help = "Write the cast as `Int(value)`, `Float(value)`, or a width form like `U64(value)` / `F32(value)` with a single numeric value.",
            });
            return error.DiagnosticsEmitted;
        }
        const operand = try lowerExpr(ctx, node.args[0].value, imports, scope, function_headers);
        const operand_ty = model.hir.exprType(operand.*);
        if (operand_ty.kind != .integer and operand_ty.kind != .float) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM118",
                .title = "invalid numeric cast",
                .message = try std.fmt.allocPrint(ctx.allocator, "`{s}(...)` can only convert `Int` or `Float` values.", .{callee_name}),
                .labels = &.{diagnostics.primaryLabel(node.span, "operand is not a numeric value")},
                .help = "Pass an `Int` or `Float` expression to the cast.",
            });
            return error.DiagnosticsEmitted;
        }
        lowered.* = .{ .cast = .{
            .operand = operand,
            .ty = target_type,
            .span = node.span,
        } };
        return;
    }

    return resolution.lowerResolvedCall(
        ctx,
        lowered,
        node,
        imports,
        scope,
        function_headers,
        callee_name,
        callee_leaf,
    );
}
