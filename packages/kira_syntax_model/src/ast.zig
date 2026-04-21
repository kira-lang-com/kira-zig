const std = @import("std");
const Span = @import("kira_source").Span;

pub const Program = struct {
    imports: []ImportDecl,
    decls: []Decl,
    functions: []FunctionDecl,
};

pub const Decl = union(enum) {
    annotation_decl: AnnotationDecl,
    capability_decl: CapabilityDecl,
    function_decl: FunctionDecl,
    type_decl: TypeDecl,
    construct_decl: ConstructDecl,
    construct_form_decl: ConstructFormDecl,
};

pub const ImportDecl = struct {
    module_name: QualifiedName,
    alias: ?[]const u8,
    span: Span,
};

pub const NameSegment = struct {
    text: []const u8,
    span: Span,
};

pub const QualifiedName = struct {
    segments: []NameSegment,
    span: Span,
};

pub const Annotation = struct {
    name: QualifiedName,
    args: []AnnotationArg,
    block: ?AnnotationBlock,
    span: Span,
};

pub const AnnotationArg = struct {
    label: ?[]const u8,
    value: *Expr,
    span: Span,
};

pub const AnnotationBlock = struct {
    entries: []AnnotationBlockEntry,
    span: Span,
};

pub const AnnotationBlockEntry = union(enum) {
    value: AnnotationBlockValue,
    field: AnnotationBlockField,
};

pub const AnnotationBlockValue = struct {
    value: *Expr,
    span: Span,
};

pub const AnnotationBlockField = struct {
    name: []const u8,
    value: *Expr,
    span: Span,
};

pub const AnnotationDecl = struct {
    name: []const u8,
    targets: []AnnotationTarget,
    uses: []QualifiedName,
    parameters: []AnnotationParameterDecl,
    generated_members: []GeneratedMember,
    span: Span,
};

pub const CapabilityDecl = struct {
    name: []const u8,
    generated_members: []GeneratedMember,
    span: Span,
};

pub const AnnotationTarget = enum {
    class,
    struct_decl,
    function,
    construct,
    field,
};

pub const AnnotationParameterDecl = struct {
    name: []const u8,
    type_expr: *TypeExpr,
    default_value: ?*Expr,
    span: Span,
};

pub const GeneratedMember = struct {
    overridable: bool,
    member: BodyMember,
    span: Span,
};

pub const FunctionDecl = struct {
    annotations: []const Annotation,
    is_override: bool = false,
    name: []const u8,
    params: []ParamDecl,
    return_type: ?*TypeExpr,
    body: ?Block,
    span: Span,
};

pub const FunctionSignature = struct {
    name: []const u8,
    params: []ParamDecl,
    return_type: ?*TypeExpr,
    span: Span,
};

pub const ParamDecl = struct {
    annotations: []const Annotation,
    name: []const u8,
    type_expr: ?*TypeExpr,
    span: Span,
};

pub const TypeDecl = struct {
    kind: TypeKind,
    annotations: []const Annotation,
    name: []const u8,
    parents: []QualifiedName,
    members: []BodyMember,
    span: Span,
};

pub const TypeKind = enum {
    class,
    struct_decl,
};

pub const ConstructDecl = struct {
    annotations: []const Annotation,
    name: []const u8,
    sections: []ConstructSection,
    span: Span,
};

pub const ConstructSection = struct {
    name: []const u8,
    kind: ConstructSectionKind,
    entries: []ConstructSectionEntry,
    span: Span,
};

pub const ConstructSectionKind = enum {
    annotations,
    modifiers,
    requires,
    lifecycle,
    builder,
    representation,
    custom,
};

pub const ConstructSectionEntry = union(enum) {
    annotation_spec: AnnotationSpec,
    field_decl: FieldDecl,
    lifecycle_hook: LifecycleHook,
    function_signature: FunctionSignature,
    named_rule: NamedRule,
};

pub const AnnotationSpec = struct {
    name: QualifiedName,
    type_expr: ?*TypeExpr,
    default_value: ?*Expr,
    span: Span,
};

pub const NamedRule = struct {
    name: QualifiedName,
    args: []RuleArg,
    type_expr: ?*TypeExpr,
    value: ?*Expr,
    block: ?Block,
    span: Span,
};

pub const RuleArg = struct {
    label: ?[]const u8,
    value: ?*Expr,
    span: Span,
};

pub const ConstructFormDecl = struct {
    annotations: []const Annotation,
    construct_name: QualifiedName,
    name: []const u8,
    params: []ParamDecl,
    body: ConstructBody,
    span: Span,
};

pub const ConstructBody = struct {
    members: []BodyMember,
    span: Span,
};

pub const BodyMember = union(enum) {
    field_decl: FieldDecl,
    function_decl: FunctionDecl,
    content_section: ContentSection,
    lifecycle_hook: LifecycleHook,
    named_rule: NamedRule,
};

pub const FieldDecl = struct {
    annotations: []const Annotation,
    is_override: bool = false,
    storage: FieldStorage,
    name: []const u8,
    type_expr: ?*TypeExpr,
    value: ?*Expr,
    span: Span,
};

pub const FieldStorage = enum {
    immutable,
    mutable,
};

pub const ContentSection = struct {
    annotations: []const Annotation,
    builder: BuilderBlock,
    span: Span,
};

pub const LifecycleHook = struct {
    name: []const u8,
    args: []RuleArg,
    body: Block,
    span: Span,
};

pub const Block = struct {
    statements: []Statement,
    span: Span,
};

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
    switch_stmt: SwitchStatement,
};

pub const LetStatement = struct {
    annotations: []const Annotation,
    storage: FieldStorage,
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
    iterator: *Expr,
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
    callback: CallbackBlock,
    struct_literal: StructLiteralExpr,
    native_state: NativeStateExpr,
    native_user_data: NativeUserDataExpr,
    native_recover: NativeRecoverExpr,
    unary: UnaryExpr,
    binary: BinaryExpr,
    conditional: ConditionalExpr,
    member: MemberExpr,
    index: IndexExpr,
    call: CallExpr,
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
    name: QualifiedName,
    span: Span,
};

pub const ArrayExpr = struct {
    elements: []*Expr,
    span: Span,
};

pub const StructLiteralExpr = struct {
    type_name: QualifiedName,
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
};

pub const UnaryOp = enum {
    negate,
    not,
};

pub const TypeExpr = union(enum) {
    named: QualifiedName,
    array: ArrayTypeExpr,
    function: FunctionTypeExpr,
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

pub const CallbackBlock = struct {
    params: []CallbackParam,
    body: Block,
    span: Span,
};

pub const CallbackParam = struct {
    name: []const u8,
    span: Span,
};

pub fn dumpProgram(writer: anytype, program: Program) !void {
    try writer.writeAll("Program\n");
    for (program.imports) |import_decl| {
        try indent(writer, 1);
        try writer.print("Import {s}\n", .{qualifiedNameText(import_decl.module_name)});
    }
    for (program.decls) |decl| {
        try dumpDecl(writer, decl, 1);
    }
}

fn dumpDecl(writer: anytype, decl: Decl, depth: usize) anyerror!void {
    switch (decl) {
        .annotation_decl => |annotation_decl| {
            try indent(writer, depth);
            try writer.print("Annotation {s}\n", .{annotation_decl.name});
        },
        .capability_decl => |capability_decl| {
            try indent(writer, depth);
            try writer.print("Capability {s}\n", .{capability_decl.name});
        },
        .function_decl => |function_decl| {
            try indent(writer, depth);
            try writer.print("Function {s}\n", .{function_decl.name});
            if (function_decl.body) |body| {
                try dumpBlock(writer, body, depth + 1);
            }
        },
        .type_decl => |type_decl| {
            try indent(writer, depth);
            try writer.print("{s} {s}\n", .{ typeKindLabel(type_decl.kind), type_decl.name });
            for (type_decl.members) |member| try dumpBodyMember(writer, member, depth + 1);
        },
        .construct_decl => |construct_decl| {
            try indent(writer, depth);
            try writer.print("Construct {s}\n", .{construct_decl.name});
            for (construct_decl.sections) |section| {
                try indent(writer, depth + 1);
                try writer.print("Section {s}\n", .{section.name});
            }
        },
        .construct_form_decl => |form_decl| {
            try indent(writer, depth);
            try writer.print("ConstructDecl {s} {s}\n", .{ qualifiedNameText(form_decl.construct_name), form_decl.name });
            for (form_decl.body.members) |member| try dumpBodyMember(writer, member, depth + 1);
        },
    }
}

fn dumpBodyMember(writer: anytype, member: BodyMember, depth: usize) anyerror!void {
    switch (member) {
        .field_decl => |field_decl| {
            try indent(writer, depth);
            try writer.print("Field {s} {s}\n", .{
                @tagName(field_decl.storage),
                field_decl.name,
            });
        },
        .function_decl => |function_decl| {
            try indent(writer, depth);
            try writer.print("Function {s}\n", .{function_decl.name});
            if (function_decl.body) |body| {
                try dumpBlock(writer, body, depth + 1);
            }
        },
        .content_section => |content| {
            try indent(writer, depth);
            try writer.writeAll("Content\n");
            try dumpBuilderBlock(writer, content.builder, depth + 1);
        },
        .lifecycle_hook => |hook| {
            try indent(writer, depth);
            try writer.print("Lifecycle {s}\n", .{hook.name});
            try dumpBlock(writer, hook.body, depth + 1);
        },
        .named_rule => |rule| {
            try indent(writer, depth);
            try writer.print("Rule {s}\n", .{qualifiedNameText(rule.name)});
        },
    }
}

fn indent(writer: anytype, depth: usize) !void {
    for (0..depth) |_| try writer.writeAll("  ");
}

fn typeKindLabel(kind: TypeKind) []const u8 {
    return switch (kind) {
        .class => "Class",
        .struct_decl => "Struct",
    };
}

fn dumpBlock(writer: anytype, block: Block, depth: usize) anyerror!void {
    try indent(writer, depth);
    try writer.writeAll("Block\n");
    for (block.statements) |statement| try dumpStatement(writer, statement, depth + 1);
}

fn dumpStatement(writer: anytype, statement: Statement, depth: usize) anyerror!void {
    switch (statement) {
        .let_stmt => |let_stmt| {
            try indent(writer, depth);
            try writer.print("Let {s}\n", .{let_stmt.name});
            if (let_stmt.value) |value| try dumpExpr(writer, value.*, depth + 1);
        },
        .assign_stmt => |assign_stmt| {
            try indent(writer, depth);
            try writer.writeAll("Assign\n");
            try dumpExpr(writer, assign_stmt.target.*, depth + 1);
            try dumpExpr(writer, assign_stmt.value.*, depth + 1);
        },
        .expr_stmt => |expr_stmt| {
            try indent(writer, depth);
            try writer.writeAll("ExprStmt\n");
            try dumpExpr(writer, expr_stmt.expr.*, depth + 1);
        },
        .return_stmt => |return_stmt| {
            try indent(writer, depth);
            try writer.writeAll("Return\n");
            if (return_stmt.value) |value| try dumpExpr(writer, value.*, depth + 1);
        },
        .if_stmt => |if_stmt| {
            try indent(writer, depth);
            try writer.writeAll("If\n");
            try dumpExpr(writer, if_stmt.condition.*, depth + 1);
            try dumpBlock(writer, if_stmt.then_block, depth + 1);
        },
        .for_stmt => |for_stmt| {
            try indent(writer, depth);
            try writer.print("For {s}\n", .{for_stmt.binding_name});
            try dumpExpr(writer, for_stmt.iterator.*, depth + 1);
            try dumpBlock(writer, for_stmt.body, depth + 1);
        },
        .while_stmt => |while_stmt| {
            try indent(writer, depth);
            try writer.writeAll("While\n");
            try dumpExpr(writer, while_stmt.condition.*, depth + 1);
            try dumpBlock(writer, while_stmt.body, depth + 1);
        },
        .break_stmt => {
            try indent(writer, depth);
            try writer.writeAll("Break\n");
        },
        .continue_stmt => {
            try indent(writer, depth);
            try writer.writeAll("Continue\n");
        },
        .switch_stmt => |switch_stmt| {
            try indent(writer, depth);
            try writer.writeAll("Switch\n");
            try dumpExpr(writer, switch_stmt.subject.*, depth + 1);
        },
    }
}

fn dumpBuilderBlock(writer: anytype, block: BuilderBlock, depth: usize) anyerror!void {
    try indent(writer, depth);
    try writer.writeAll("Builder\n");
    for (block.items) |item| {
        switch (item) {
            .expr => |value| {
                try indent(writer, depth + 1);
                try writer.writeAll("BuilderExpr\n");
                try dumpExpr(writer, value.expr.*, depth + 2);
            },
            .if_item => {
                try indent(writer, depth + 1);
                try writer.writeAll("BuilderIf\n");
            },
            .for_item => {
                try indent(writer, depth + 1);
                try writer.writeAll("BuilderFor\n");
            },
            .switch_item => {
                try indent(writer, depth + 1);
                try writer.writeAll("BuilderSwitch\n");
            },
        }
    }
}

fn dumpExpr(writer: anytype, expr: Expr, depth: usize) anyerror!void {
    switch (expr) {
        .integer => |value| {
            try indent(writer, depth);
            try writer.print("Int {d}\n", .{value.value});
        },
        .float => |value| {
            try indent(writer, depth);
            try writer.print("Float {d}\n", .{value.value});
        },
        .string => |value| {
            try indent(writer, depth);
            try writer.print("String \"{s}\"\n", .{value.value});
        },
        .bool => |value| {
            try indent(writer, depth);
            try writer.print("Bool {}\n", .{value.value});
        },
        .identifier => |value| {
            try indent(writer, depth);
            try writer.print("Identifier {s}\n", .{qualifiedNameText(value.name)});
        },
        .array => |value| {
            try indent(writer, depth);
            try writer.writeAll("Array\n");
            for (value.elements) |element| try dumpExpr(writer, element.*, depth + 1);
        },
        .callback => |value| {
            try indent(writer, depth);
            try writer.writeAll("CallbackLiteral\n");
            if (value.params.len != 0) {
                try indent(writer, depth + 1);
                try writer.writeAll("Params\n");
                for (value.params) |param| {
                    try indent(writer, depth + 2);
                    try writer.print("{s}\n", .{param.name});
                }
            }
            try dumpBlock(writer, value.body, depth + 1);
        },
        .struct_literal => |value| {
            try indent(writer, depth);
            try writer.print("StructLiteral {s}\n", .{qualifiedNameText(value.type_name)});
            for (value.fields) |field| {
                try indent(writer, depth + 1);
                try writer.print("Field {s}\n", .{field.name});
                try dumpExpr(writer, field.value.*, depth + 2);
            }
        },
        .native_state => |value| {
            try indent(writer, depth);
            try writer.writeAll("NativeState\n");
            try dumpExpr(writer, value.value.*, depth + 1);
        },
        .native_user_data => |value| {
            try indent(writer, depth);
            try writer.writeAll("NativeUserData\n");
            try dumpExpr(writer, value.state.*, depth + 1);
        },
        .native_recover => |value| {
            try indent(writer, depth);
            try writer.writeAll("NativeRecover\n");
            try indent(writer, depth + 1);
            try writer.print("Type {s}\n", .{typeExprText(value.state_type.*)});
            try dumpExpr(writer, value.value.*, depth + 1);
        },
        .unary => |value| {
            try indent(writer, depth);
            try writer.print("Unary {s}\n", .{@tagName(value.op)});
            try dumpExpr(writer, value.operand.*, depth + 1);
        },
        .binary => |value| {
            try indent(writer, depth);
            try writer.print("Binary {s}\n", .{@tagName(value.op)});
            try dumpExpr(writer, value.lhs.*, depth + 1);
            try dumpExpr(writer, value.rhs.*, depth + 1);
        },
        .conditional => |value| {
            try indent(writer, depth);
            try writer.writeAll("Conditional\n");
            try dumpExpr(writer, value.condition.*, depth + 1);
            try dumpExpr(writer, value.then_expr.*, depth + 1);
            try dumpExpr(writer, value.else_expr.*, depth + 1);
        },
        .member => |value| {
            try indent(writer, depth);
            try writer.print("Member {s}\n", .{value.member});
            try dumpExpr(writer, value.object.*, depth + 1);
        },
        .index => |value| {
            try indent(writer, depth);
            try writer.writeAll("Index\n");
            try dumpExpr(writer, value.object.*, depth + 1);
            try dumpExpr(writer, value.index.*, depth + 1);
        },
        .call => |value| {
            try indent(writer, depth);
            try writer.writeAll("Call\n");
            try dumpExpr(writer, value.callee.*, depth + 1);
            for (value.args) |arg| try dumpExpr(writer, arg.value.*, depth + 1);
            if (value.trailing_builder) |builder| try dumpBuilderBlock(writer, builder, depth + 1);
            if (value.trailing_callback) |callback| {
                try indent(writer, depth + 1);
                try writer.writeAll("Callback\n");
                try dumpBlock(writer, callback.body, depth + 2);
            }
        },
    }
}

fn typeExprText(ty: TypeExpr) []const u8 {
    return switch (ty) {
        .named => |value| qualifiedNameText(value),
        .array => "Array",
        .function => "Function",
    };
}

fn qualifiedNameText(name: QualifiedName) []const u8 {
    if (name.segments.len == 0) return "";
    return name.segments[0].text;
}

test "ast dump smoke" {
    _ = std.testing;
}
