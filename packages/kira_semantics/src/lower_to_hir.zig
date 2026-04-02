const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const runtime_abi = @import("kira_runtime_abi");

const FunctionHeader = struct {
    id: u32,
    execution: runtime_abi.FunctionExecution,
};

pub fn lowerProgram(allocator: std.mem.Allocator, program: syntax.ast.Program, out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic)) !model.Program {
    var function_headers = std.StringHashMapUnmanaged(FunctionHeader){};
    defer function_headers.deinit(allocator);

    var functions = std.array_list.Managed(model.Function).init(allocator);
    var main_index: ?usize = null;

    for (program.functions, 0..) |function_decl, function_index| {
        const annotation_info = try resolveAnnotations(allocator, function_decl, out_diagnostics);
        if (function_headers.contains(function_decl.name)) {
            try out_diagnostics.append(diagnostics.single(.@"error", "duplicate function name", .{
                .span = function_decl.span,
                .message = "function names must be unique in the bootstrap subset",
            }));
            return error.SemanticFailed;
        }
        try function_headers.put(allocator, function_decl.name, .{
            .id = @as(u32, @intCast(function_index)),
            .execution = annotation_info.execution,
        });
    }

    for (program.functions, 0..) |function_decl, function_index| {
        const annotation_info = try resolveAnnotations(allocator, function_decl, out_diagnostics);
        const lowered = try lowerFunction(
            allocator,
            function_decl,
            @as(u32, @intCast(function_index)),
            annotation_info.is_main,
            annotation_info.execution,
            &function_headers,
            out_diagnostics,
        );
        if (annotation_info.is_main) {
            if (main_index != null) {
                try out_diagnostics.append(diagnostics.single(.@"error", "multiple @Main functions found", .{
                    .span = function_decl.span,
                    .message = "this function conflicts with an earlier @Main entrypoint",
                }));
                return error.SemanticFailed;
            }
            main_index = function_index;
        }
        try functions.append(lowered);
    }

    if (main_index == null) {
        try out_diagnostics.append(diagnostics.single(.@"error", "no @Main function found", .{
            .span = source_pkg.Span.init(0, 0),
            .message = "add @Main to exactly one function to make the module runnable",
        }));
        return error.MissingMain;
    }

    return .{
        .functions = try functions.toOwnedSlice(),
        .entry_index = main_index.?,
    };
}

const AnnotationInfo = struct {
    is_main: bool,
    execution: runtime_abi.FunctionExecution,
};

fn resolveAnnotations(
    allocator: std.mem.Allocator,
    function_decl: syntax.ast.FunctionDecl,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !AnnotationInfo {
    var is_main = false;
    var execution: runtime_abi.FunctionExecution = .inherited;

    for (function_decl.annotations) |annotation| {
        if (std.mem.eql(u8, annotation.name, "Main")) {
            if (is_main) {
                try out_diagnostics.append(diagnostics.single(.@"error", "duplicate @Main annotation", .{
                    .span = annotation.span,
                    .message = "@Main can only appear once on a function",
                }));
                return error.SemanticFailed;
            }
            is_main = true;
            continue;
        }
        if (std.mem.eql(u8, annotation.name, "Runtime")) {
            if (execution != .inherited) {
                try out_diagnostics.append(diagnostics.single(.@"error", "multiple execution annotations", .{
                    .span = annotation.span,
                    .message = "use at most one of @Runtime or @Native",
                }));
                return error.SemanticFailed;
            }
            execution = .runtime;
            continue;
        }
        if (std.mem.eql(u8, annotation.name, "Native")) {
            if (execution != .inherited) {
                try out_diagnostics.append(diagnostics.single(.@"error", "multiple execution annotations", .{
                    .span = annotation.span,
                    .message = "use at most one of @Runtime or @Native",
                }));
                return error.SemanticFailed;
            }
            execution = .native;
            continue;
        }

        const message = try std.fmt.allocPrint(allocator, "unsupported annotation '@{s}'", .{annotation.name});
        try out_diagnostics.append(diagnostics.single(.@"error", message, .{
            .span = annotation.span,
            .message = "only @Main, @Runtime, and @Native are supported in the bootstrap subset",
        }));
        return error.SemanticFailed;
    }

    return .{ .is_main = is_main, .execution = execution };
}

fn lowerFunction(
    allocator: std.mem.Allocator,
    function_decl: syntax.ast.FunctionDecl,
    function_id: u32,
    is_main: bool,
    execution: runtime_abi.FunctionExecution,
    function_headers: *const std.StringHashMapUnmanaged(FunctionHeader),
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !model.Function {
    var scope = model.Scope{};
    defer scope.deinit(allocator);

    var locals = std.array_list.Managed(model.LocalSymbol).init(allocator);
    var body = std.array_list.Managed(model.Statement).init(allocator);

    for (function_decl.body.statements) |statement| {
        try body.append(try lowerStatement(allocator, statement, &scope, &locals, function_headers, out_diagnostics));
    }

    return .{
        .id = function_id,
        .name = function_decl.name,
        .is_main = is_main,
        .execution = execution,
        .locals = try locals.toOwnedSlice(),
        .body = try body.toOwnedSlice(),
        .span = function_decl.span,
    };
}

fn lowerStatement(
    allocator: std.mem.Allocator,
    statement: syntax.ast.Statement,
    scope: *model.Scope,
    locals: *std.array_list.Managed(model.LocalSymbol),
    function_headers: *const std.StringHashMapUnmanaged(FunctionHeader),
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !model.Statement {
    return switch (statement) {
        .let_stmt => |node| blk: {
            const value = try lowerExpr(allocator, node.value, scope, out_diagnostics);
            const ty = model.hir.exprType(value.*);
            const local_id = @as(u32, @intCast(locals.items.len));
            try scope.put(allocator, node.name, .{ .id = local_id, .ty = ty });
            try locals.append(.{
                .id = local_id,
                .name = node.name,
                .ty = ty,
                .span = node.span,
            });
            break :blk .{ .let_stmt = .{
                .local_id = local_id,
                .value = value,
                .span = node.span,
            } };
        },
        .expr_stmt => |node| blk: {
            switch (node.expr.*) {
                .call => |call| {
                    if (std.mem.eql(u8, call.callee, "print")) {
                        if (call.args.len != 1) {
                            try out_diagnostics.append(diagnostics.single(.@"error", "print expects exactly one argument", .{
                                .span = call.span,
                                .message = "builtin print takes one value",
                            }));
                            return error.SemanticFailed;
                        }
                        const lowered_arg = try lowerExpr(allocator, call.args[0], scope, out_diagnostics);
                        const arg_ty = model.hir.exprType(lowered_arg.*);
                        if (arg_ty != .integer and arg_ty != .string) {
                            try out_diagnostics.append(diagnostics.single(.@"error", "print argument type is unsupported", .{
                                .span = call.span,
                                .message = "print currently accepts integers and strings only",
                            }));
                            return error.SemanticFailed;
                        }
                        break :blk .{ .print_stmt = .{
                            .value = lowered_arg,
                            .span = node.span,
                        } };
                    }

                    if (call.args.len != 0) {
                        try out_diagnostics.append(diagnostics.single(.@"error", "bootstrap function calls do not take arguments yet", .{
                            .span = call.span,
                            .message = "user-defined calls currently use zero arguments only",
                        }));
                        return error.SemanticFailed;
                    }

                    const target = function_headers.get(call.callee) orelse {
                        try out_diagnostics.append(diagnostics.single(.@"error", "unknown call target", .{
                            .span = call.span,
                            .message = "declare the function before using it",
                        }));
                        return error.SemanticFailed;
                    };
                    break :blk .{ .call_stmt = .{
                        .function_id = target.id,
                        .name = call.callee,
                        .execution = target.execution,
                        .span = node.span,
                    } };
                },
                else => {
                    try out_diagnostics.append(diagnostics.single(.@"error", "expression statements must be calls", .{
                        .span = node.span,
                        .message = "only print(...) or zero-argument function calls are allowed as statements",
                    }));
                    return error.SemanticFailed;
                },
            }
        },
        .return_stmt => |node| .{ .return_stmt = .{ .span = node.span } },
    };
}

fn lowerExpr(
    allocator: std.mem.Allocator,
    expr: *syntax.ast.Expr,
    scope: *model.Scope,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !*model.Expr {
    const lowered = try allocator.create(model.Expr);
    switch (expr.*) {
        .integer => |node| lowered.* = .{ .integer = .{ .value = node.value, .span = node.span } },
        .string => |node| lowered.* = .{ .string = .{ .value = node.value, .span = node.span } },
        .identifier => |node| {
            const binding = scope.get(node.name) orelse {
                try out_diagnostics.append(diagnostics.single(.@"error", "unknown local name", .{
                    .span = node.span,
                    .message = "declare the value before you use it",
                }));
                return error.SemanticFailed;
            };
            lowered.* = .{ .local = .{
                .local_id = binding.id,
                .name = node.name,
                .ty = binding.ty,
                .span = node.span,
            } };
        },
        .binary => |node| {
            const lhs = try lowerExpr(allocator, node.lhs, scope, out_diagnostics);
            const rhs = try lowerExpr(allocator, node.rhs, scope, out_diagnostics);
            const lhs_ty = model.hir.exprType(lhs.*);
            const rhs_ty = model.hir.exprType(rhs.*);
            if (lhs_ty != .integer or rhs_ty != .integer) {
                try out_diagnostics.append(diagnostics.single(.@"error", "operator '+' currently requires integers", .{
                    .span = node.span,
                    .message = "both sides of '+' must be integers in the bootstrap runtime",
                }));
                return error.SemanticFailed;
            }
            lowered.* = .{ .binary = .{
                .op = .add,
                .lhs = lhs,
                .rhs = rhs,
                .ty = .integer,
                .span = node.span,
            } };
        },
        .call => |node| {
            try out_diagnostics.append(diagnostics.single(.@"error", "calls are only supported as statements", .{
                .span = node.span,
                .message = "move the call into its own statement",
            }));
            return error.SemanticFailed;
        },
    }
    return lowered;
}
