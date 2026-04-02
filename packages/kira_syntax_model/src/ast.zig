const std = @import("std");
const Span = @import("kira_source").Span;

pub const Program = struct {
    functions: []FunctionDecl,
};

pub const Annotation = struct {
    name: []const u8,
    span: Span,
};

pub const FunctionDecl = struct {
    annotations: []Annotation,
    name: []const u8,
    body: Block,
    span: Span,
};

pub const Block = struct {
    statements: []Statement,
    span: Span,
};

pub const Statement = union(enum) {
    let_stmt: LetStatement,
    expr_stmt: ExprStatement,
    return_stmt: ReturnStatement,
};

pub const LetStatement = struct {
    name: []const u8,
    value: *Expr,
    span: Span,
};

pub const ExprStatement = struct {
    expr: *Expr,
    span: Span,
};

pub const ReturnStatement = struct {
    span: Span,
};

pub const Expr = union(enum) {
    integer: IntegerLiteral,
    string: StringLiteral,
    identifier: IdentifierExpr,
    binary: BinaryExpr,
    call: CallExpr,
};

pub const IntegerLiteral = struct {
    value: i64,
    span: Span,
};

pub const StringLiteral = struct {
    value: []const u8,
    span: Span,
};

pub const IdentifierExpr = struct {
    name: []const u8,
    span: Span,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
    span: Span,
};

pub const CallExpr = struct {
    callee: []const u8,
    args: []*Expr,
    span: Span,
};

pub const BinaryOp = enum {
    add,
};

pub fn dumpProgram(writer: anytype, program: Program) !void {
    try writer.writeAll("Program\n");
    for (program.functions) |function_decl| {
        try writer.print("  Function {s}\n", .{function_decl.name});
        for (function_decl.annotations) |annotation| {
            try indent(writer, 2);
            try writer.print("Annotation @{s}\n", .{annotation.name});
        }
        try dumpBlock(writer, function_decl.body, 2);
    }
}

fn indent(writer: anytype, depth: usize) !void {
    for (0..depth) |_| try writer.writeAll("  ");
}

fn dumpBlock(writer: anytype, block: Block, depth: usize) !void {
    try indent(writer, depth);
    try writer.writeAll("Block\n");
    for (block.statements) |statement| {
        try dumpStatement(writer, statement, depth + 1);
    }
}

fn dumpStatement(writer: anytype, statement: Statement, depth: usize) !void {
    switch (statement) {
        .let_stmt => |let_stmt| {
            try indent(writer, depth);
            try writer.print("Let {s}\n", .{let_stmt.name});
            try dumpExpr(writer, let_stmt.value.*, depth + 1);
        },
        .expr_stmt => |expr_stmt| {
            try indent(writer, depth);
            try writer.writeAll("ExprStmt\n");
            try dumpExpr(writer, expr_stmt.expr.*, depth + 1);
        },
        .return_stmt => {
            try indent(writer, depth);
            try writer.writeAll("Return\n");
        },
    }
}

fn dumpExpr(writer: anytype, expr: Expr, depth: usize) !void {
    switch (expr) {
        .integer => |value| {
            try indent(writer, depth);
            try writer.print("Int {d}\n", .{value.value});
        },
        .string => |value| {
            try indent(writer, depth);
            try writer.print("String \"{s}\"\n", .{value.value});
        },
        .identifier => |value| {
            try indent(writer, depth);
            try writer.print("Identifier {s}\n", .{value.name});
        },
        .binary => |value| {
            try indent(writer, depth);
            try writer.print("Binary {s}\n", .{@tagName(value.op)});
            try dumpExpr(writer, value.lhs.*, depth + 1);
            try dumpExpr(writer, value.rhs.*, depth + 1);
        },
        .call => |value| {
            try indent(writer, depth);
            try writer.print("Call {s}\n", .{value.callee});
            for (value.args) |arg| {
                try dumpExpr(writer, arg.*, depth + 1);
            }
        },
    }
}

test "ast dump smoke" {
    _ = std.testing;
}
