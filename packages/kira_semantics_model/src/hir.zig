const source_pkg = @import("kira_source");
const runtime_abi = @import("kira_runtime_abi");
const symbols = @import("symbols.zig");
const Type = @import("types.zig").Type;
const ResolvedType = @import("types.zig").ResolvedType;
const ffi = @import("ffi.zig");

pub const Program = struct {
    imports: []Import,
    annotations: []AnnotationDecl,
    capabilities: []CapabilityDecl = &.{},
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
    symbol_index: ?usize = null,
    arguments: []AnnotationArgument = &.{},
    span: source_pkg.Span,
};

pub const AnnotationDecl = struct {
    name: []const u8,
    targets: []AnnotationTarget = &.{},
    uses: []const []const u8 = &.{},
    generated_functions: []GeneratedFunction = &.{},
    parameters: []AnnotationParameterDecl,
    module_path: []const u8 = "",
    span: source_pkg.Span,
};

pub const CapabilityDecl = struct {
    name: []const u8,
    generated_functions: []GeneratedFunction = &.{},
    module_path: []const u8 = "",
    span: source_pkg.Span,
};

pub const AnnotationTarget = enum {
    class,
    struct_decl,
    function,
    construct,
    field,
};

pub const GeneratedFunction = struct {
    name: []const u8,
    overridable: bool,
    params: []const ResolvedType = &.{},
    return_type: ResolvedType = .{ .kind = .unknown },
    source_annotation: []const u8 = "",
    span: source_pkg.Span,
};

pub const AnnotationParameterDecl = struct {
    name: []const u8,
    ty: ResolvedType,
    default_value: ?AnnotationValue = null,
    span: source_pkg.Span,
};

pub const AnnotationArgument = struct {
    name: []const u8,
    value: AnnotationValue,
    ty: ResolvedType,
    span: source_pkg.Span,
};

pub const AnnotationValue = union(enum) {
    integer: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
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
    kind: TypeKind = .struct_decl,
    name: []const u8,
    fields: []const Field,
    ffi: ?ffi.NamedTypeInfo = null,
    span: source_pkg.Span,
};

pub const TypeKind = enum {
    class,
    struct_decl,
};

pub const ConstructForm = struct {
    construct_name: []const u8,
    name: []const u8,
    fields: []const Field,
    content: ?BuilderBlock,
    lifecycle_hooks: []LifecycleHook,
    span: source_pkg.Span,
};

pub const Field = struct {
    name: []const u8,
    owner_type_name: []const u8,
    storage: FieldStorage,
    slot_index: u32,
    ty: ResolvedType,
    explicit_type: bool,
    default_value: ?*Expr = null,
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
    is_extern: bool = false,
    foreign: ?ffi.ForeignFunction = null,
    annotations: []Annotation,
    params: []Parameter,
    locals: []symbols.LocalSymbol,
    return_type: ResolvedType,
    body: []Statement,
    span: source_pkg.Span,
};

pub const Parameter = struct {
    id: u32,
    name: []const u8,
    ty: ResolvedType,
    span: source_pkg.Span,
};

pub const Statement = union(enum) {
    let_stmt: LetStatement,
    assign_stmt: AssignStatement,
    expr_stmt: ExprStatement,
    if_stmt: IfStatement,
    for_stmt: ForStatement,
    switch_stmt: SwitchStatement,
    return_stmt: ReturnStatement,
};

pub const LetStatement = struct {
    local_id: u32,
    ty: ResolvedType,
    explicit_type: bool,
    value: ?*Expr,
    span: source_pkg.Span,
};

pub const ExprStatement = struct {
    expr: *Expr,
    span: source_pkg.Span,
};

pub const AssignStatement = struct {
    target: *Expr,
    value: *Expr,
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
    binding_local_id: u32,
    binding_ty: ResolvedType,
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
    null_ptr: NullPtrExpr,
    function_ref: FunctionRefExpr,
    local: LocalExpr,
    namespace_ref: NamespaceRefExpr,
    parent_view: ParentViewExpr,
    field: FieldExpr,
    binary: BinaryExpr,
    unary: UnaryExpr,
    conditional: ConditionalExpr,
    call: CallExpr,
    array: ArrayExpr,
};

pub const IntegerExpr = struct {
    value: i64,
    ty: ResolvedType = .{ .kind = .integer },
    span: source_pkg.Span,
};

pub const FloatExpr = struct {
    value: f64,
    ty: ResolvedType = .{ .kind = .float },
    span: source_pkg.Span,
};

pub const StringExpr = struct {
    value: []const u8,
    ty: ResolvedType = .{ .kind = .string },
    span: source_pkg.Span,
};

pub const BooleanExpr = struct {
    value: bool,
    ty: ResolvedType = .{ .kind = .boolean },
    span: source_pkg.Span,
};

pub const NullPtrExpr = struct {
    ty: ResolvedType,
    span: source_pkg.Span,
};

pub const FunctionRefExpr = struct {
    function_id: u32,
    name: []const u8,
    ty: ResolvedType,
    span: source_pkg.Span,
};

pub const LocalExpr = struct {
    local_id: u32,
    name: []const u8,
    ty: ResolvedType,
    storage: FieldStorage,
    span: source_pkg.Span,
};

pub const NamespaceRefExpr = struct {
    root: []const u8,
    path: []const u8,
    ty: ResolvedType = .{ .kind = .unknown },
    span: source_pkg.Span,
};

pub const ParentViewExpr = struct {
    object: *Expr,
    ty: ResolvedType,
    offset: u32,
    span: source_pkg.Span,
};

pub const FieldExpr = struct {
    object: *Expr,
    container_type_name: []const u8,
    field_name: []const u8,
    field_index: u32,
    ty: ResolvedType,
    storage: FieldStorage,
    span: source_pkg.Span,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
    ty: ResolvedType,
    span: source_pkg.Span,
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: *Expr,
    ty: ResolvedType,
    span: source_pkg.Span,
};

pub const ConditionalExpr = struct {
    condition: *Expr,
    then_expr: *Expr,
    else_expr: *Expr,
    ty: ResolvedType,
    span: source_pkg.Span,
};

pub const CallExpr = struct {
    callee_name: []const u8,
    function_id: ?u32,
    args: []*Expr,
    ty: ResolvedType,
    span: source_pkg.Span,
};

pub const ArrayExpr = struct {
    elements: []*Expr,
    ty: ResolvedType,
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

pub const FieldStorage = enum {
    immutable,
    mutable,
};

pub fn exprType(expr: Expr) ResolvedType {
    return switch (expr) {
        .integer => .{ .kind = .integer },
        .float => .{ .kind = .float },
        .string => .{ .kind = .string },
        .boolean => .{ .kind = .boolean },
        .null_ptr => |node| node.ty,
        .function_ref => |node| node.ty,
        .local => |node| node.ty,
        .namespace_ref => |node| node.ty,
        .parent_view => |node| node.ty,
        .field => |node| node.ty,
        .binary => |node| node.ty,
        .unary => |node| node.ty,
        .conditional => |node| node.ty,
        .call => |node| node.ty,
        .array => |node| node.ty,
    };
}
