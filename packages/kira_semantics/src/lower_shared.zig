const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const runtime_abi = @import("kira_runtime_abi");
const ImportedGlobals = @import("imported_globals.zig").ImportedGlobals;

pub const Context = struct {
    allocator: std.mem.Allocator,
    diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    imported_globals: ImportedGlobals = .{},
};

pub const FunctionHeader = struct {
    id: u32,
    execution: runtime_abi.FunctionExecution,
    return_type: model.Type,
    span: source_pkg.Span,
};

pub const ConstructHeader = struct {
    index: usize,
    span: source_pkg.Span,
};

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

pub fn typeFromSyntax(ty: syntax.ast.TypeExpr) model.Type {
    return switch (ty) {
        .array => .array,
        .named => |name| blk: {
            const leaf = name.segments[name.segments.len - 1].text;
            if (std.mem.eql(u8, leaf, "Int")) break :blk .integer;
            if (std.mem.eql(u8, leaf, "Float")) break :blk .float;
            if (std.mem.eql(u8, leaf, "Bool")) break :blk .boolean;
            if (std.mem.eql(u8, leaf, "String")) break :blk .string;
            if (std.mem.eql(u8, leaf, "Void")) break :blk .void;
            break :blk .named;
        },
    };
}

pub fn canAssign(target: model.Type, actual: model.Type) bool {
    if (target == actual) return true;
    return target == .float and actual == .integer;
}

pub fn canAssignExactly(target: model.Type, actual: model.Type) bool {
    return target == actual;
}

pub fn emitTypeMismatch(
    allocator: std.mem.Allocator,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    span: source_pkg.Span,
    target: model.Type,
    actual: model.Type,
) !void {
    try diagnostics.appendOwned(allocator, out_diagnostics, .{
        .severity = .@"error",
        .code = "KSEM031",
        .title = "type mismatch",
        .message = try std.fmt.allocPrint(allocator, "Kira expected {s} here, but the value resolves to {s}.", .{ @tagName(target), @tagName(actual) }),
        .labels = &.{
            diagnostics.primaryLabel(span, "value does not match the required type"),
        },
        .help = "Add an explicit type declaration where coercion is allowed, or change the value so the type is unambiguous.",
    });
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

pub fn resolveFunctionAnnotations(ctx: *Context, annotations: []const syntax.ast.Annotation) !struct { annotations: []model.Annotation, is_main: bool, execution: runtime_abi.FunctionExecution } {
    var lowered = std.array_list.Managed(model.Annotation).init(ctx.allocator);
    var is_main = false;
    var main_span: ?source_pkg.Span = null;
    var execution: runtime_abi.FunctionExecution = .inherited;
    var execution_span: ?source_pkg.Span = null;

    for (annotations) |annotation| {
        const name = try qualifiedNameLeaf(ctx.allocator, annotation.name);
        try lowered.append(.{
            .name = name,
            .is_namespaced = annotation.name.segments.len > 1,
            .span = annotation.span,
        });

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
        try lowered.append(.{
            .name = try qualifiedNameLeaf(ctx.allocator, annotation.name),
            .is_namespaced = annotation.name.segments.len > 1,
            .span = annotation.span,
        });
    }
    return lowered.toOwnedSlice();
}

pub fn validateAnnotationPlacement(
    ctx: *Context,
    annotations: []const syntax.ast.Annotation,
    placement: enum { function_decl, type_decl, construct_decl, construct_form_decl, field_decl },
    construct_model: ?model.Construct,
) !void {
    for (annotations) |annotation| {
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
        if (placement == .field_decl) {
            if (construct_model) |construct_info| {
                if (!std.mem.eql(u8, name, "Doc") and !containsAnnotationRule(construct_info.allowed_annotations, name)) {
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
