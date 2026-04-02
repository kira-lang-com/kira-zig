const source_pkg = @import("kira_source");
const runtime_abi = @import("kira_runtime_abi");
const symbols = @import("symbols.zig");
const Type = @import("types.zig").Type;

pub const Program = struct {
    functions: []Function,
    entry_index: usize,
};

pub const Function = struct {
    id: u32,
    name: []const u8,
    is_main: bool,
    execution: runtime_abi.FunctionExecution,
    locals: []symbols.LocalSymbol,
    body: []Statement,
    span: source_pkg.Span,
};

pub const Statement = union(enum) {
    let_stmt: LetStatement,
    print_stmt: PrintStatement,
    call_stmt: CallStatement,
    return_stmt: ReturnStatement,
};

pub const LetStatement = struct {
    local_id: u32,
    value: *Expr,
    span: source_pkg.Span,
};

pub const PrintStatement = struct {
    value: *Expr,
    span: source_pkg.Span,
};

pub const CallStatement = struct {
    function_id: u32,
    name: []const u8,
    execution: runtime_abi.FunctionExecution,
    span: source_pkg.Span,
};

pub const ReturnStatement = struct {
    span: source_pkg.Span,
};

pub const Expr = union(enum) {
    integer: IntegerExpr,
    string: StringExpr,
    local: LocalExpr,
    binary: BinaryExpr,
};

pub const IntegerExpr = struct {
    value: i64,
    ty: Type = .integer,
    span: source_pkg.Span,
};

pub const StringExpr = struct {
    value: []const u8,
    ty: Type = .string,
    span: source_pkg.Span,
};

pub const LocalExpr = struct {
    local_id: u32,
    name: []const u8,
    ty: Type,
    span: source_pkg.Span,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
    ty: Type,
    span: source_pkg.Span,
};

pub const BinaryOp = enum {
    add,
};

pub fn exprType(expr: Expr) Type {
    return switch (expr) {
        .integer => .integer,
        .string => .string,
        .local => |node| node.ty,
        .binary => |node| node.ty,
    };
}
