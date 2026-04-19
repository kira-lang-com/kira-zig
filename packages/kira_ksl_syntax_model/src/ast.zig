const std = @import("std");
const source = @import("kira_source");

pub const Module = struct {
    imports: []const ImportDecl,
    types: []const TypeDecl,
    functions: []const FunctionDecl,
    shaders: []const ShaderDecl,
};

pub const QualifiedName = struct {
    segments: []const NameSegment,
    span: source.Span,
};

pub const NameSegment = struct {
    text: []const u8,
    span: source.Span,
};

pub const ImportDecl = struct {
    module_name: QualifiedName,
    alias: ?[]const u8,
    span: source.Span,
};

pub const Annotation = struct {
    name: QualifiedName,
    args: []const *Expr,
    span: source.Span,
};

pub const TypeRef = union(enum) {
    named: QualifiedName,
    runtime_array: RuntimeArrayType,
};

pub const RuntimeArrayType = struct {
    element: *TypeRef,
    span: source.Span,
};

pub const TypeField = struct {
    annotations: []const Annotation,
    name: []const u8,
    ty: *TypeRef,
    span: source.Span,
};

pub const TypeDecl = struct {
    name: []const u8,
    fields: []const TypeField,
    span: source.Span,
};

pub const ParamDecl = struct {
    name: []const u8,
    ty: *TypeRef,
    span: source.Span,
};

pub const FunctionDecl = struct {
    name: []const u8,
    params: []const ParamDecl,
    return_type: ?*TypeRef,
    body: Block,
    span: source.Span,
};

pub const ShaderDecl = struct {
    name: []const u8,
    options: []const OptionDecl,
    groups: []const GroupDecl,
    stages: []const StageDecl,
    span: source.Span,
};

pub const OptionDecl = struct {
    name: []const u8,
    ty: *TypeRef,
    default_value: *Expr,
    span: source.Span,
};

pub const GroupDecl = struct {
    name: []const u8,
    resources: []const ResourceDecl,
    span: source.Span,
};

pub const ResourceDecl = struct {
    kind: ResourceKind,
    access: ?AccessMode,
    name: []const u8,
    ty: *TypeRef,
    span: source.Span,
};

pub const ResourceKind = enum {
    uniform,
    storage,
    texture,
    sampler,
};

pub const AccessMode = enum {
    read,
    read_write,
};

pub const StageKind = enum {
    vertex,
    fragment,
    compute,
};

pub const StageDecl = struct {
    kind: StageKind,
    input_type: ?QualifiedName,
    output_type: ?QualifiedName,
    threads: ?ThreadsDecl,
    entry: FunctionDecl,
    span: source.Span,
};

pub const ThreadsDecl = struct {
    x: *Expr,
    y: *Expr,
    z: *Expr,
    span: source.Span,
};

pub const Block = struct {
    statements: []const Statement,
    span: source.Span,
};

pub const Statement = union(enum) {
    let_stmt: LetStatement,
    assign_stmt: AssignStatement,
    expr_stmt: ExprStatement,
    return_stmt: ReturnStatement,
    if_stmt: IfStatement,
};

pub const LetStatement = struct {
    name: []const u8,
    ty: ?*TypeRef,
    value: ?*Expr,
    span: source.Span,
};

pub const AssignStatement = struct {
    target: *Expr,
    value: *Expr,
    span: source.Span,
};

pub const ExprStatement = struct {
    expr: *Expr,
    span: source.Span,
};

pub const ReturnStatement = struct {
    value: ?*Expr,
    span: source.Span,
};

pub const IfStatement = struct {
    condition: *Expr,
    then_block: Block,
    else_block: ?Block,
    span: source.Span,
};

pub const Expr = union(enum) {
    integer: IntegerLiteral,
    float: FloatLiteral,
    string: StringLiteral,
    bool: BoolLiteral,
    identifier: IdentifierExpr,
    unary: UnaryExpr,
    binary: BinaryExpr,
    call: CallExpr,
    member: MemberExpr,
    index: IndexExpr,
};

pub const IntegerLiteral = struct {
    text: []const u8,
    span: source.Span,
};

pub const FloatLiteral = struct {
    text: []const u8,
    span: source.Span,
};

pub const StringLiteral = struct {
    text: []const u8,
    span: source.Span,
};

pub const BoolLiteral = struct {
    value: bool,
    span: source.Span,
};

pub const IdentifierExpr = struct {
    name: QualifiedName,
    span: source.Span,
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: *Expr,
    span: source.Span,
};

pub const UnaryOp = enum {
    neg,
    not,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: *Expr,
    right: *Expr,
    span: source.Span,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    less,
    less_equal,
    greater,
    greater_equal,
    equal,
    not_equal,
};

pub const CallExpr = struct {
    callee: *Expr,
    args: []const *Expr,
    span: source.Span,
};

pub const MemberExpr = struct {
    object: *Expr,
    name: []const u8,
    span: source.Span,
};

pub const IndexExpr = struct {
    object: *Expr,
    index: *Expr,
    span: source.Span,
};

pub fn exprSpan(expr: Expr) source.Span {
    return switch (expr) {
        .integer => |value| value.span,
        .float => |value| value.span,
        .string => |value| value.span,
        .bool => |value| value.span,
        .identifier => |value| value.span,
        .unary => |value| value.span,
        .binary => |value| value.span,
        .call => |value| value.span,
        .member => |value| value.span,
        .index => |value| value.span,
    };
}

pub fn typeSpan(ty: TypeRef) source.Span {
    return switch (ty) {
        .named => |value| value.span,
        .runtime_array => |value| value.span,
    };
}

pub fn dumpModule(writer: anytype, module: Module) !void {
    try writer.print("Module(imports={d}, types={d}, functions={d}, shaders={d})\n", .{
        module.imports.len,
        module.types.len,
        module.functions.len,
        module.shaders.len,
    });
    for (module.imports) |import_decl| {
        try writer.print("  import {s}", .{qualifiedNameText(import_decl.module_name)});
        if (import_decl.alias) |alias| try writer.print(" as {s}", .{alias});
        try writer.writeByte('\n');
    }
    for (module.types) |type_decl| {
        try writer.print("  type {s}\n", .{type_decl.name});
    }
    for (module.functions) |function_decl| {
        try writer.print("  function {s}\n", .{function_decl.name});
    }
    for (module.shaders) |shader_decl| {
        try writer.print("  shader {s}\n", .{shader_decl.name});
        for (shader_decl.options) |option_decl| {
            try writer.print("    option {s}\n", .{option_decl.name});
        }
        for (shader_decl.groups) |group_decl| {
            try writer.print("    group {s}\n", .{group_decl.name});
        }
        for (shader_decl.stages) |stage_decl| {
            try writer.print("    stage {s} entry={s}\n", .{ @tagName(stage_decl.kind), stage_decl.entry.name });
        }
    }
}

fn qualifiedNameText(name: QualifiedName) []const u8 {
    if (name.segments.len == 0) return "";
    return switch (name.segments.len) {
        1 => name.segments[0].text,
        else => name.segments[0].text,
    };
}

test "dump module writes shader summary" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try dumpModule(buffer.writer(), .{
        .imports = &.{},
        .types = &.{},
        .functions = &.{},
        .shaders = &.{},
    });
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Module(") != null);
}
