const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const runtime_abi = @import("kira_runtime_abi");
const ImportedGlobals = @import("imported_globals.zig").ImportedGlobals;
const function_types = @import("function_types.zig");
const decls = @import("lower_shared_decls.zig");

pub const lowerAnnotationDecl = decls.lowerAnnotationDecl;
pub const lowerCapabilityDecl = decls.lowerCapabilityDecl;
pub const lowerGeneratedFunctions = decls.lowerGeneratedFunctions;

pub const Context = struct {
    allocator: std.mem.Allocator,
    diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    imported_globals: ImportedGlobals = .{},
    annotation_headers: ?*const std.StringHashMapUnmanaged(AnnotationHeader) = null,
    type_headers: ?*const std.StringHashMapUnmanaged(TypeHeader) = null,
};

pub const AnnotationHeader = struct {
    index: ?usize = null,
    decl: model.AnnotationDecl,
    allows_block: bool = false,
    compiler_builtin: bool = false,
};

pub const FunctionHeader = struct {
    id: u32,
    params: []const model.ResolvedType = &.{},
    execution: runtime_abi.FunctionExecution,
    return_type: model.ResolvedType,
    is_extern: bool = false,
    foreign: ?model.ForeignFunction = null,
    span: source_pkg.Span,
};

pub const ConstructHeader = struct {
    index: usize,
    span: source_pkg.Span,
};

pub const ParentView = struct {
    type_name: []const u8,
    offset: u32,
    span: source_pkg.Span,
};

pub const MethodMember = struct {
    name: []const u8,
    full_name: []const u8,
    receiver_type_name: []const u8,
    receiver_offset: u32,
    generated_by: ?[]const u8 = null,
    overridable: bool = true,
    params: []const model.ResolvedType = &.{},
    return_type: model.ResolvedType,
    span: source_pkg.Span,
};

pub const TypeHeader = struct {
    kind: model.TypeKind = .struct_decl,
    fields: []const model.Field = &.{},
    methods: []const MethodMember = &.{},
    parent_views: []const ParentView = &.{},
    ffi: ?model.NamedTypeInfo = null,
    span: source_pkg.Span,
};

pub const AnnotationPlacement = enum {
    function_decl,
    class_decl,
    struct_decl,
    construct_decl,
    construct_form_decl,
    field_decl,
    content_section,
};

pub fn registerBuiltinAnnotationHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMapUnmanaged(AnnotationHeader),
) !void {
    try putBuiltinAnnotation(allocator, headers, "Main", false);
    try putBuiltinAnnotation(allocator, headers, "Native", false);
    try putBuiltinAnnotation(allocator, headers, "Runtime", false);
    try putBuiltinAnnotation(allocator, headers, "FFI.Extern", true);
    try putBuiltinAnnotation(allocator, headers, "FFI.Struct", true);
    try putBuiltinAnnotation(allocator, headers, "FFI.Pointer", true);
    try putBuiltinAnnotation(allocator, headers, "FFI.Alias", true);
    try putBuiltinAnnotation(allocator, headers, "FFI.Array", true);
    try putBuiltinAnnotation(allocator, headers, "FFI.Callback", true);
}

fn putBuiltinAnnotation(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMapUnmanaged(AnnotationHeader),
    name: []const u8,
    allows_block: bool,
) !void {
    try headers.put(allocator, name, .{
        .decl = .{
            .name = name,
            .parameters = &.{},
            .module_path = "kira.compiler",
            .span = .{ .start = 0, .end = 0 },
        },
        .allows_block = allows_block,
        .compiler_builtin = true,
    });
}

pub fn qualifiedNameText(allocator: std.mem.Allocator, name: syntax.ast.QualifiedName) ![]const u8 {
    var builder = std.array_list.Managed(u8).init(allocator);
    for (name.segments, 0..) |segment, index| {
        if (index != 0) try builder.append('.');
        try builder.appendSlice(segment.text);
    }
    return builder.toOwnedSlice();
}

pub fn qualifiedNameLeaf(allocator: std.mem.Allocator, name: syntax.ast.QualifiedName) ![]const u8 {
    return allocator.dupe(u8, name.segments[name.segments.len - 1].text);
}

pub fn typeFromSyntax(allocator: std.mem.Allocator, ty: syntax.ast.TypeExpr) anyerror!model.ResolvedType {
    return switch (ty) {
        .array => |info| .{ .kind = .array, .name = try typeTextFromSyntax(allocator, info.element_type.*) },
        .function => |info| .{ .kind = .callback, .name = try functionTypeTextFromSyntax(allocator, info) },
        .named => |name| blk: {
            const leaf = name.segments[name.segments.len - 1].text;
            if (std.mem.eql(u8, leaf, "Int")) break :blk .{ .kind = .integer };
            if (std.mem.eql(u8, leaf, "Float")) break :blk .{ .kind = .float };
            if (std.mem.eql(u8, leaf, "Bool")) break :blk .{ .kind = .boolean };
            if (std.mem.eql(u8, leaf, "String")) break :blk .{ .kind = .string };
            if (std.mem.eql(u8, leaf, "Void")) break :blk .{ .kind = .void };
            if (std.mem.eql(u8, leaf, "I8") or
                std.mem.eql(u8, leaf, "U8") or
                std.mem.eql(u8, leaf, "I16") or
                std.mem.eql(u8, leaf, "U16") or
                std.mem.eql(u8, leaf, "I32") or
                std.mem.eql(u8, leaf, "U32") or
                std.mem.eql(u8, leaf, "I64") or
                std.mem.eql(u8, leaf, "U64"))
            {
                break :blk .{ .kind = .integer, .name = leaf };
            }
            if (std.mem.eql(u8, leaf, "F32") or std.mem.eql(u8, leaf, "F64")) {
                break :blk .{ .kind = .float, .name = leaf };
            }
            if (std.mem.eql(u8, leaf, "CBool")) break :blk .{ .kind = .boolean, .name = leaf };
            if (std.mem.eql(u8, leaf, "CString")) break :blk .{ .kind = .c_string, .name = leaf };
            if (std.mem.eql(u8, leaf, "RawPtr")) break :blk .{ .kind = .raw_ptr, .name = leaf };
            break :blk .{ .kind = .named, .name = leaf };
        },
    };
}

pub fn typeTextFromSyntax(allocator: std.mem.Allocator, ty: syntax.ast.TypeExpr) anyerror![]const u8 {
    return switch (ty) {
        .array => |info| std.fmt.allocPrint(allocator, "[{s}]", .{try typeTextFromSyntax(allocator, info.element_type.*)}),
        .function => |info| functionTypeTextFromSyntax(allocator, info),
        .named => |name| allocator.dupe(u8, name.segments[name.segments.len - 1].text),
    };
}

pub fn typeTextFromResolved(allocator: std.mem.Allocator, ty: model.ResolvedType) ![]const u8 {
    return switch (ty.kind) {
        .void => allocator.dupe(u8, "Void"),
        .integer => allocator.dupe(u8, ty.name orelse "Int"),
        .float => allocator.dupe(u8, ty.name orelse "Float"),
        .boolean => allocator.dupe(u8, ty.name orelse "Bool"),
        .string => allocator.dupe(u8, "String"),
        .c_string => allocator.dupe(u8, ty.name orelse "CString"),
        .raw_ptr => allocator.dupe(u8, ty.name orelse "RawPtr"),
        .callback, .ffi_struct, .named => allocator.dupe(u8, ty.name orelse "Unknown"),
        .array => std.fmt.allocPrint(allocator, "[{s}]", .{ty.name orelse ""}),
        .unknown => allocator.dupe(u8, "Unknown"),
    };
}

pub fn canAssign(target: model.ResolvedType, actual: model.ResolvedType) bool {
    if (target.eql(actual)) return true;
    if (target.kind == .array or actual.kind == .array) return false;
    return target.kind == .float and actual.kind == .integer;
}

pub fn canAssignExactly(target: model.ResolvedType, actual: model.ResolvedType) bool {
    return target.eql(actual);
}

pub fn emitTypeMismatch(
    allocator: std.mem.Allocator,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    span: source_pkg.Span,
    target: model.ResolvedType,
    actual: model.ResolvedType,
) !void {
    try diagnostics.appendOwned(allocator, out_diagnostics, .{
        .severity = .@"error",
        .code = "KSEM031",
        .title = "type mismatch",
        .message = try std.fmt.allocPrint(allocator, "Kira expected {s} here, but the value resolves to {s}.", .{ typeLabel(target), typeLabel(actual) }),
        .labels = &.{
            diagnostics.primaryLabel(span, "value does not match the required type"),
        },
        .help = "Add an explicit type declaration where coercion is allowed, or change the value so the type is unambiguous.",
    });
}

pub fn typeLabel(ty: model.ResolvedType) []const u8 {
    if (ty.kind == .array) return ty.name orelse "[]";
    if (ty.name) |name| return name;
    return switch (ty.kind) {
        .void => "Void",
        .integer => "Int",
        .float => "Float",
        .boolean => "Bool",
        .string => "String",
        .c_string => "CString",
        .raw_ptr => "RawPtr",
        .callback, .ffi_struct, .named => "Unknown",
        .array => "[]",
        .unknown => "Unknown",
    };
}

pub fn namedTypeInfo(ctx: *const Context, ty: model.ResolvedType) ?model.NamedTypeInfo {
    if (ty.kind != .named or ty.name == null) return null;
    if (ctx.type_headers) |headers| {
        if (headers.get(ty.name.?)) |header| return header.ffi;
    }
    if (ctx.imported_globals.findType(ty.name.?)) |type_decl| return type_decl.ffi;
    return null;
}

pub fn namedTypeHeader(ctx: *const Context, ty: model.ResolvedType) ?TypeHeader {
    if (ty.kind != .named or ty.name == null) return null;
    if (ctx.type_headers) |headers| {
        if (headers.get(ty.name.?)) |header| return header;
    }
    return null;
}

pub fn namedTypeFields(ctx: *const Context, ty: model.ResolvedType) []const model.Field {
    if (namedTypeHeader(ctx, ty)) |header| return header.fields;
    return &.{};
}

pub fn isPointerLike(ctx: *const Context, ty: model.ResolvedType) bool {
    return switch (ty.kind) {
        .raw_ptr, .c_string => true,
        .named => if (namedTypeInfo(ctx, ty)) |info|
            switch (info) {
                .pointer, .callback => true,
                .alias => |value| isPointerLike(ctx, value.target),
                .ffi_struct, .array => false,
            }
        else
            false,
        else => false,
    };
}

pub fn callbackInfo(ctx: *const Context, ty: model.ResolvedType) ?model.CallbackInfo {
    if (ty.kind != .named) return null;
    return if (namedTypeInfo(ctx, ty)) |info|
        switch (info) {
            .callback => |value| value,
            .alias => |value| callbackInfo(ctx, value.target),
            else => null,
        }
    else
        null;
}

pub fn resolveForeignFunction(ctx: *Context, annotations: []const syntax.ast.Annotation, span: source_pkg.Span) !?model.ForeignFunction {
    const annotation = findAnnotation(annotations, "FFI", "Extern") orelse return null;
    var library_name: ?[]const u8 = null;
    var symbol_name: ?[]const u8 = null;
    var calling_convention: runtime_abi.CallingConvention = .c;

    if (annotation.block) |block| {
        for (block.entries) |entry| {
            if (entry != .field) continue;
            if (std.mem.eql(u8, entry.field.name, "library")) library_name = try annotationValueText(ctx, entry.field.value);
            if (std.mem.eql(u8, entry.field.name, "symbol")) symbol_name = try annotationValueText(ctx, entry.field.value);
            if (std.mem.eql(u8, entry.field.name, "abi")) calling_convention = try annotationCallingConvention(ctx, entry.field.value);
        }
    }

    if (library_name == null or symbol_name == null) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM036",
            .title = "invalid FFI extern annotation",
            .message = "An @FFI.Extern annotation must declare both `library` and `symbol`.",
            .labels = &.{
                diagnostics.primaryLabel(span, "FFI extern declaration is missing required metadata"),
            },
            .help = "Write `@FFI.Extern { library: native_lib, symbol: native_symbol, abi: c }`.",
        });
        return error.DiagnosticsEmitted;
    }

    return .{
        .library_name = library_name.?,
        .symbol_name = symbol_name.?,
        .calling_convention = calling_convention,
        .span = annotation.span,
    };
}

pub fn resolveNamedTypeInfo(ctx: *Context, annotations: []const syntax.ast.Annotation, span: source_pkg.Span) !?model.NamedTypeInfo {
    var result: ?model.NamedTypeInfo = null;

    if (findAnnotation(annotations, "FFI", "Struct")) |annotation| {
        const layout = if (annotation.block) |block|
            annotationBlockText(ctx, block, "layout") catch |err| switch (err) {
                error.MissingField => "c",
                else => return err,
            }
        else
            "c";
        result = .{ .ffi_struct = .{
            .layout = layout,
            .span = annotation.span,
        } };
    }

    if (findAnnotation(annotations, "FFI", "Pointer")) |annotation| {
        if (result != null) {
            try emitConflictingFfiTypeAnnotation(ctx, span);
            return error.DiagnosticsEmitted;
        }
        const block = annotation.block orelse {
            try emitMissingFfiBlock(ctx, annotation.span, "@FFI.Pointer");
            return error.DiagnosticsEmitted;
        };
        const target_name = try annotationBlockText(ctx, block, "target");
        const ownership_text = annotationBlockText(ctx, block, "ownership") catch |err| switch (err) {
            error.MissingField => "borrowed",
            else => return err,
        };
        result = .{ .pointer = .{
            .target_name = target_name,
            .ownership = try parseOwnership(ctx, ownership_text, annotation.span),
            .span = annotation.span,
        } };
    }

    if (findAnnotation(annotations, "FFI", "Alias")) |annotation| {
        if (result != null) {
            try emitConflictingFfiTypeAnnotation(ctx, span);
            return error.DiagnosticsEmitted;
        }
        const block = annotation.block orelse {
            try emitMissingFfiBlock(ctx, annotation.span, "@FFI.Alias");
            return error.DiagnosticsEmitted;
        };
        result = .{ .alias = .{
            .target = try annotationBlockType(ctx, block, "target"),
            .span = annotation.span,
        } };
    }

    if (findAnnotation(annotations, "FFI", "Array")) |annotation| {
        if (result != null) {
            try emitConflictingFfiTypeAnnotation(ctx, span);
            return error.DiagnosticsEmitted;
        }
        const block = annotation.block orelse {
            try emitMissingFfiBlock(ctx, annotation.span, "@FFI.Array");
            return error.DiagnosticsEmitted;
        };
        result = .{ .array = .{
            .element = try annotationBlockType(ctx, block, "element"),
            .count = try annotationBlockCount(ctx, block, "count"),
            .span = annotation.span,
        } };
    }

    if (findAnnotation(annotations, "FFI", "Callback")) |annotation| {
        if (result != null) {
            try emitConflictingFfiTypeAnnotation(ctx, span);
            return error.DiagnosticsEmitted;
        }
        const block = annotation.block orelse {
            try emitMissingFfiBlock(ctx, annotation.span, "@FFI.Callback");
            return error.DiagnosticsEmitted;
        };
        result = .{ .callback = .{
            .calling_convention = annotationBlockCallingConvention(ctx, block, "abi") catch |err| switch (err) {
                error.MissingField => .c,
                else => return err,
            },
            .params = try annotationBlockTypeArray(ctx, block, "params"),
            .result = annotationBlockType(ctx, block, "result") catch |err| switch (err) {
                error.MissingField => .{ .kind = .void },
                else => return err,
            },
            .span = annotation.span,
        } };
    }

    return result;
}

fn emitConflictingFfiTypeAnnotation(ctx: *Context, span: source_pkg.Span) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM037",
        .title = "conflicting FFI type annotations",
        .message = "A type declaration can describe exactly one FFI kind.",
        .labels = &.{
            diagnostics.primaryLabel(span, "type mixes incompatible FFI annotations"),
        },
        .help = "Choose one FFI type annotation such as @FFI.Struct, @FFI.Pointer, @FFI.Alias, @FFI.Array, or @FFI.Callback.",
    });
}

fn emitMissingFfiBlock(ctx: *Context, span: source_pkg.Span, name: []const u8) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM038",
        .title = "missing FFI annotation block",
        .message = try std.fmt.allocPrint(ctx.allocator, "{s} requires a block with explicit fields.", .{name}),
        .labels = &.{
            diagnostics.primaryLabel(span, "FFI annotation metadata is missing"),
        },
        .help = "Add a block such as `{ target: native_type, ownership: borrowed }`.",
    });
}

fn findAnnotation(annotations: []const syntax.ast.Annotation, namespace: []const u8, leaf: []const u8) ?syntax.ast.Annotation {
    for (annotations) |annotation| {
        if (qualifiedNameMatches(annotation.name, namespace, leaf)) return annotation;
    }
    return null;
}

fn qualifiedNameMatches(name: syntax.ast.QualifiedName, namespace: []const u8, leaf: []const u8) bool {
    if (name.segments.len != 2) return false;
    return std.mem.eql(u8, name.segments[0].text, namespace) and std.mem.eql(u8, name.segments[1].text, leaf);
}

fn annotationBlockText(ctx: *Context, block: syntax.ast.AnnotationBlock, field_name: []const u8) ![]const u8 {
    for (block.entries) |entry| {
        if (entry != .field) continue;
        if (!std.mem.eql(u8, entry.field.name, field_name)) continue;
        return annotationValueText(ctx, entry.field.value);
    }
    return error.MissingField;
}

fn annotationBlockType(ctx: *Context, block: syntax.ast.AnnotationBlock, field_name: []const u8) !model.ResolvedType {
    const text = try annotationBlockText(ctx, block, field_name);
    return resolvedTypeFromText(text);
}

fn annotationBlockCount(ctx: *Context, block: syntax.ast.AnnotationBlock, field_name: []const u8) !usize {
    for (block.entries) |entry| {
        if (entry != .field) continue;
        if (!std.mem.eql(u8, entry.field.name, field_name)) continue;
        return annotationCountValue(ctx, entry.field.value);
    }
    return error.MissingField;
}

fn annotationBlockTypeArray(ctx: *Context, block: syntax.ast.AnnotationBlock, field_name: []const u8) ![]const model.ResolvedType {
    for (block.entries) |entry| {
        if (entry != .field) continue;
        if (!std.mem.eql(u8, entry.field.name, field_name)) continue;
        return annotationTypeArray(ctx, entry.field.value);
    }
    return error.MissingField;
}

fn annotationBlockCallingConvention(ctx: *Context, block: syntax.ast.AnnotationBlock, field_name: []const u8) !runtime_abi.CallingConvention {
    const value = try annotationBlockText(ctx, block, field_name);
    return parseCallingConvention(ctx, value, block.span);
}

fn annotationCallingConvention(ctx: *Context, value: *syntax.ast.Expr) !runtime_abi.CallingConvention {
    return parseCallingConvention(ctx, try annotationValueText(ctx, value), exprSpan(value.*));
}

fn parseCallingConvention(ctx: *Context, value: []const u8, span: source_pkg.Span) !runtime_abi.CallingConvention {
    if (std.mem.eql(u8, value, "c")) return .c;
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM039",
        .title = "unsupported FFI calling convention",
        .message = try std.fmt.allocPrint(ctx.allocator, "The calling convention '{s}' is not supported by this FFI pass.", .{value}),
        .labels = &.{
            diagnostics.primaryLabel(span, "unsupported calling convention"),
        },
        .help = "Use `abi: c` for the first-version FFI system.",
    });
    return error.DiagnosticsEmitted;
}

fn parseOwnership(ctx: *Context, value: []const u8, span: source_pkg.Span) !model.Ownership {
    if (std.mem.eql(u8, value, "borrowed")) return .borrowed;
    if (std.mem.eql(u8, value, "owned")) return .owned;
    if (std.mem.eql(u8, value, "opaque")) return .@"opaque";
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM040",
        .title = "unsupported FFI ownership mode",
        .message = try std.fmt.allocPrint(ctx.allocator, "The ownership mode '{s}' is not supported here.", .{value}),
        .labels = &.{
            diagnostics.primaryLabel(span, "unsupported ownership mode"),
        },
        .help = "Use `borrowed`, `owned`, or `opaque`.",
    });
    return error.DiagnosticsEmitted;
}

fn annotationTypeArray(ctx: *Context, expr: *syntax.ast.Expr) ![]const model.ResolvedType {
    if (expr.* != .array) return error.InvalidAnnotationValue;
    var list = std.array_list.Managed(model.ResolvedType).init(ctx.allocator);
    for (expr.array.elements) |element| {
        try list.append(try resolvedTypeFromText(try annotationValueText(ctx, element)));
    }
    return list.toOwnedSlice();
}

fn annotationValueText(ctx: *Context, expr: *syntax.ast.Expr) ![]const u8 {
    _ = ctx;
    return switch (expr.*) {
        .string => |value| value.value,
        .identifier => |value| value.name.segments[value.name.segments.len - 1].text,
        .member => |value| value.member,
        else => error.InvalidAnnotationValue,
    };
}

fn annotationCountValue(ctx: *Context, expr: *syntax.ast.Expr) !usize {
    _ = ctx;
    return switch (expr.*) {
        .integer => |value| std.math.cast(usize, value.value) orelse return error.InvalidAnnotationValue,
        else => error.InvalidAnnotationValue,
    };
}

pub const CheckedAnnotationValue = struct {
    value: model.AnnotationValue,
    ty: model.ResolvedType,
};

pub fn annotationValueForParameter(
    ctx: *Context,
    annotation_name: []const u8,
    parameter_name: []const u8,
    expected_type: model.ResolvedType,
    expr: *syntax.ast.Expr,
    is_default: bool,
) !CheckedAnnotationValue {
    const literal = annotationLiteralValue(ctx, expr) catch |err| switch (err) {
        error.InvalidAnnotationValue => {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM070",
                .title = if (is_default) "invalid annotation parameter default" else "invalid annotation parameter value",
                .message = "Annotation parameters currently support Bool, Int, Float, and String literal values.",
                .labels = &.{diagnostics.primaryLabel(exprSpan(expr.*), "unsupported annotation parameter value")},
                .help = "Use a literal value such as `true`, `0`, `1.5`, or \"text\".",
            });
            return error.DiagnosticsEmitted;
        },
        else => return err,
    };

    if (!canAssign(expected_type, literal.ty)) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM071",
            .title = "annotation parameter type mismatch",
            .message = try std.fmt.allocPrint(
                ctx.allocator,
                "parameter '{s}' for {s} expects {s}, got {s}.",
                .{ parameter_name, annotation_name, typeLabel(expected_type), typeLabel(literal.ty) },
            ),
            .labels = &.{diagnostics.primaryLabel(exprSpan(expr.*), "annotation argument has the wrong type")},
            .help = "Change the argument value or update the annotation parameter type.",
        });
        return error.DiagnosticsEmitted;
    }

    if (expected_type.kind == .float and literal.ty.kind == .integer) {
        return .{
            .value = .{ .float = @floatFromInt(literal.value.integer) },
            .ty = expected_type,
        };
    }

    return .{
        .value = literal.value,
        .ty = expected_type,
    };
}

pub fn annotationLiteralValue(ctx: *Context, expr: *syntax.ast.Expr) !CheckedAnnotationValue {
    return switch (expr.*) {
        .integer => |value| .{
            .value = .{ .integer = value.value },
            .ty = .{ .kind = .integer },
        },
        .float => |value| .{
            .value = .{ .float = value.value },
            .ty = .{ .kind = .float },
        },
        .string => |value| .{
            .value = .{ .string = value.value },
            .ty = .{ .kind = .string },
        },
        .bool => |value| .{
            .value = .{ .boolean = value.value },
            .ty = .{ .kind = .boolean },
        },
        .unary => |node| blk: {
            if (node.op != .negate) return error.InvalidAnnotationValue;
            const operand = try annotationLiteralValue(ctx, node.operand);
            break :blk switch (operand.value) {
                .integer => |value| .{
                    .value = .{ .integer = -value },
                    .ty = operand.ty,
                },
                .float => |value| .{
                    .value = .{ .float = -value },
                    .ty = operand.ty,
                },
                else => error.InvalidAnnotationValue,
            };
        },
        else => error.InvalidAnnotationValue,
    };
}

pub fn resolvedTypeFromText(text: []const u8) !model.ResolvedType {
    if (text.len >= 4 and text[0] == '(' and std.mem.indexOf(u8, text, "->") != null) {
        return .{ .kind = .callback, .name = text };
    }
    if (text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']') {
        return .{ .kind = .array, .name = text[1 .. text.len - 1] };
    }
    if (std.mem.eql(u8, text, "Void")) return .{ .kind = .void };
    if (std.mem.eql(u8, text, "Int")) return .{ .kind = .integer };
    if (std.mem.eql(u8, text, "Float")) return .{ .kind = .float };
    if (std.mem.eql(u8, text, "Bool")) return .{ .kind = .boolean };
    if (std.mem.eql(u8, text, "String")) return .{ .kind = .string };
    if (std.mem.eql(u8, text, "CString")) return .{ .kind = .c_string, .name = text };
    if (std.mem.eql(u8, text, "RawPtr")) return .{ .kind = .raw_ptr, .name = text };
    if (std.mem.eql(u8, text, "I8") or
        std.mem.eql(u8, text, "U8") or
        std.mem.eql(u8, text, "I16") or
        std.mem.eql(u8, text, "U16") or
        std.mem.eql(u8, text, "I32") or
        std.mem.eql(u8, text, "U32") or
        std.mem.eql(u8, text, "I64") or
        std.mem.eql(u8, text, "U64"))
    {
        return .{ .kind = .integer, .name = text };
    }
    if (std.mem.eql(u8, text, "F32") or std.mem.eql(u8, text, "F64")) return .{ .kind = .float, .name = text };
    if (std.mem.eql(u8, text, "CBool")) return .{ .kind = .boolean, .name = text };
    return .{ .kind = .named, .name = text };
}

fn functionTypeTextFromSyntax(allocator: std.mem.Allocator, info: syntax.ast.FunctionTypeExpr) anyerror![]const u8 {
    var params = std.array_list.Managed(model.ResolvedType).init(allocator);
    for (info.params) |param| try params.append(try typeFromSyntax(allocator, param.*));
    return function_types.signatureText(allocator, params.items, try typeFromSyntax(allocator, info.result.*));
}

fn exprSpan(expr: syntax.ast.Expr) source_pkg.Span {
    return switch (expr) {
        .integer => |node| node.span,
        .float => |node| node.span,
        .string => |node| node.span,
        .bool => |node| node.span,
        .identifier => |node| node.span,
        .array => |node| node.span,
        .callback => |node| node.span,
        .struct_literal => |node| node.span,
        .unary => |node| node.span,
        .binary => |node| node.span,
        .conditional => |node| node.span,
        .member => |node| node.span,
        .index => |node| node.span,
        .call => |node| node.span,
    };
}

pub fn emitAmbiguousInference(
    allocator: std.mem.Allocator,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    span: source_pkg.Span,
) !void {
    try diagnostics.appendOwned(allocator, out_diagnostics, .{
        .severity = .@"error",
        .code = "KSEM029",
        .title = "type inference is ambiguous",
        .message = "Kira cannot infer a type here because no explicit type or value was provided.",
        .labels = &.{
            diagnostics.primaryLabel(span, "type is ambiguous here"),
        },
        .help = "Add an explicit type annotation.",
    });
}

pub fn registerTopLevelName(
    allocator: std.mem.Allocator,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    map: *std.StringHashMapUnmanaged(source_pkg.Span),
    name: []const u8,
    span: source_pkg.Span,
) !void {
    if (map.get(name)) |previous_span| {
        try diagnostics.appendOwned(allocator, out_diagnostics, .{
            .severity = .@"error",
            .code = "KSEM003",
            .title = "duplicate top-level name",
            .message = try std.fmt.allocPrint(allocator, "Kira found more than one top-level declaration named '{s}'.", .{name}),
            .labels = &.{
                diagnostics.primaryLabel(span, "duplicate declaration"),
                diagnostics.secondaryLabel(previous_span, "first declaration was here"),
            },
            .help = "Rename one of the declarations so the symbol is unambiguous.",
        });
        return error.DiagnosticsEmitted;
    }
    try map.put(allocator, name, span);
}

pub fn containsAnnotationRule(rules: []const model.AnnotationRule, name: []const u8) bool {
    for (rules) |rule| if (std.mem.eql(u8, rule.name, name)) return true;
    return false;
}

pub fn containsString(values: [][]const u8, name: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, name)) return true;
    return false;
}

pub fn isImportedRoot(name: []const u8, imports: []const model.Import) bool {
    for (imports) |import_decl| {
        if (import_decl.alias) |alias| {
            if (std.mem.eql(u8, alias, name)) return true;
        }
        if (std.mem.eql(u8, import_decl.module_name, name)) return true;
    }
    return false;
}

pub fn resolveAnnotationHeader(ctx: *Context, name: syntax.ast.QualifiedName) !AnnotationHeader {
    const full_name = try qualifiedNameText(ctx.allocator, name);
    const leaf = name.segments[name.segments.len - 1].text;
    if (ctx.annotation_headers) |headers| {
        if (headers.get(full_name)) |header| return header;
        if (headers.get(leaf)) |header| return header;
    }
    if (ctx.imported_globals.findAnnotation(full_name)) |annotation_decl| {
        return .{
            .decl = .{
                .name = annotation_decl.name,
                .parameters = @constCast(annotation_decl.parameters),
                .module_path = annotation_decl.module_path,
                .span = annotation_decl.span,
            },
        };
    }
    if (ctx.imported_globals.findAnnotation(leaf)) |annotation_decl| {
        return .{
            .decl = .{
                .name = annotation_decl.name,
                .parameters = @constCast(annotation_decl.parameters),
                .module_path = annotation_decl.module_path,
                .span = annotation_decl.span,
            },
        };
    }

    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM063",
        .title = "unknown annotation",
        .message = try std.fmt.allocPrint(ctx.allocator, "unknown annotation @{s}", .{full_name}),
        .labels = &.{diagnostics.primaryLabel(name.span, "annotation has not been declared")},
        .help = "Declare the annotation with `annotation Name { }` or import the module that declares it.",
    });
    return error.DiagnosticsEmitted;
}

pub fn lowerAnnotation(ctx: *Context, annotation: syntax.ast.Annotation) !model.Annotation {
    const header = try resolveAnnotationHeader(ctx, annotation.name);
    const leaf = try qualifiedNameLeaf(ctx.allocator, annotation.name);
    const arguments = try lowerAnnotationArguments(ctx, annotation, header);
    return .{
        .name = leaf,
        .is_namespaced = annotation.name.segments.len > 1,
        .symbol_index = header.index,
        .arguments = arguments,
        .span = annotation.span,
    };
}

pub fn validateAnnotationUse(ctx: *Context, annotation: syntax.ast.Annotation) !void {
    _ = try lowerAnnotation(ctx, annotation);
}

fn lowerAnnotationArguments(ctx: *Context, annotation: syntax.ast.Annotation, header: AnnotationHeader) ![]model.AnnotationArgument {
    const params = header.decl.parameters;
    const display_name = try annotationDisplayName(ctx.allocator, annotation.name);

    if (params.len == 0) {
        if (annotation.args.len != 0 or (annotation.block != null and !header.allows_block)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM064",
                .title = "annotation does not accept parameters",
                .message = try std.fmt.allocPrint(ctx.allocator, "{s} does not accept parameters.", .{display_name}),
                .labels = &.{diagnostics.primaryLabel(annotation.span, "unexpected annotation parameters")},
                .help = "Remove the annotation arguments.",
            });
            return error.DiagnosticsEmitted;
        }
        return &.{};
    }

    if (annotation.block != null) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM065",
            .title = "annotation parameters require parentheses",
            .message = try std.fmt.allocPrint(ctx.allocator, "{s} declares parameters and must be applied with parentheses.", .{display_name}),
            .labels = &.{diagnostics.primaryLabel(annotation.span, "annotation block cannot fill declared parameters")},
            .help = "Write annotation parameters as `@Name(value)` or `@Name(parameter: value)`.",
        });
        return error.DiagnosticsEmitted;
    }

    var filled = try ctx.allocator.alloc(bool, params.len);
    @memset(filled, false);
    var values = try ctx.allocator.alloc(model.AnnotationArgument, params.len);
    var next_positional: usize = 0;

    for (annotation.args) |arg| {
        const param_index = if (arg.label) |label|
            findAnnotationParameter(params, label) orelse {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM066",
                    .title = "unknown annotation parameter",
                    .message = try std.fmt.allocPrint(ctx.allocator, "{s} does not declare a parameter named '{s}'.", .{ display_name, label }),
                    .labels = &.{diagnostics.primaryLabel(arg.span, "unknown annotation parameter")},
                    .help = "Use one of the parameters declared by the annotation.",
                });
                return error.DiagnosticsEmitted;
            }
        else blk: {
            while (next_positional < params.len and filled[next_positional]) next_positional += 1;
            if (next_positional >= params.len) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM067",
                    .title = "too many annotation parameters",
                    .message = try std.fmt.allocPrint(ctx.allocator, "{s} received more parameters than it declares.", .{display_name}),
                    .labels = &.{diagnostics.primaryLabel(arg.span, "extra annotation parameter")},
                    .help = "Remove the extra argument or declare another annotation parameter.",
                });
                return error.DiagnosticsEmitted;
            }
            const index = next_positional;
            next_positional += 1;
            break :blk index;
        };

        if (filled[param_index]) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM068",
                .title = "duplicate annotation parameter",
                .message = try std.fmt.allocPrint(ctx.allocator, "{s} receives parameter '{s}' more than once.", .{ display_name, params[param_index].name }),
                .labels = &.{diagnostics.primaryLabel(arg.span, "duplicate annotation parameter")},
                .help = "Pass each annotation parameter once.",
            });
            return error.DiagnosticsEmitted;
        }

        const checked = try annotationValueForParameter(ctx, display_name, params[param_index].name, params[param_index].ty, arg.value, false);
        values[param_index] = .{
            .name = params[param_index].name,
            .value = checked.value,
            .ty = params[param_index].ty,
            .span = arg.span,
        };
        filled[param_index] = true;
    }

    for (params, 0..) |param, index| {
        if (filled[index]) continue;
        if (param.default_value) |default_value| {
            values[index] = .{
                .name = param.name,
                .value = default_value,
                .ty = param.ty,
                .span = param.span,
            };
            filled[index] = true;
            continue;
        }

        const type_text = try typeTextFromResolved(ctx.allocator, param.ty);
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM069",
            .title = "missing annotation parameter",
            .message = try std.fmt.allocPrint(ctx.allocator, "{s} requires parameter '{s}: {s}'.", .{ display_name, param.name, type_text }),
            .labels = &.{diagnostics.primaryLabel(annotation.span, "required annotation parameter is missing")},
            .help = "Pass the required parameter or add a default value to the annotation declaration.",
        });
        return error.DiagnosticsEmitted;
    }

    return values;
}

fn findAnnotationParameter(params: []const model.AnnotationParameterDecl, name: []const u8) ?usize {
    for (params, 0..) |param, index| {
        if (std.mem.eql(u8, param.name, name)) return index;
    }
    return null;
}

fn annotationDisplayName(allocator: std.mem.Allocator, name: syntax.ast.QualifiedName) ![]const u8 {
    return std.fmt.allocPrint(allocator, "@{s}", .{try qualifiedNameText(allocator, name)});
}

pub fn resolveFunctionAnnotations(ctx: *Context, annotations: []const syntax.ast.Annotation) !struct { annotations: []model.Annotation, is_main: bool, execution: runtime_abi.FunctionExecution } {
    var lowered = std.array_list.Managed(model.Annotation).init(ctx.allocator);
    var is_main = false;
    var main_span: ?source_pkg.Span = null;
    var execution: runtime_abi.FunctionExecution = .inherited;
    var execution_span: ?source_pkg.Span = null;

    for (annotations) |annotation| {
        const lowered_annotation = try lowerAnnotation(ctx, annotation);
        const name = lowered_annotation.name;
        try lowered.append(lowered_annotation);

        if (std.mem.eql(u8, name, "Main")) {
            if (is_main) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
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

        if (std.mem.eql(u8, name, "Runtime") or std.mem.eql(u8, name, "Native")) {
            const next_execution: runtime_abi.FunctionExecution = if (std.mem.eql(u8, name, "Runtime")) .runtime else .native;
            if (execution != .inherited) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
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
            execution = next_execution;
            execution_span = annotation.span;
        }
    }

    return .{
        .annotations = try lowered.toOwnedSlice(),
        .is_main = is_main,
        .execution = execution,
    };
}

pub fn lowerAnnotations(ctx: *Context, annotations: []const syntax.ast.Annotation) ![]model.Annotation {
    var lowered = std.array_list.Managed(model.Annotation).init(ctx.allocator);
    for (annotations) |annotation| {
        try lowered.append(try lowerAnnotation(ctx, annotation));
    }
    return lowered.toOwnedSlice();
}

pub fn validateAnnotationPlacement(
    ctx: *Context,
    annotations: []const syntax.ast.Annotation,
    placement: AnnotationPlacement,
    construct_model: ?model.Construct,
) !void {
    for (annotations) |annotation| {
        const header = try resolveAnnotationHeader(ctx, annotation.name);
        _ = try lowerAnnotationArguments(ctx, annotation, header);
        const name = try qualifiedNameLeaf(ctx.allocator, annotation.name);
        const is_execution = std.mem.eql(u8, name, "Main") or std.mem.eql(u8, name, "Native") or std.mem.eql(u8, name, "Runtime");
        if (placement != .function_decl and is_execution) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM025",
                .title = "illegal annotation placement",
                .message = try std.fmt.allocPrint(ctx.allocator, "The annotation '@{s}' is only valid on functions.", .{name}),
                .labels = &.{
                    diagnostics.primaryLabel(annotation.span, "annotation cannot be applied here"),
                },
                .help = "Move the annotation onto a function declaration or remove it.",
            });
            return error.DiagnosticsEmitted;
        }
        if (header.decl.targets.len != 0 and !annotationTargetsIncludePlacement(header.decl.targets, placement)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM071",
                .title = "invalid annotation target",
                .message = try std.fmt.allocPrint(ctx.allocator, "The annotation '@{s}' is not valid on this declaration kind.", .{name}),
                .labels = &.{diagnostics.primaryLabel(annotation.span, "annotation target does not match this declaration")},
                .help = "Move the annotation to a supported target or update its `targets:` declaration.",
            });
            return error.DiagnosticsEmitted;
        }
        if (placement == .field_decl or placement == .content_section) {
            if (construct_model) |construct_info| {
                if (!containsAnnotationRule(construct_info.allowed_annotations, name)) {
                    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM026",
                        .title = "annotation is not allowed in this construct",
                        .message = try std.fmt.allocPrint(ctx.allocator, "The construct '{s}' does not declare the annotation '@{s}'.", .{ construct_info.name, name }),
                        .labels = &.{
                            diagnostics.primaryLabel(annotation.span, "annotation is not declared by this construct"),
                        },
                        .help = "Declare the annotation in the construct's `annotations { ... }` section or remove it.",
                    });
                    return error.DiagnosticsEmitted;
                }
            }
        }
    }
}

fn annotationTargetsIncludePlacement(targets: []const model.AnnotationTarget, placement: AnnotationPlacement) bool {
    const actual: ?model.AnnotationTarget = switch (placement) {
        .function_decl => .function,
        .class_decl => .class,
        .struct_decl => .struct_decl,
        .construct_decl => .construct,
        .field_decl, .content_section => .field,
        .construct_form_decl => null,
    };
    const required = actual orelse return false;
    for (targets) |target| {
        if (target == required) return true;
    }
    return false;
}
