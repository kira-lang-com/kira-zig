const source_pkg = @import("kira_source");
const runtime_abi = @import("kira_runtime_abi");
const symbols = @import("symbols.zig");
const Type = @import("types.zig").Type;

pub const Program = struct {
    imports: []Import,
    constructs: []Construct,
    types: []TypeDecl,
    forms: []ConstructForm,
    functions: []Function,
    entry_index: usize,
};

pub const Import = struct {
    module_name: []const u8,
    alias: ?[]const u8,
    span: source_pkg.Span,
};

pub const Annotation = struct {
    name: []const u8,
    is_namespaced: bool = false,
    span: source_pkg.Span,
};

pub const Construct = struct {
    name: []const u8,
    allowed_annotations: []AnnotationRule,
    required_content: bool,
    allowed_lifecycle_hooks: [][]const u8,
    span: source_pkg.Span,
};

pub const AnnotationRule = struct {
    name: []const u8,
    span: source_pkg.Span,
};

pub const TypeDecl = struct {
    name: []const u8,
    fields: []Field,
    span: source_pkg.Span,
};

pub const ConstructForm = struct {
    construct_name: []const u8,
    name: []const u8,
    fields: []Field,
    content: ?BuilderBlock,
    lifecycle_hooks: []LifecycleHook,
    span: source_pkg.Span,
};

pub const Field = struct {
    name: []const u8,
    ty: Type,
    explicit_type: bool,
    annotations: []Annotation,
    span: source_pkg.Span,
};

pub const LifecycleHook = struct {
    name: []const u8,
    span: source_pkg.Span,
};

pub const Function = struct {
    id: u32,
    name: []const u8,
    is_main: bool,
    execution: runtime_abi.FunctionExecution,
    annotations: []Annotation,
    params: []Parameter,
    locals: []symbols.LocalSymbol,
    return_type: Type,
    body: []Statement,
    span: source_pkg.Span,
};

pub const Parameter = struct {
    id: u32,
    name: []const u8,
    ty: Type,
    span: source_pkg.Span,
};

pub const Statement = union(enum) {
    let_stmt: LetStatement,
    expr_stmt: ExprStatement,
    if_stmt: IfStatement,
    for_stmt: ForStatement,
    switch_stmt: SwitchStatement,
    return_stmt: ReturnStatement,
};

pub const LetStatement = struct {
    local_id: u32,
    ty: Type,
    explicit_type: bool,
    value: ?*Expr,
    span: source_pkg.Span,
};

pub const ExprStatement = struct {
    expr: *Expr,
    span: source_pkg.Span,
};

pub const IfStatement = struct {
    condition: *Expr,
    then_body: []Statement,
    else_body: ?[]Statement,
    span: source_pkg.Span,
};

pub const ForStatement = struct {
    binding_name: []const u8,
    iterator: *Expr,
    body: []Statement,
    span: source_pkg.Span,
};

pub const SwitchStatement = struct {
    subject: *Expr,
    cases: []SwitchCase,
    default_body: ?[]Statement,
    span: source_pkg.Span,
};

pub const SwitchCase = struct {
    pattern: *Expr,
    body: []Statement,
    span: source_pkg.Span,
};

pub const ReturnStatement = struct {
    value: ?*Expr,
    span: source_pkg.Span,
};

pub const BuilderBlock = struct {
    items: []BuilderItem,
    span: source_pkg.Span,
};

pub const BuilderItem = union(enum) {
    expr: BuilderExprItem,
    if_item: BuilderIfItem,
    for_item: BuilderForItem,
    switch_item: BuilderSwitchItem,
};

pub const BuilderExprItem = struct {
    expr: *Expr,
    span: source_pkg.Span,
};

pub const BuilderIfItem = struct {
    condition: *Expr,
    then_block: BuilderBlock,
    else_block: ?BuilderBlock,
    span: source_pkg.Span,
};

pub const BuilderForItem = struct {
    binding_name: []const u8,
    iterator: *Expr,
    body: BuilderBlock,
    span: source_pkg.Span,
};

pub const BuilderSwitchItem = struct {
    subject: *Expr,
    cases: []BuilderSwitchCase,
    default_block: ?BuilderBlock,
    span: source_pkg.Span,
};

pub const BuilderSwitchCase = struct {
    pattern: *Expr,
    body: BuilderBlock,
    span: source_pkg.Span,
};

pub const Expr = union(enum) {
    integer: IntegerExpr,
    float: FloatExpr,
    string: StringExpr,
    boolean: BooleanExpr,
    local: LocalExpr,
    namespace_ref: NamespaceRefExpr,
    binary: BinaryExpr,
    unary: UnaryExpr,
    call: CallExpr,
    array: ArrayExpr,
};

pub const IntegerExpr = struct {
    value: i64,
    ty: Type = .integer,
    span: source_pkg.Span,
};

pub const FloatExpr = struct {
    value: f64,
    ty: Type = .float,
    span: source_pkg.Span,
};

pub const StringExpr = struct {
    value: []const u8,
    ty: Type = .string,
    span: source_pkg.Span,
};

pub const BooleanExpr = struct {
    value: bool,
    ty: Type = .boolean,
    span: source_pkg.Span,
};

pub const LocalExpr = struct {
    local_id: u32,
    name: []const u8,
    ty: Type,
    span: source_pkg.Span,
};

pub const NamespaceRefExpr = struct {
    root: []const u8,
    path: []const u8,
    ty: Type = .unknown,
    span: source_pkg.Span,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
    ty: Type,
    span: source_pkg.Span,
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: *Expr,
    ty: Type,
    span: source_pkg.Span,
};

pub const CallExpr = struct {
    callee_name: []const u8,
    function_id: ?u32,
    args: []*Expr,
    ty: Type,
    span: source_pkg.Span,
};

pub const ArrayExpr = struct {
    elements: []*Expr,
    ty: Type = .array,
    span: source_pkg.Span,
};

pub const BinaryOp = enum {
    add,
    subtract,
    multiply,
    divide,
    modulo,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    logical_and,
    logical_or,
};

pub const UnaryOp = enum {
    negate,
    not,
};

pub fn exprType(expr: Expr) Type {
    return switch (expr) {
        .integer => .integer,
        .float => .float,
        .string => .string,
        .boolean => .boolean,
        .local => |node| node.ty,
        .namespace_ref => |node| node.ty,
        .binary => |node| node.ty,
        .unary => |node| node.ty,
        .call => |node| node.ty,
        .array => .array,
    };
}
