const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const Context = shared.Context;
const AnnotationHeader = shared.AnnotationHeader;
const qualifiedNameText = shared.qualifiedNameText;

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

pub fn isImportedRoot(ctx: *const Context, name: []const u8, imports: []const model.Import) bool {
    for (imports) |import_decl| {
        if (!importVisibleToContext(ctx, import_decl)) continue;
        if (import_decl.alias) |alias| {
            if (std.mem.eql(u8, alias, name)) return true;
        }
        if (std.mem.eql(u8, import_decl.module_name, name)) return true;
    }
    return false;
}

pub fn importedQualifiedName(ctx: *const Context, imports: []const model.Import, name: []const u8) ?[]const u8 {
    const root_end = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    const root = name[0..root_end];
    const member = name[root_end + 1 ..];
    for (imports) |import_decl| {
        if (!importVisibleToContext(ctx, import_decl)) continue;
        if (import_decl.alias) |alias| {
            if (std.mem.eql(u8, alias, root)) {
                return std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ import_decl.module_name, member }) catch null;
            }
        }
        if (std.mem.eql(u8, import_decl.module_name, root)) {
            return std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ import_decl.module_name, member }) catch null;
        }
    }
    return null;
}

fn importVisibleToContext(ctx: *const Context, import_decl: model.Import) bool {
    if (import_decl.source_path.len != 0) {
        if (ctx.current_source_path == null) return false;
        if (!std.mem.eql(u8, import_decl.source_path, ctx.current_source_path.?)) return false;
    }
    if (import_decl.package_name) |package_name| {
        if (ctx.current_package == null) return false;
        return std.mem.eql(u8, package_name, ctx.current_package.?);
    }
    return ctx.current_package == null;
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
