const Span = @import("kira_source").Span;
const ast = @import("ast.zig");

pub const Statement = union(enum) {
    let_stmt: LetStatement,
    assign_stmt: AssignStatement,
    expr_stmt: ExprStatement,
    return_stmt: ReturnStatement,
    if_stmt: IfStatement,
    for_stmt: ForStatement,
    while_stmt: WhileStatement,
    break_stmt: BreakStatement,
    continue_stmt: ContinueStatement,
    match_stmt: MatchStatement,
    switch_stmt: SwitchStatement,
    attempt_stmt: AttemptStatement,
};

// Linear error handling over `Result<Value, Failure>`. Each `try` expression inside `body`
// unwraps a `Result`: on `Ok` execution continues, on `Error` control transfers to the matching
// `handle` case. `handle` is a contextual keyword recognized only after an `attempt { ... }` block.
pub const AttemptStatement = struct {
    body: []Statement,
    handlers: []HandleCase,
    span: Span,
};

pub const HandleCase = struct {
    variant_name: []const u8,
    binding_name: ?[]const u8,
    body: Block,
    span: Span,
};

pub const LetStatement = struct {
    annotations: []const ast.Annotation,
    storage: ast.FieldStorage,
    name: []const u8,
    type_expr: ?*TypeExpr,
    value: ?*Expr,
    span: Span,
};

pub const ExprStatement = struct {
    expr: *Expr,
    span: Span,
};

pub const AssignStatement = struct {
    target: *Expr,
    value: *Expr,
    span: Span,
};

pub const ReturnStatement = struct {
    value: ?*Expr,
    span: Span,
};

pub const IfStatement = struct {
    condition: *Expr,
    then_block: Block,
    else_block: ?Block,
    span: Span,
};

pub const ForStatement = struct {
    binding_name: []const u8,
    // `iterator` is the iterable for `for x in collection`, or the START bound for
    // a numeric range `for i in start..end` (when `range_end` is non-null).
    iterator: *Expr,
    range_end: ?*Expr = null,
    body: Block,
    span: Span,
};

pub const WhileStatement = struct {
    condition: *Expr,
    body: Block,
    span: Span,
};

pub const BreakStatement = struct {
    span: Span,
};

pub const ContinueStatement = struct {
    span: Span,
};

pub const MatchStatement = struct {
    subject: *Expr,
    arms: []MatchArm,
    span: Span,
};

pub const MatchArm = struct {
    patterns: []MatchPattern,
    guard: ?*Expr,
    body: Block,
    span: Span,
};

pub const MatchPattern = union(enum) {
    bare_variant: struct { name: []const u8, span: Span },
    destructure: struct { variant_name: []const u8, inner: *MatchPattern, span: Span },
    as_binding: struct { inner: *MatchPattern, binding_name: []const u8, span: Span },
};

pub const SwitchStatement = struct {
    subject: *Expr,
    cases: []SwitchCase,
    default_block: ?Block,
    span: Span,
};

pub const SwitchCase = struct {
    pattern: *Expr,
    body: Block,
    span: Span,
};

pub const BuilderBlock = struct {
    items: []BuilderItem,
    span: Span,
};

pub const BuilderItem = union(enum) {
    expr: BuilderExprItem,
    if_item: BuilderIfItem,
    for_item: BuilderForItem,
    switch_item: BuilderSwitchItem,
};

pub const BuilderExprItem = struct {
    expr: *Expr,
    span: Span,
};

pub const BuilderIfItem = struct {
    condition: *Expr,
    then_block: BuilderBlock,
    else_block: ?BuilderBlock,
    span: Span,
};

pub const BuilderForItem = struct {
    binding_name: []const u8,
    iterator: *Expr,
    body: BuilderBlock,
    span: Span,
};

pub const BuilderSwitchItem = struct {
    subject: *Expr,
    cases: []BuilderSwitchCase,
    default_block: ?BuilderBlock,
    span: Span,
};

pub const BuilderSwitchCase = struct {
    pattern: *Expr,
    body: BuilderBlock,
    span: Span,
};

pub const Expr = union(enum) {
    integer: IntegerLiteral,
    float: FloatLiteral,
    string: StringLiteral,
    bool: BoolLiteral,
    identifier: IdentifierExpr,
    array: ArrayExpr,
    builder_array: BuilderArrayExpr,
    callback: CallbackBlock,
    struct_literal: StructLiteralExpr,
    native_state: NativeStateExpr,
    native_user_data: NativeUserDataExpr,
    native_recover: NativeRecoverExpr,
    native_state_free: NativeStateFreeExpr,
    ownership: OwnershipExpr,
    unary: UnaryExpr,
    binary: BinaryExpr,
    conditional: ConditionalExpr,
    member: MemberExpr,
    index: IndexExpr,
    call: CallExpr,
    try_expr: TryExpr,
    quote: QuoteExpr,
};

// `quote { ... }` inside a `comptime macro` body. The body is captured as a sequence of literal
// token runs interleaved with `#{ expr }` splice holes; the compile-time evaluator renders it to
// Kira source text (filling splices by value type) and the macro-expansion pass re-parses the
// result. Only ever appears inside a procedural macro's `expand` and is consumed before semantics.
pub const QuoteExpr = struct {
    parts: []QuotePart,
    span: Span,
};

pub const QuotePart = union(enum) {
    /// Literal source text (a run of captured token lexemes joined by spaces).
    text: []const u8,
    /// A `#{ expr }` splice; `expr` is evaluated at macro-expansion time.
    splice: *Expr,
};

// `try expr` unwraps a `Result<Value, Failure>`. Only valid inside an `attempt { ... }` block.
pub const TryExpr = struct {
    operand: *Expr,
    span: Span,
};

pub const IntegerLiteral = struct {
    value: i64,
    span: Span,
};

pub const FloatLiteral = struct {
    value: f64,
    span: Span,
};

pub const StringLiteral = struct {
    value: []const u8,
    span: Span,
};

pub const BoolLiteral = struct {
    value: bool,
    span: Span,
};

pub const IdentifierExpr = struct {
    name: ast.QualifiedName,
    span: Span,
};

pub const ArrayExpr = struct {
    elements: []*Expr,
    span: Span,
};

pub const BuilderArrayExpr = struct {
    builder: BuilderBlock,
    span: Span,
};

pub const StructLiteralExpr = struct {
    type_name: ast.QualifiedName,
    fields: []StructLiteralField,
    span: Span,
};

pub const StructLiteralField = struct {
    name: []const u8,
    value: *Expr,
    span: Span,
};

pub const NativeStateExpr = struct {
    value: *Expr,
    span: Span,
};

pub const NativeUserDataExpr = struct {
    state: *Expr,
    span: Span,
};

pub const NativeRecoverExpr = struct {
    state_type: *TypeExpr,
    value: *Expr,
    span: Span,
};

// `nativeStateFree(state)` releases a native-state box created by `nativeState(...)`.
// Accepts the `NativeState<T>` handle or the `RawPtr` userdata token from
// `nativeUserData(state)`. Any outstanding `nativeRecover` views become invalid.
pub const NativeStateFreeExpr = struct {
    state: *Expr,
    span: Span,
};

pub const OwnershipExpr = struct {
    op: OwnershipExprOp,
    operand: *Expr,
    span: Span,
};

pub const OwnershipExprOp = enum {
    move,
    copy,
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: *Expr,
    span: Span,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
    span: Span,
};

pub const ConditionalExpr = struct {
    condition: *Expr,
    then_expr: *Expr,
    else_expr: *Expr,
    span: Span,
};

pub const MemberExpr = struct {
    object: *Expr,
    member: []const u8,
    span: Span,
};

pub const IndexExpr = struct {
    object: *Expr,
    index: *Expr,
    span: Span,
};

pub const CallExpr = struct {
    callee: *Expr,
    args: []CallArg,
    trailing_builder: ?BuilderBlock,
    trailing_callback: ?CallbackBlock,
    // When true this is a macro call written `name!(args)`; `callee` names the macro. The
    // macro-expansion pass replaces every such node before semantics; a residual `is_macro`
    // call reaching HIR lowering is an internal error (unknown macro already diagnosed).
    is_macro: bool = false,
    span: Span,
};

pub const CallArg = struct {
    label: ?[]const u8,
    value: *Expr,
    span: Span,
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
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
};

pub const UnaryOp = enum {
    negate,
    not,
    bit_not,
};

pub const TypeExpr = union(enum) {
    named: ast.QualifiedName,
    generic: GenericTypeExpr,
    ownership: OwnershipTypeExpr,
    any: AnyTypeExpr,
    array: ArrayTypeExpr,
    function: FunctionTypeExpr,
};

pub const OwnershipMode = enum {
    owned,
    borrow_read,
    borrow_mut,
    move,
    copy,
};

pub const OwnershipTypeExpr = struct {
    mode: OwnershipMode,
    target: *TypeExpr,
    span: Span,
};

pub const AnyTypeExpr = struct {
    target: *TypeExpr,
    span: Span,
    // `some Target` (existential / dynamic dispatch) vs `any Target`. Both currently lower to the
    // same existential `construct_any` semantics; this flag distinguishes the surface keyword so a
    // later phase can give `any` monomorphized-generic meaning while `some` keeps dynamic dispatch.
    existential: bool = false,
};

pub const ArrayTypeExpr = struct {
    element_type: *TypeExpr,
    span: Span,
};

pub const FunctionTypeExpr = struct {
    params: []*TypeExpr,
    result: *TypeExpr,
    span: Span,
};

pub const GenericTypeExpr = struct {
    base: ast.QualifiedName,
    args: []*TypeExpr,
    span: Span,
};

pub const CallbackBlock = struct {
    params: []CallbackParam,
    body: Block,
    span: Span,
};

pub const CallbackParam = struct {
    name: []const u8,
    span: Span,
};

pub const Block = struct {
    statements: []Statement,
    span: Span,
};
