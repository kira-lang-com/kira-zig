//! Import lowering, per-file import-alias registration, and annotation/capability
//! generated-function composition. Split from lower_program_types.zig; the public
//! surface is re-exported there and from lower_program.zig.
const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");

pub fn lowerImports(ctx: *shared.Context, program: syntax.ast.Program) ![]model.Import {
    const lowered = try ctx.allocator.alloc(model.Import, program.imports.len);
    for (program.imports, 0..) |import_decl, index| {
        const origin = if (index < program.import_origins.len) program.import_origins[index] else syntax.ast.DeclOrigin{};
        lowered[index] = .{
            .module_name = try shared.qualifiedNameText(ctx.allocator, import_decl.module_name),
            .alias = if (import_decl.alias) |alias| try ctx.allocator.dupe(u8, alias) else null,
            .package_name = if (origin.package_name) |package_name| try ctx.allocator.dupe(u8, package_name) else null,
            .source_path = if (origin.source_path.len != 0) try ctx.allocator.dupe(u8, origin.source_path) else "",
            .span = import_decl.span,
        };
    }
    return lowered;
}

pub fn composeAnnotationGeneratedFunctions(
    ctx: *shared.Context,
    annotation_decl: model.AnnotationDecl,
    capabilities: []const model.CapabilityDecl,
    capability_headers: *const std.StringHashMapUnmanaged(usize),
) ![]model.GeneratedFunction {
    var generated = std.array_list.Managed(model.GeneratedFunction).init(ctx.allocator);
    var names = std.StringHashMapUnmanaged(source_pkg.Span){};
    defer names.deinit(ctx.allocator);

    for (annotation_decl.uses) |capability_name| {
        const capability_index = capability_headers.get(capability_name) orelse {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM075",
                .title = "unknown capability",
                .message = try std.fmt.allocPrint(ctx.allocator, "The annotation '{s}' uses unknown capability '{s}'.", .{ annotation_decl.name, capability_name }),
                .labels = &.{diagnostics.primaryLabel(annotation_decl.span, "capability use cannot be resolved")},
                .help = "Declare the capability before composing it into an annotation.",
            });
            return error.DiagnosticsEmitted;
        };
        for (capabilities[capability_index].generated_functions) |function_decl| {
            try appendGeneratedFunctionUnique(ctx, &generated, &names, function_decl);
        }
    }
    for (annotation_decl.generated_functions) |function_decl| {
        try appendGeneratedFunctionUnique(ctx, &generated, &names, function_decl);
    }
    return generated.toOwnedSlice();
}

pub fn appendGeneratedFunctionUnique(
    ctx: *shared.Context,
    generated: *std.array_list.Managed(model.GeneratedFunction),
    names: *std.StringHashMapUnmanaged(source_pkg.Span),
    function_decl: model.GeneratedFunction,
) !void {
    if (names.get(function_decl.name)) |previous_span| {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM076",
            .title = "duplicate generated member",
            .message = try std.fmt.allocPrint(ctx.allocator, "More than one composed annotation capability generates function '{s}'.", .{function_decl.name}),
            .labels = &.{
                diagnostics.primaryLabel(function_decl.span, "duplicate generated function"),
                diagnostics.secondaryLabel(previous_span, "first generated function was here"),
            },
            .help = "Remove one capability use or rename one generated function so composition is explicit.",
        });
        return error.DiagnosticsEmitted;
    }
    try names.put(ctx.allocator, function_decl.name, function_decl.span);
    try generated.append(function_decl);
}

pub fn registerImportAliases(
    ctx: *shared.Context,
    imports: []const model.Import,
    root_top_level_names: *const std.StringHashMapUnmanaged(void),
    map: *std.StringHashMapUnmanaged(source_pkg.Span),
) !void {
    for (imports) |import_decl| {
        if (import_decl.package_name != null) continue;
        const visible = import_decl.alias orelse import_decl.module_name;
        // An import alias (or bare module root) that collides with one of this package's own
        // top-level declarations is a duplicate top-level name: the alias would otherwise
        // shadow or misresolve the local decl. This is checked independently of the per-file
        // dedup below (whose composite key can never collide with a plain decl name), so an
        // `import Foundation as Foo` next to a local `struct Foo` still reports KSEM003.
        if (root_top_level_names.contains(visible)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM003",
                .title = "duplicate top-level name",
                .message = try std.fmt.allocPrint(ctx.allocator, "Kira found more than one top-level declaration named '{s}'.", .{visible}),
                .labels = &.{
                    diagnostics.primaryLabel(import_decl.span, "this import name collides with a top-level declaration"),
                },
                .help = "Rename the import alias or the conflicting declaration so the symbol is unambiguous.",
            });
            return error.DiagnosticsEmitted;
        }
        // Imports are file-scoped, so the same module may be imported by sibling files
        // without conflict. Dedupe per file (keyed by source path) and flag only a
        // repeated import within the SAME file. The composite key never collides with
        // the plain top-level decl names also stored in this map.
        const key = try std.fmt.allocPrint(ctx.allocator, "{s}\x00import\x00{s}", .{ import_decl.source_path, visible });
        if (map.get(key)) |previous_span| {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM003",
                .title = "duplicate top-level name",
                .message = try std.fmt.allocPrint(ctx.allocator, "Kira found more than one import named '{s}' in this file.", .{visible}),
                .labels = &.{
                    diagnostics.primaryLabel(import_decl.span, "duplicate import"),
                    diagnostics.secondaryLabel(previous_span, "first import was here"),
                },
                .help = "Import each module at most once per file.",
            });
            return error.DiagnosticsEmitted;
        }
        try map.put(ctx.allocator, key, import_decl.span);
    }
}
