//! Async task lowering (deferred execution).
//!
//! `Task { f(a, b) }` lowers to `hir.task_spawn`: the args are evaluated at the
//! spawn site, the CALL runs when the task is first driven — `handle.await`
//! (`hir.task_await`) joins it and yields the result, `handle.detach()`
//! (`hir.task_detach`) drives and discards. `handle.requestCancel()`
//! (`hir.task_cancel`) sets the cooperative flag; a cancel observed before the
//! first drive prevents the call from ever running, and a later await traps.
//! `Task { <pure literal> }` lowers to `hir.task_spawn_ready` (an
//! already-completed task). Joining twice traps on both backends.
//!
//! Restricted slice (KSEM159): the task body must be a direct call to a named
//! function whose parameters and result are scalars (Int/Float/Bool — result
//! may also be Void), or a pure scalar literal. Richer bodies and captured
//! aggregates arrive with the closure-based spawn.
//!
//! The handle stays checker-transparent (its static type is the task's result
//! type); misuse is rejected by the KSEM158 task-handle guard, so no code can
//! observe the underlying runtime representation (a task pointer).
const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const parent = @import("lower_exprs.zig");
const lowerExpr = parent.lowerExpr;

/// Recognizes the `taskYield()` intrinsic: a bare call with that exact name.
pub fn isTaskYield(node: syntax.ast.CallExpr) bool {
    return node.callee.* == .identifier and
        node.callee.identifier.name.segments.len == 1 and
        std.mem.eql(u8, node.callee.identifier.name.segments[0].text, "taskYield") and
        node.trailing_builder == null and node.trailing_callback == null;
}

/// Lower `taskYield()`: a cooperative progress point — the executor runs the
/// next queued task (if any) before this body continues.
pub fn lowerTaskYield(
    ctx: *shared.Context,
    lowered: *model.Expr,
    node: syntax.ast.CallExpr,
) !void {
    if (node.args.len != 0) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM157",
            .title = "taskYield takes no arguments",
            .message = "`taskYield()` is called with no arguments.",
            .labels = &.{diagnostics.primaryLabel(node.span, "unexpected arguments")},
            .help = "Call it as `taskYield()`.",
        });
        return error.DiagnosticsEmitted;
    }
    lowered.* = .{ .task_yield = .{ .span = node.span } };
}

/// Recognizes the `taskSleep(ms)` intrinsic.
pub fn isTaskSleep(node: syntax.ast.CallExpr) bool {
    return node.callee.* == .identifier and
        node.callee.identifier.name.segments.len == 1 and
        std.mem.eql(u8, node.callee.identifier.name.segments[0].text, "taskSleep") and
        node.trailing_builder == null and node.trailing_callback == null;
}

/// Lower `taskSleep(ms)`: park the current task for at least `ms`
/// milliseconds; the executor wakes it when the deadline passes.
pub fn lowerTaskSleep(
    ctx: *shared.Context,
    lowered: *model.Expr,
    node: syntax.ast.CallExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    if (node.args.len != 1) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM157",
            .title = "taskSleep takes one Int argument",
            .message = "`taskSleep(ms)` parks the current task for at least `ms` milliseconds.",
            .labels = &.{diagnostics.primaryLabel(node.span, "expected exactly one argument")},
            .help = "Call it as `taskSleep(10)`.",
        });
        return error.DiagnosticsEmitted;
    }
    const ms = try lowerExpr(ctx, node.args[0].value, imports, scope, function_headers);
    if (model.hir.exprType(ms.*).kind != .integer) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM157",
            .title = "taskSleep takes one Int argument",
            .message = "The sleep duration is an Int of milliseconds.",
            .labels = &.{diagnostics.primaryLabel(node.span, "duration is not an Int")},
            .help = "Pass a millisecond count, e.g. `taskSleep(10)`.",
        });
        return error.DiagnosticsEmitted;
    }
    lowered.* = .{ .task_sleep = .{ .milliseconds = ms, .span = node.span } };
}

/// Recognizes the `Task { ... }` spawn form: `Task` called with a trailing
/// builder block and no positional arguments.
pub fn isTaskSpawn(node: syntax.ast.CallExpr) bool {
    return node.callee.* == .identifier and
        node.callee.identifier.name.segments.len == 1 and
        std.mem.eql(u8, node.callee.identifier.name.segments[0].text, "Task") and
        node.trailing_builder != null;
}

fn isScalarKind(kind: model.Type) bool {
    return kind == .integer or kind == .float or kind == .boolean;
}

fn emitTaskBodyRestriction(ctx: *shared.Context, span: anytype, detail: []const u8) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM159",
        .title = "unsupported task body",
        .message = try std.fmt.allocPrint(ctx.allocator, "The task spine spawns a direct call to a named function with scalar (Int/Float/Bool) parameters and a scalar or Void result, or a pure scalar literal. {s}", .{detail}),
        .labels = &.{diagnostics.primaryLabel(span, "this task body is not supported yet")},
        .help = "Move the work into a function with scalar parameters and spawn it, e.g. `Task { doWork(n) }`.",
    });
    return error.DiagnosticsEmitted;
}

/// Lower `Task { expr }` to a deferred spawn.
pub fn lowerTaskSpawn(
    ctx: *shared.Context,
    lowered: *model.Expr,
    node: syntax.ast.CallExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    if (node.args.len != 0) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM157",
            .title = "Task takes no call arguments",
            .message = "Spawn work with the trailing block form `Task { expr }`; `Task(...)` does not take positional arguments.",
            .labels = &.{diagnostics.primaryLabel(node.span, "unexpected arguments to Task")},
            .help = "Write the work inside the trailing block, e.g. `Task { compute() }`.",
        });
        return error.DiagnosticsEmitted;
    }
    const builder = node.trailing_builder.?;
    if (builder.items.len != 1 or builder.items[0] != .expr) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM157",
            .title = "Task block must be a single expression",
            .message = "The task spine spawns exactly one expression: `Task { expr }`.",
            .labels = &.{diagnostics.primaryLabel(node.span, "expected a single expression in the task block")},
            .help = "Move multi-statement work into a function and spawn it, e.g. `Task { doWork() }`.",
        });
        return error.DiagnosticsEmitted;
    }

    const body = try lowerExpr(ctx, builder.items[0].expr.expr, imports, scope, function_headers);
    switch (body.*) {
        // Pure scalar literal: an already-completed task.
        .integer, .float, .boolean => {
            lowered.* = .{ .task_spawn_ready = .{
                .value = body,
                .ty = model.hir.exprType(body.*),
                .span = node.span,
            } };
        },
        // Direct call to a named function: defer the call, keep the
        // already-lowered (and therefore already-checked) args.
        .call => |call| {
            const function_id = call.function_id orelse
                return emitTaskBodyRestriction(ctx, node.span, "The callee could not be resolved to a named function.");
            if (call.trailing_builder != null)
                return emitTaskBodyRestriction(ctx, node.span, "Builder-block callees cannot be spawned yet.");
            for (call.args) |arg| {
                if (!isScalarKind(model.hir.exprType(arg.*).kind))
                    return emitTaskBodyRestriction(ctx, node.span, "A task argument is not a scalar.");
            }
            // A Void (or implicitly-void) callee's task joins as Int 0: the
            // handle needs a value-typed static type (a void-typed local has no
            // storage layout), and both runtimes yield a zero payload for a
            // void completion. `await`ing such a task is only useful for its
            // sequencing effect.
            const returns_void = call.ty.kind == .void or call.ty.kind == .unknown;
            const result_ty: model.ResolvedType = if (returns_void)
                .{ .kind = .integer }
            else
                call.ty;
            if (!isScalarKind(result_ty.kind))
                return emitTaskBodyRestriction(ctx, node.span, "The callee's result is not a scalar or Void.");
            lowered.* = .{ .task_spawn = .{
                .callee_name = call.callee_name,
                .function_id = function_id,
                .args = call.args,
                .ty = result_ty,
                .span = node.span,
            } };
        },
        else => return emitTaskBodyRestriction(ctx, node.span, "Only direct calls and scalar literals are spawnable."),
    }
}

/// Classification of an `.await` / `.requestCancel()` / `.detach()` receiver.
const TaskReceiver = union(enum) {
    /// The lowered handle expression (a task-handle local read or an inline
    /// `Task { ... }` spawn).
    handle: *model.Expr,
};

/// Lower the receiver of a task operation, requiring it to actually be a task
/// handle: a binding initialized from `Task { ... }` (KSEM158 guard flag) or an
/// inline spawn expression.
fn lowerTaskReceiver(
    ctx: *shared.Context,
    object: *syntax.ast.Expr,
    op_name: []const u8,
    span: anytype,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !*model.Expr {
    const is_handle_local = object.* == .identifier and
        object.identifier.name.segments.len == 1 and
        if (scope.get(object.identifier.name.segments[0].text)) |binding| binding.is_task_handle else false;
    const is_inline_spawn = object.* == .call and isTaskSpawn(object.call);
    if (!is_handle_local and !is_inline_spawn) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM159",
            .title = "task operation requires a task handle",
            .message = try std.fmt.allocPrint(ctx.allocator, "`{s}` operates on a task handle: a `let` binding initialized from `Task {{ ... }}` or an inline `Task {{ ... }}` expression.", .{op_name}),
            .labels = &.{diagnostics.primaryLabel(span, "not a task handle")},
            .help = "Spawn the work first, e.g. `let handle = Task { doWork() }`.",
        });
        return error.DiagnosticsEmitted;
    }
    const previous_allow = ctx.allow_task_handle_read;
    ctx.allow_task_handle_read = true;
    defer ctx.allow_task_handle_read = previous_allow;
    return lowerExpr(ctx, object, imports, scope, function_headers);
}

/// Lower `handle.await` to a join point (`hir.task_await`).
pub fn lowerTaskAwait(
    ctx: *shared.Context,
    lowered: *model.Expr,
    node: syntax.ast.MemberExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !*model.Expr {
    const task = try lowerTaskReceiver(ctx, node.object, "await", node.span, imports, scope, function_headers);
    lowered.* = .{ .task_await = .{
        .task = task,
        .ty = model.hir.exprType(task.*),
        .span = node.span,
    } };
    return lowered;
}

/// Recognizes a task-handle method: `handle.requestCancel()` or
/// `handle.detach()`.
pub fn isHandleNoopMethod(member: syntax.ast.MemberExpr) bool {
    return std.mem.eql(u8, member.member, "requestCancel") or
        std.mem.eql(u8, member.member, "detach");
}

/// Lower `handle.requestCancel()` / `handle.detach()`.
pub fn lowerHandleNoop(
    ctx: *shared.Context,
    lowered: *model.Expr,
    node: syntax.ast.CallExpr,
    member: syntax.ast.MemberExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    if (node.args.len != 0) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM157",
            .title = "task handle operation takes no arguments",
            .message = "`requestCancel()` and `detach()` are called with no arguments.",
            .labels = &.{diagnostics.primaryLabel(node.span, "unexpected arguments")},
            .help = "Call it as `handle.requestCancel()` or `handle.detach()`.",
        });
        return error.DiagnosticsEmitted;
    }
    const is_cancel = std.mem.eql(u8, member.member, "requestCancel");
    const task = try lowerTaskReceiver(ctx, member.object, member.member, node.span, imports, scope, function_headers);
    lowered.* = if (is_cancel)
        .{ .task_cancel = .{ .task = task, .span = node.span } }
    else
        .{ .task_detach = .{ .task = task, .span = node.span } };
}
