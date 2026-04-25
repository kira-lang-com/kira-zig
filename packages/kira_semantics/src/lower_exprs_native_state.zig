const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const parent = @import("lower_exprs.zig");
const lowerExpr = parent.lowerExpr;

pub fn lowerNativeStateExpr(
    ctx: *shared.Context,
    node: syntax.ast.NativeStateExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !model.Expr {
    const value = try lowerExpr(ctx, node.value, imports, scope, function_headers);
    const payload_type = try resolveNativeStatePayloadType(ctx, model.hir.exprType(value.*), node.span, "nativeState");
    return .{ .native_state = .{
        .value = value,
        .ty = .{ .kind = .native_state, .name = try ctx.allocator.dupe(u8, payload_type.name.?) },
        .span = node.span,
    } };
}

pub fn lowerNativeUserDataExpr(
    ctx: *shared.Context,
    node: syntax.ast.NativeUserDataExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !model.Expr {
    const state = try lowerExpr(ctx, node.state, imports, scope, function_headers);
    const state_type = model.hir.exprType(state.*);
    if (state_type.kind != .native_state or state_type.name == null) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM088",
            .title = "nativeUserData requires native state",
            .message = "`nativeUserData(...)` only accepts values previously created by `nativeState(...)`.",
            .labels = &.{diagnostics.primaryLabel(node.span, "this value is not a native state handle")},
            .help = "Create a handle with `nativeState(value)` first, then pass that handle to `nativeUserData`.",
        });
        return error.DiagnosticsEmitted;
    }
    return .{ .native_user_data = .{
        .state = state,
        .span = node.span,
    } };
}

pub fn lowerNativeRecoverExpr(
    ctx: *shared.Context,
    node: syntax.ast.NativeRecoverExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !model.Expr {
    const expected_type = try resolveNativeRecoverType(ctx, node.state_type, node.span);

    if (node.value.* == .native_user_data) {
        const direct_state = try lowerExpr(ctx, node.value.native_user_data.state, imports, scope, function_headers);
        const direct_state_type = model.hir.exprType(direct_state.*);
        if (direct_state_type.kind == .native_state and direct_state_type.name != null and !std.mem.eql(u8, direct_state_type.name.?, expected_type.name.?)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM091",
                .title = "native state type mismatch",
                .message = try std.fmt.allocPrint(ctx.allocator, "This userdata token came from `NativeState<{s}>`, but `nativeRecover` expects `{s}`.", .{
                    direct_state_type.name.?,
                    expected_type.name.?,
                }),
                .labels = &.{diagnostics.primaryLabel(node.span, "recovery type does not match the originating native state")},
                .help = "Recover the same type that was originally boxed with `nativeState(...)`.",
            });
            return error.DiagnosticsEmitted;
        }
    }

    const value = try lowerExpr(ctx, node.value, imports, scope, function_headers);
    const value_type = model.hir.exprType(value.*);
    if (value_type.kind != .raw_ptr) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM089",
            .title = "nativeRecover requires RawPtr",
            .message = "`nativeRecover<T>(...)` expects an opaque `RawPtr` userdata token.",
            .labels = &.{diagnostics.primaryLabel(node.span, "this value is not a RawPtr userdata token")},
            .help = "Pass the result of `nativeUserData(state)` or another `RawPtr` token returned by native code.",
        });
        return error.DiagnosticsEmitted;
    }

    return .{ .native_recover = .{
        .value = value,
        .ty = .{ .kind = .native_state_view, .name = try ctx.allocator.dupe(u8, expected_type.name.?) },
        .span = node.span,
    } };
}

fn resolveNativeStatePayloadType(
    ctx: *shared.Context,
    ty: model.ResolvedType,
    span: source_pkg.Span,
    builtin_name: []const u8,
) !model.ResolvedType {
    const candidate = switch (ty.kind) {
        .named => ty,
        .native_state_view => model.ResolvedType{ .kind = .named, .name = ty.name },
        else => model.ResolvedType{ .kind = .unknown },
    };

    if (candidate.kind == .named and candidate.name != null and shared.namedTypeHeader(ctx, candidate) != null and shared.namedTypeInfo(ctx, candidate) == null) {
        return candidate;
    }

    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM087",
        .title = "native state requires a Kira-owned type",
        .message = try std.fmt.allocPrint(ctx.allocator, "`{s}(...)` currently supports ordinary Kira struct or class values only.", .{builtin_name}),
        .labels = &.{diagnostics.primaryLabel(span, "this value is not a Kira-owned named type")},
        .help = "Box a regular Kira type such as `CounterState { ... }`. `@FFI.Struct` and raw pointer types are not valid here.",
    });
    return error.DiagnosticsEmitted;
}

fn resolveNativeRecoverType(
    ctx: *shared.Context,
    type_expr: *syntax.ast.TypeExpr,
    span: source_pkg.Span,
) !model.ResolvedType {
    const resolved = try shared.typeFromSyntaxChecked(ctx, type_expr.*);
    if (resolved.kind == .named and resolved.name != null and shared.namedTypeHeader(ctx, resolved) != null and shared.namedTypeInfo(ctx, resolved) == null) {
        return resolved;
    }

    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM090",
        .title = "nativeRecover requires a Kira-owned named type",
        .message = "`nativeRecover<T>(...)` only supports ordinary Kira struct or class types for `T`.",
        .labels = &.{diagnostics.primaryLabel(span, "this recovered type is not a Kira-owned named type")},
        .help = "Recover the same Kira-owned type that was originally boxed with `nativeState(...)`.",
    });
    return error.DiagnosticsEmitted;
}
