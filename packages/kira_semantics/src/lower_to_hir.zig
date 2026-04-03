const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const runtime_abi = @import("kira_runtime_abi");

const FunctionHeader = struct {
    id: u32,
    execution: runtime_abi.FunctionExecution,
    span: source_pkg.Span,
};

pub fn lowerProgram(allocator: std.mem.Allocator, program: syntax.ast.Program, out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic)) !model.Program {
    var function_headers = std.StringHashMapUnmanaged(FunctionHeader){};
    defer function_headers.deinit(allocator);

    var functions = std.array_list.Managed(model.Function).init(allocator);
    var main_index: ?usize = null;
    var first_main_span: ?source_pkg.Span = null;

    for (program.functions, 0..) |function_decl, function_index| {
        const annotation_info = try resolveAnnotations(allocator, function_decl, out_diagnostics);
        if (function_headers.get(function_decl.name)) |previous| {
            try diagnostics.appendOwned(allocator, out_diagnostics, .{
                .severity = .@"error",
                .code = "KSEM003",
                .title = "duplicate function name",
                .message = try std.fmt.allocPrint(
                    allocator,
                    "Kira found more than one function named '{s}'. Function names must be unique.",
                    .{function_decl.name},
                ),
                .labels = &.{
                    diagnostics.primaryLabel(function_decl.span, "duplicate declaration"),
                    diagnostics.secondaryLabel(previous.span, "first declaration was here"),
                },
                .help = "Rename one of the functions so each declaration has a unique name.",
            });
            return error.DiagnosticsEmitted;
        }
        try function_headers.put(allocator, function_decl.name, .{
            .id = @as(u32, @intCast(function_index)),
            .execution = annotation_info.execution,
            .span = function_decl.span,
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
            if (first_main_span) |previous_span| {
                try diagnostics.appendOwned(allocator, out_diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM002",
                    .title = "multiple @Main entrypoints",
                    .message = "A module can only have one @Main entrypoint.",
                    .labels = &.{
                        diagnostics.primaryLabel(function_decl.span, "this function is marked as another entrypoint"),
                        diagnostics.secondaryLabel(previous_span, "the first @Main entrypoint was declared here"),
                    },
                    .help = "Keep @Main on exactly one function.",
                });
                return error.DiagnosticsEmitted;
            }
            first_main_span = function_decl.span;
            main_index = function_index;
        }
        try functions.append(lowered);
    }

    if (main_index == null) {
        try diagnostics.appendOwned(allocator, out_diagnostics, .{
            .severity = .@"error",
            .code = "KSEM001",
            .title = "missing @Main entrypoint",
            .message = "This module cannot run because no function is marked with @Main.",
            .help = "Add @Main to exactly one zero-argument function, for example `@Main function main() { ... }`.",
        });
        return error.DiagnosticsEmitted;
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
    var main_span: ?source_pkg.Span = null;
    var execution: runtime_abi.FunctionExecution = .inherited;
    var execution_span: ?source_pkg.Span = null;

    for (function_decl.annotations) |annotation| {
        if (std.mem.eql(u8, annotation.name, "Main")) {
            if (is_main) {
                try diagnostics.appendOwned(allocator, out_diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM004",
                    .title = "duplicate @Main annotation",
                    .message = "The same function cannot declare @Main more than once.",
                    .labels = &.{
                        diagnostics.primaryLabel(annotation.span, "duplicate @Main annotation"),
                        diagnostics.secondaryLabel(main_span.?, "the first @Main annotation was here"),
                    },
                    .help = "Remove the extra @Main annotation.",
                });
                return error.DiagnosticsEmitted;
            }
            is_main = true;
            main_span = annotation.span;
            continue;
        }
        if (std.mem.eql(u8, annotation.name, "Runtime")) {
            if (execution != .inherited) {
                try diagnostics.appendOwned(allocator, out_diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM005",
                    .title = "conflicting execution annotations",
                    .message = "A function can use at most one execution annotation.",
                    .labels = &.{
                        diagnostics.primaryLabel(annotation.span, "conflicting execution annotation"),
                        diagnostics.secondaryLabel(execution_span.?, "the first execution annotation was here"),
                    },
                    .help = "Choose either @Runtime or @Native for this function.",
                });
                return error.DiagnosticsEmitted;
            }
            execution = .runtime;
            execution_span = annotation.span;
            continue;
        }
        if (std.mem.eql(u8, annotation.name, "Native")) {
            if (execution != .inherited) {
                try diagnostics.appendOwned(allocator, out_diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM005",
                    .title = "conflicting execution annotations",
                    .message = "A function can use at most one execution annotation.",
                    .labels = &.{
                        diagnostics.primaryLabel(annotation.span, "conflicting execution annotation"),
                        diagnostics.secondaryLabel(execution_span.?, "the first execution annotation was here"),
                    },
                    .help = "Choose either @Runtime or @Native for this function.",
                });
                return error.DiagnosticsEmitted;
            }
            execution = .native;
            execution_span = annotation.span;
            continue;
        }

        try diagnostics.appendOwned(allocator, out_diagnostics, .{
            .severity = .@"error",
            .code = "KSEM006",
            .title = "unsupported annotation",
            .message = try std.fmt.allocPrint(allocator, "Kira does not recognize the annotation '@{s}' in the current language subset.", .{annotation.name}),
            .labels = &.{
                diagnostics.primaryLabel(annotation.span, "unsupported annotation"),
            },
            .help = "Use only @Main, @Runtime, or @Native here.",
        });
        return error.DiagnosticsEmitted;
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
                            try diagnostics.appendOwned(allocator, out_diagnostics, .{
                                .severity = .@"error",
                                .code = "KSEM007",
                                .title = "wrong number of arguments to print",
                                .message = "The builtin `print` expects exactly one argument.",
                                .labels = &.{
                                    diagnostics.primaryLabel(call.span, "print call has the wrong number of arguments"),
                                },
                                .help = "Call `print(value);` with exactly one value.",
                            });
                            return error.DiagnosticsEmitted;
                        }
                        const lowered_arg = try lowerExpr(allocator, call.args[0], scope, out_diagnostics);
                        const arg_ty = model.hir.exprType(lowered_arg.*);
                        if (arg_ty != .integer and arg_ty != .string) {
                            try diagnostics.appendOwned(allocator, out_diagnostics, .{
                                .severity = .@"error",
                                .code = "KSEM008",
                                .title = "unsupported print argument type",
                                .message = "The current Kira runtime can only print integers and strings.",
                                .labels = &.{
                                    diagnostics.primaryLabel(call.span, "unsupported argument type for print"),
                                },
                                .help = "Pass an integer or string to `print`.",
                            });
                            return error.DiagnosticsEmitted;
                        }
                        break :blk .{ .print_stmt = .{
                            .value = lowered_arg,
                            .span = node.span,
                        } };
                    }

                    if (call.args.len != 0) {
                        try diagnostics.appendOwned(allocator, out_diagnostics, .{
                            .severity = .@"error",
                            .code = "KSEM009",
                            .title = "bootstrap calls do not take arguments yet",
                            .message = "User-defined function calls in the current Kira subset must use zero arguments.",
                            .labels = &.{
                                diagnostics.primaryLabel(call.span, "arguments are not supported for this call yet"),
                            },
                            .help = "Remove the arguments for now, or lower the call into supported bootstrap syntax.",
                        });
                        return error.DiagnosticsEmitted;
                    }

                    const target = function_headers.get(call.callee) orelse {
                        try diagnostics.appendOwned(allocator, out_diagnostics, .{
                            .severity = .@"error",
                            .code = "KSEM010",
                            .title = "unknown call target",
                            .message = try std.fmt.allocPrint(allocator, "Kira could not find a function named '{s}'.", .{call.callee}),
                            .labels = &.{
                                diagnostics.primaryLabel(call.span, "unknown function call"),
                            },
                            .help = "Declare the function before calling it.",
                        });
                        return error.DiagnosticsEmitted;
                    };
                    break :blk .{ .call_stmt = .{
                        .function_id = target.id,
                        .name = call.callee,
                        .execution = target.execution,
                        .span = node.span,
                    } };
                },
                else => {
                    try diagnostics.appendOwned(allocator, out_diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM011",
                        .title = "invalid expression statement",
                        .message = "Only calls can stand alone as statements in the current Kira subset.",
                        .labels = &.{
                            diagnostics.primaryLabel(node.span, "this expression cannot appear as a standalone statement"),
                        },
                        .help = "Use `print(...)`, call a zero-argument function, or bind the expression to a name.",
                    });
                    return error.DiagnosticsEmitted;
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
                try diagnostics.appendOwned(allocator, out_diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM012",
                    .title = "unknown local name",
                    .message = try std.fmt.allocPrint(allocator, "Kira could not find a local binding named '{s}'.", .{node.name}),
                    .labels = &.{
                        diagnostics.primaryLabel(node.span, "unknown local name"),
                    },
                    .help = "Declare the value with `let` before using it.",
                });
                return error.DiagnosticsEmitted;
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
                try diagnostics.appendOwned(allocator, out_diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM013",
                    .title = "operator '+' requires integers",
                    .message = "The '+' operator currently accepts integer operands only.",
                    .labels = &.{
                        diagnostics.primaryLabel(node.span, "both sides of '+' must be integers"),
                    },
                    .help = "Convert both operands to integers before using '+'.",
                });
                return error.DiagnosticsEmitted;
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
            try diagnostics.appendOwned(allocator, out_diagnostics, .{
                .severity = .@"error",
                .code = "KSEM014",
                .title = "calls are not expressions yet",
                .message = "Calls can only appear as standalone statements in the current Kira subset.",
                .labels = &.{
                    diagnostics.primaryLabel(node.span, "call used as an expression"),
                },
                .help = "Move the call into its own statement.",
            });
            return error.DiagnosticsEmitted;
        },
    }
    return lowered;
}
