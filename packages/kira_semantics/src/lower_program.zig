const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const exprs = @import("lower_exprs.zig");
const ImportedGlobals = @import("imported_globals.zig").ImportedGlobals;

const ResolvedFieldOverride = struct {
    field: model.Field,
    inherited_offset: u32,
};

const ResolvedMethodMember = shared.MethodMember;

const TypeSource = union(enum) {
    local: syntax.ast.TypeDecl,
    imported: @import("imported_globals.zig").ImportedType,
};

const LocalTypeMap = std.StringHashMapUnmanaged(syntax.ast.TypeDecl);

const ResolverState = enum {
    resolving,
    resolved,
};

pub fn lowerProgram(
    allocator: std.mem.Allocator,
    program: syntax.ast.Program,
    imported_globals: ImportedGlobals,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !model.Program {
    var ctx = shared.Context{
        .allocator = allocator,
        .diagnostics = out_diagnostics,
        .imported_globals = imported_globals,
    };

    const imports = try lowerImports(&ctx, program.imports);

    var top_level_names = std.StringHashMapUnmanaged(source_pkg.Span){};
    defer top_level_names.deinit(allocator);
    try registerImportAliases(&ctx, imports, &top_level_names);

    var construct_headers = std.StringHashMapUnmanaged(shared.ConstructHeader){};
    defer construct_headers.deinit(allocator);
    var function_headers = std.StringHashMapUnmanaged(shared.FunctionHeader){};
    defer function_headers.deinit(allocator);
    var type_headers = std.StringHashMapUnmanaged(shared.TypeHeader){};
    defer type_headers.deinit(allocator);
    ctx.type_headers = &type_headers;
    var annotation_headers = std.StringHashMapUnmanaged(shared.AnnotationHeader){};
    defer annotation_headers.deinit(allocator);
    try shared.registerBuiltinAnnotationHeaders(allocator, &annotation_headers);
    ctx.annotation_headers = &annotation_headers;

    var annotations = std.array_list.Managed(model.AnnotationDecl).init(allocator);
    var capabilities = std.array_list.Managed(model.CapabilityDecl).init(allocator);
    var capability_headers = std.StringHashMapUnmanaged(usize){};
    defer capability_headers.deinit(allocator);
    var constructs = std.array_list.Managed(model.Construct).init(allocator);
    var types = std.array_list.Managed(model.TypeDecl).init(allocator);
    var forms = std.array_list.Managed(model.ConstructForm).init(allocator);
    var functions = std.array_list.Managed(model.Function).init(allocator);
    var local_types = LocalTypeMap{};
    defer local_types.deinit(allocator);
    var resolver_states = std.StringHashMapUnmanaged(ResolverState){};
    defer resolver_states.deinit(allocator);

    for (program.decls) |decl| {
        switch (decl) {
            .annotation_decl => |annotation_decl| {
                if (annotation_headers.get(annotation_decl.name)) |previous| {
                    try diagnostics.appendOwned(allocator, out_diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM060",
                        .title = "duplicate annotation declaration",
                        .message = try std.fmt.allocPrint(allocator, "Kira found more than one annotation declaration named '{s}'.", .{annotation_decl.name}),
                        .labels = &.{
                            diagnostics.primaryLabel(annotation_decl.span, "duplicate annotation declaration"),
                            diagnostics.secondaryLabel(previous.decl.span, "first annotation declaration was here"),
                        },
                        .help = "Rename one of the annotations so the symbol is unambiguous.",
                    });
                    return error.DiagnosticsEmitted;
                }
                try shared.registerTopLevelName(allocator, out_diagnostics, &top_level_names, annotation_decl.name, annotation_decl.span);
                const lowered = try shared.lowerAnnotationDecl(&ctx, annotation_decl, "");
                try annotation_headers.put(allocator, lowered.name, .{
                    .index = annotations.items.len,
                    .decl = lowered,
                });
                try annotations.append(lowered);
            },
            .capability_decl => |capability_decl| {
                if (capability_headers.get(capability_decl.name)) |previous_index| {
                    try diagnostics.appendOwned(allocator, out_diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM072",
                        .title = "duplicate capability declaration",
                        .message = try std.fmt.allocPrint(allocator, "Kira found more than one capability declaration named '{s}'.", .{capability_decl.name}),
                        .labels = &.{
                            diagnostics.primaryLabel(capability_decl.span, "duplicate capability declaration"),
                            diagnostics.secondaryLabel(capabilities.items[previous_index].span, "first capability declaration was here"),
                        },
                        .help = "Rename one of the capabilities so annotation composition stays unambiguous.",
                    });
                    return error.DiagnosticsEmitted;
                }
                try shared.registerTopLevelName(allocator, out_diagnostics, &top_level_names, capability_decl.name, capability_decl.span);
                const lowered = try shared.lowerCapabilityDecl(&ctx, capability_decl, "");
                try capability_headers.put(allocator, lowered.name, capabilities.items.len);
                try capabilities.append(lowered);
            },
            else => {},
        }
    }

    for (annotations.items) |*annotation_decl| {
        annotation_decl.generated_functions = try composeAnnotationGeneratedFunctions(&ctx, annotation_decl.*, capabilities.items, &capability_headers);
        if (annotation_headers.getPtr(annotation_decl.name)) |header| {
            header.decl = annotation_decl.*;
        }
    }

    for (program.decls) |decl| {
        switch (decl) {
            .annotation_decl, .capability_decl => {},
            .construct_decl => |construct_decl| {
                try shared.registerTopLevelName(allocator, out_diagnostics, &top_level_names, construct_decl.name, construct_decl.span);
                const lowered = try lowerConstructDecl(&ctx, construct_decl);
                try construct_headers.put(allocator, lowered.name, .{
                    .index = constructs.items.len,
                    .span = lowered.span,
                });
                try constructs.append(lowered);
            },
            .type_decl => |type_decl| {
                try shared.registerTopLevelName(allocator, out_diagnostics, &top_level_names, type_decl.name, type_decl.span);
                try local_types.put(allocator, type_decl.name, type_decl);
            },
            .construct_form_decl => |form_decl| {
                try shared.registerTopLevelName(allocator, out_diagnostics, &top_level_names, form_decl.name, form_decl.span);
            },
            .function_decl => |function_decl| {
                try shared.registerTopLevelName(allocator, out_diagnostics, &top_level_names, function_decl.name, function_decl.span);
                const annotation_info = try shared.resolveFunctionAnnotations(&ctx, function_decl.annotations);
                const foreign = try shared.resolveForeignFunction(&ctx, function_decl.annotations, function_decl.span);
                var param_types = std.array_list.Managed(model.ResolvedType).init(allocator);
                for (function_decl.params) |param| {
                    if (param.type_expr) |type_expr| {
                        try param_types.append(try shared.typeFromSyntax(allocator, type_expr.*));
                    } else {
                        try param_types.append(.{ .kind = .unknown });
                    }
                }
                try function_headers.put(allocator, function_decl.name, .{
                    .id = @as(u32, @intCast(function_headers.count())),
                    .params = try param_types.toOwnedSlice(),
                    .execution = if (foreign != null and annotation_info.execution == .inherited) .native else annotation_info.execution,
                    .return_type = if (function_decl.return_type) |return_type| try shared.typeFromSyntax(allocator, return_type.*) else .{ .kind = .unknown },
                    .is_extern = foreign != null,
                    .foreign = foreign,
                    .span = function_decl.span,
                });
            },
        }
    }

    for (imported_globals.types) |type_decl| {
        _ = try resolveTypeHeader(&ctx, &local_types, &resolver_states, &type_headers, .{ .imported = type_decl }, type_decl.name);
    }

    var local_type_iterator = local_types.iterator();
    while (local_type_iterator.next()) |entry| {
        _ = try resolveTypeHeader(&ctx, &local_types, &resolver_states, &type_headers, .{ .local = entry.value_ptr.* }, entry.key_ptr.*);
    }

    var type_header_iterator = type_headers.iterator();
    while (type_header_iterator.next()) |entry| {
        try types.append(.{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .kind = entry.value_ptr.kind,
            .fields = @constCast(entry.value_ptr.fields),
            .ffi = entry.value_ptr.ffi,
            .span = entry.value_ptr.span,
        });
    }

    try registerImportedFunctionHeaders(&ctx, &function_headers);
    for (program.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| try registerTypeMethodHeaders(&ctx, type_decl, &function_headers),
            .function_decl => {},
            else => {},
        }
    }

    var main_index: ?usize = null;
    var first_main_span: ?source_pkg.Span = null;

    for (imported_globals.functions) |function_decl| {
        if (!function_decl.is_extern) continue;
        const header = function_headers.get(function_decl.name) orelse continue;
        const empty_statements = try allocator.alloc(model.Statement, 0);
        const params = try lowerImportedParams(allocator, function_decl.params);
        try functions.append(.{
            .id = header.id,
            .name = try allocator.dupe(u8, function_decl.name),
            .is_main = false,
            .execution = header.execution,
            .is_extern = true,
            .foreign = function_decl.foreign,
            .annotations = &.{},
            .params = params,
            .locals = &.{},
            .return_type = function_decl.return_type,
            .body = empty_statements,
            .span = header.span,
        });
    }

    for (program.decls) |decl| {
        switch (decl) {
            .construct_form_decl => |form_decl| try forms.append(try lowerConstructForm(&ctx, form_decl, imports, constructs.items, &construct_headers)),
            .function_decl => |function_decl| {
                const lowered = try lowerFunction(&ctx, function_decl, imports, &function_headers);
                if (lowered.is_main) {
                    if (first_main_span) |previous_span| {
                        try diagnostics.appendOwned(allocator, out_diagnostics, .{
                            .severity = .@"error",
                            .code = "KSEM002",
                            .title = "multiple @Main entrypoints",
                            .message = "A module can only have one @Main entrypoint.",
                            .labels = &.{
                                diagnostics.primaryLabel(function_decl.span, "this function is marked as another entrypoint"),
                                diagnostics.secondaryLabel(previous_span, "the first @Main entrypoint was declared here"),
                            },
                            .help = "Keep @Main on exactly one function.",
                        });
                        return error.DiagnosticsEmitted;
                    }
                    first_main_span = function_decl.span;
                    main_index = functions.items.len;
                }
                try functions.append(lowered);
            },
            .type_decl => |type_decl| {
                const lowered_methods = try lowerTypeMethods(&ctx, type_decl, imports, &function_headers);
                try functions.appendSlice(lowered_methods);
            },
            else => {},
        }
    }

    if (main_index == null) {
        try diagnostics.appendOwned(allocator, out_diagnostics, .{
            .severity = .@"error",
            .code = "KSEM001",
            .title = "missing @Main entrypoint",
            .message = "This module cannot run because no function is marked with @Main.",
            .help = "Add @Main to exactly one zero-argument function, for example `@Main function entry() { ... }`.",
        });
        return error.DiagnosticsEmitted;
    }

    if (diagnostics.hasErrors(out_diagnostics.items)) return error.DiagnosticsEmitted;

    return .{
        .imports = imports,
        .annotations = try annotations.toOwnedSlice(),
        .capabilities = try capabilities.toOwnedSlice(),
        .constructs = try constructs.toOwnedSlice(),
        .types = try types.toOwnedSlice(),
        .forms = try forms.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
        .entry_index = main_index.?,
    };
}

fn lowerImports(ctx: *shared.Context, imports: []const syntax.ast.ImportDecl) ![]model.Import {
    const lowered = try ctx.allocator.alloc(model.Import, imports.len);
    for (imports, 0..) |import_decl, index| {
        lowered[index] = .{
            .module_name = try shared.qualifiedNameText(ctx.allocator, import_decl.module_name),
            .alias = if (import_decl.alias) |alias| try ctx.allocator.dupe(u8, alias) else null,
            .span = import_decl.span,
        };
    }
    return lowered;
}

fn composeAnnotationGeneratedFunctions(
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

fn appendGeneratedFunctionUnique(
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

fn registerImportAliases(ctx: *shared.Context, imports: []const model.Import, map: *std.StringHashMapUnmanaged(source_pkg.Span)) !void {
    for (imports) |import_decl| {
        const visible = import_decl.alias orelse import_decl.module_name;
        try shared.registerTopLevelName(ctx.allocator, ctx.diagnostics, map, visible, import_decl.span);
    }
}

fn lowerConstructDecl(ctx: *shared.Context, construct_decl: syntax.ast.ConstructDecl) !model.Construct {
    try shared.validateAnnotationPlacement(ctx, construct_decl.annotations, .construct_decl, null);
    var allowed_annotations = std.array_list.Managed(model.AnnotationRule).init(ctx.allocator);
    var allowed_lifecycle_hooks = std.array_list.Managed([]const u8).init(ctx.allocator);
    var required_content = false;

    for (construct_decl.sections) |section| {
        switch (section.kind) {
            .annotations => {
                for (section.entries) |entry| {
                    if (entry == .annotation_spec) {
                        _ = try shared.resolveAnnotationHeader(ctx, entry.annotation_spec.name);
                        try allowed_annotations.append(.{
                            .name = try shared.qualifiedNameLeaf(ctx.allocator, entry.annotation_spec.name),
                            .span = entry.annotation_spec.span,
                        });
                    }
                }
            },
            .requires => {
                for (section.entries) |entry| {
                    if (entry == .named_rule) {
                        const rule_name = entry.named_rule.name.segments[0].text;
                        if (std.mem.eql(u8, rule_name, "content")) required_content = true;
                    }
                }
            },
            .lifecycle => {
                for (section.entries) |entry| {
                    if (entry == .lifecycle_hook) {
                        try allowed_lifecycle_hooks.append(try ctx.allocator.dupe(u8, entry.lifecycle_hook.name));
                    }
                }
            },
            else => {},
        }
    }

    return .{
        .name = try ctx.allocator.dupe(u8, construct_decl.name),
        .allowed_annotations = try allowed_annotations.toOwnedSlice(),
        .required_content = required_content,
        .allowed_lifecycle_hooks = try allowed_lifecycle_hooks.toOwnedSlice(),
        .span = construct_decl.span,
    };
}

fn registerImportedFunctionHeaders(
    ctx: *shared.Context,
    function_headers: *std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    for (ctx.imported_globals.functions) |function_decl| {
        if (!function_decl.is_extern) continue;
        try function_headers.put(ctx.allocator, function_decl.name, .{
            .id = @as(u32, @intCast(function_headers.count())),
            .params = function_decl.params,
            .execution = if (function_decl.execution == .inherited) .native else function_decl.execution,
            .return_type = function_decl.return_type,
            .is_extern = true,
            .foreign = function_decl.foreign,
            .span = .{ .start = 0, .end = 0 },
        });
    }
}

fn resolveTypeHeader(
    ctx: *shared.Context,
    local_types: *const LocalTypeMap,
    resolver_states: *std.StringHashMapUnmanaged(ResolverState),
    type_headers: *std.StringHashMapUnmanaged(shared.TypeHeader),
    source: TypeSource,
    type_name: []const u8,
) anyerror!shared.TypeHeader {
    if (type_headers.get(type_name)) |header| return header;
    if (resolver_states.get(type_name)) |state| {
        if (state == .resolving) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM050",
                .title = "inheritance cycle",
                .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' participates in an inheritance cycle.", .{type_name}),
                .labels = &.{diagnostics.primaryLabel(typeSourceSpan(source), "cycle reaches this type again")},
                .help = "Remove the cycle so each inheritance chain terminates at a concrete base type.",
            });
            return error.DiagnosticsEmitted;
        }
    }
    try resolver_states.put(ctx.allocator, type_name, .resolving);

    const header = switch (source) {
        .local => |type_decl| try resolveLocalTypeHeader(ctx, local_types, resolver_states, type_headers, type_decl),
        .imported => |type_decl| try resolveImportedTypeHeader(ctx, local_types, resolver_states, type_headers, type_decl),
    };

    try type_headers.put(ctx.allocator, type_name, header);
    try resolver_states.put(ctx.allocator, type_name, .resolved);
    return header;
}

fn resolveLocalTypeHeader(
    ctx: *shared.Context,
    local_types: *const LocalTypeMap,
    resolver_states: *std.StringHashMapUnmanaged(ResolverState),
    type_headers: *std.StringHashMapUnmanaged(shared.TypeHeader),
    type_decl: syntax.ast.TypeDecl,
) anyerror!shared.TypeHeader {
    try shared.validateAnnotationPlacement(ctx, type_decl.annotations, if (type_decl.kind == .class) .class_decl else .struct_decl, null);
    if (type_decl.kind == .struct_decl and type_decl.parents.len != 0) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM073",
            .title = "struct cannot inherit",
            .message = try std.fmt.allocPrint(ctx.allocator, "The struct '{s}' cannot declare an `extends` clause.", .{type_decl.name}),
            .labels = &.{diagnostics.primaryLabel(type_decl.span, "struct declarations do not inherit")},
            .help = "Use `class` when inheritance is intended, or remove the `extends` clause.",
        });
        return error.DiagnosticsEmitted;
    }
    if (type_decl.kind == .struct_decl) {
        for (type_decl.members) |member| {
            if (member == .function_decl) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM074",
                    .title = "struct cannot declare methods",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The struct '{s}' is value-oriented and cannot declare methods.", .{type_decl.name}),
                    .labels = &.{diagnostics.primaryLabel(member.function_decl.span, "method belongs in a class")},
                    .help = "Use `class` for declarations with behavior, or move the function outside the struct.",
                });
                return error.DiagnosticsEmitted;
            }
        }
    }
    const ffi_type = try shared.resolveNamedTypeInfo(ctx, type_decl.annotations, type_decl.span);
    if (ffi_type != null and type_decl.parents.len != 0) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM053",
            .title = "invalid inheritance target",
            .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' cannot inherit because it is an FFI-defined type.", .{type_decl.name}),
            .labels = &.{diagnostics.primaryLabel(type_decl.span, "FFI types cannot participate in inheritance")},
            .help = "Remove the FFI annotation or inherit from a regular Kira type instead.",
        });
        return error.DiagnosticsEmitted;
    }

    var fields = std.array_list.Managed(model.Field).init(ctx.allocator);
    var methods = std.array_list.Managed(shared.MethodMember).init(ctx.allocator);
    var parent_views = std.array_list.Managed(shared.ParentView).init(ctx.allocator);

    try appendResolvedParents(ctx, local_types, resolver_states, type_headers, type_decl.name, type_decl.parents, &fields, &methods, &parent_views, type_decl.span);
    try appendGeneratedAnnotationMethods(ctx, type_decl, &methods);
    try applyLocalTypeMembers(ctx, type_decl, &fields, &methods);

    return .{
        .kind = if (type_decl.kind == .class) .class else .struct_decl,
        .fields = try fields.toOwnedSlice(),
        .methods = try methods.toOwnedSlice(),
        .parent_views = try parent_views.toOwnedSlice(),
        .ffi = ffi_type,
        .span = type_decl.span,
    };
}

fn resolveImportedTypeHeader(
    ctx: *shared.Context,
    local_types: *const LocalTypeMap,
    resolver_states: *std.StringHashMapUnmanaged(ResolverState),
    type_headers: *std.StringHashMapUnmanaged(shared.TypeHeader),
    type_decl: @import("imported_globals.zig").ImportedType,
) anyerror!shared.TypeHeader {
    if (type_decl.ffi != null and type_decl.parents.len != 0) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM053",
            .title = "invalid inheritance target",
            .message = try std.fmt.allocPrint(ctx.allocator, "The imported type '{s}' cannot inherit because it is an FFI-defined type.", .{type_decl.name}),
            .labels = &.{diagnostics.primaryLabel(.{ .start = 0, .end = 0 }, "FFI types cannot participate in inheritance")},
            .help = "Remove the FFI annotation or inherit from a regular Kira type instead.",
        });
        return error.DiagnosticsEmitted;
    }

    var fields = std.array_list.Managed(model.Field).init(ctx.allocator);
    var methods = std.array_list.Managed(shared.MethodMember).init(ctx.allocator);
    var parent_views = std.array_list.Managed(shared.ParentView).init(ctx.allocator);

    try appendImportedParents(ctx, local_types, resolver_states, type_headers, type_decl.name, type_decl.parents, &fields, &methods, &parent_views);
    for (type_decl.fields) |field_decl| {
        try fields.append(.{
            .name = try ctx.allocator.dupe(u8, field_decl.name),
            .owner_type_name = try ctx.allocator.dupe(u8, type_decl.name),
            .storage = field_decl.storage,
            .slot_index = @as(u32, @intCast(fields.items.len)),
            .ty = field_decl.ty,
            .explicit_type = true,
            .default_value = null,
            .annotations = &.{},
            .span = .{ .start = 0, .end = 0 },
        });
    }
    try appendDeclaredImportedMethods(ctx, type_decl.name, &methods);

    return .{
        .fields = try fields.toOwnedSlice(),
        .methods = try methods.toOwnedSlice(),
        .parent_views = try parent_views.toOwnedSlice(),
        .ffi = type_decl.ffi,
        .span = .{ .start = 0, .end = 0 },
    };
}

fn typeSourceSpan(source: TypeSource) source_pkg.Span {
    return switch (source) {
        .local => |type_decl| type_decl.span,
        .imported => .{ .start = 0, .end = 0 },
    };
}

fn findTypeSource(ctx: *shared.Context, local_types: *const LocalTypeMap, type_name: []const u8) ?TypeSource {
    if (local_types.get(type_name)) |type_decl| return .{ .local = type_decl };
    if (ctx.imported_globals.findType(type_name)) |type_decl| return .{ .imported = type_decl };
    return null;
}

fn appendResolvedParents(
    ctx: *shared.Context,
    local_types: *const LocalTypeMap,
    resolver_states: *std.StringHashMapUnmanaged(ResolverState),
    type_headers: *std.StringHashMapUnmanaged(shared.TypeHeader),
    owner_type_name: []const u8,
    parents: []const syntax.ast.QualifiedName,
    fields: *std.array_list.Managed(model.Field),
    methods: *std.array_list.Managed(shared.MethodMember),
    parent_views: *std.array_list.Managed(shared.ParentView),
    owner_span: source_pkg.Span,
) anyerror!void {
    var seen = std.StringHashMapUnmanaged(source_pkg.Span){};
    defer seen.deinit(ctx.allocator);

    for (parents) |parent_name| {
        const parent_leaf = parent_name.segments[parent_name.segments.len - 1].text;
        if (std.mem.eql(u8, owner_type_name, parent_leaf)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM050",
                .title = "inheritance cycle",
                .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' cannot inherit from itself.", .{owner_type_name}),
                .labels = &.{diagnostics.primaryLabel(parent_name.span, "self-inheritance starts a cycle")},
                .help = "Remove the self-reference from the `extends` list.",
            });
            return error.DiagnosticsEmitted;
        }
        if (seen.get(parent_leaf)) |previous_span| {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM051",
                .title = "duplicate parent type",
                .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' lists '{s}' more than once in `extends`.", .{ owner_type_name, parent_leaf }),
                .labels = &.{
                    diagnostics.primaryLabel(parent_name.span, "duplicate parent appears here"),
                    diagnostics.secondaryLabel(previous_span, "the same parent was already listed here"),
                },
                .help = "Keep each direct parent type at most once.",
            });
            return error.DiagnosticsEmitted;
        }
        try seen.put(ctx.allocator, parent_leaf, parent_name.span);

        const parent_source = findTypeSource(ctx, local_types, parent_leaf) orelse {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM052",
                .title = "unknown parent type",
                .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not resolve the parent type '{s}'.", .{parent_leaf}),
                .labels = &.{diagnostics.primaryLabel(parent_name.span, "unknown parent type")},
                .help = "Declare the parent type before using it, or import the module that defines it.",
            });
            return error.DiagnosticsEmitted;
        };
        const parent_header = try resolveTypeHeader(ctx, local_types, resolver_states, type_headers, parent_source, parent_leaf);
        if (parent_header.ffi != null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM053",
                .title = "invalid inheritance target",
                .message = try std.fmt.allocPrint(ctx.allocator, "The parent type '{s}' cannot be inherited because it is an FFI-defined type.", .{parent_leaf}),
                .labels = &.{diagnostics.primaryLabel(parent_name.span, "this parent is not a regular Kira type")},
                .help = "Inherit only from regular Kira types.",
            });
            return error.DiagnosticsEmitted;
        }

        const parent_offset = @as(u32, @intCast(fields.items.len));
        try parent_views.append(.{
            .type_name = try ctx.allocator.dupe(u8, parent_leaf),
            .offset = parent_offset,
            .span = parent_name.span,
        });
        for (parent_header.parent_views) |parent_view| {
            try parent_views.append(.{
                .type_name = parent_view.type_name,
                .offset = parent_offset + parent_view.offset,
                .span = parent_view.span,
            });
        }
        for (parent_header.fields) |field_decl| {
            var cloned = field_decl;
            cloned.slot_index = parent_offset + field_decl.slot_index;
            try fields.append(cloned);
        }
        for (parent_header.methods) |method_decl| {
            var cloned = method_decl;
            cloned.receiver_offset = parent_offset + method_decl.receiver_offset;
            try methods.append(cloned);
        }
    }

    _ = owner_span;
}

fn appendImportedParents(
    ctx: *shared.Context,
    local_types: *const LocalTypeMap,
    resolver_states: *std.StringHashMapUnmanaged(ResolverState),
    type_headers: *std.StringHashMapUnmanaged(shared.TypeHeader),
    owner_type_name: []const u8,
    parents: []const []const u8,
    fields: *std.array_list.Managed(model.Field),
    methods: *std.array_list.Managed(shared.MethodMember),
    parent_views: *std.array_list.Managed(shared.ParentView),
) anyerror!void {
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(ctx.allocator);

    for (parents) |parent_name| {
        if (std.mem.eql(u8, owner_type_name, parent_name)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM050",
                .title = "inheritance cycle",
                .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' cannot inherit from itself.", .{owner_type_name}),
                .labels = &.{diagnostics.primaryLabel(.{ .start = 0, .end = 0 }, "self-inheritance starts a cycle")},
                .help = "Remove the self-reference from the imported type's `extends` list.",
            });
            return error.DiagnosticsEmitted;
        }
        if (seen.contains(parent_name)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM051",
                .title = "duplicate parent type",
                .message = try std.fmt.allocPrint(ctx.allocator, "The imported type '{s}' lists '{s}' more than once in `extends`.", .{ owner_type_name, parent_name }),
                .labels = &.{diagnostics.primaryLabel(.{ .start = 0, .end = 0 }, "duplicate parent appears in imported metadata")},
                .help = "Keep each direct parent type at most once.",
            });
            return error.DiagnosticsEmitted;
        }
        try seen.put(ctx.allocator, parent_name, {});

        const parent_source = findTypeSource(ctx, local_types, parent_name) orelse {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM052",
                .title = "unknown parent type",
                .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not resolve the imported parent type '{s}'.", .{parent_name}),
                .labels = &.{diagnostics.primaryLabel(.{ .start = 0, .end = 0 }, "unknown imported parent type")},
                .help = "Import the parent type's module before relying on this inheritance chain.",
            });
            return error.DiagnosticsEmitted;
        };
        const parent_header = try resolveTypeHeader(ctx, local_types, resolver_states, type_headers, parent_source, parent_name);
        if (parent_header.ffi != null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM053",
                .title = "invalid inheritance target",
                .message = try std.fmt.allocPrint(ctx.allocator, "The parent type '{s}' cannot be inherited because it is an FFI-defined type.", .{parent_name}),
                .labels = &.{diagnostics.primaryLabel(.{ .start = 0, .end = 0 }, "this imported parent is not a regular Kira type")},
                .help = "Inherit only from regular Kira types.",
            });
            return error.DiagnosticsEmitted;
        }

        const parent_offset = @as(u32, @intCast(fields.items.len));
        try parent_views.append(.{
            .type_name = try ctx.allocator.dupe(u8, parent_name),
            .offset = parent_offset,
            .span = .{ .start = 0, .end = 0 },
        });
        for (parent_header.parent_views) |parent_view| {
            try parent_views.append(.{
                .type_name = parent_view.type_name,
                .offset = parent_offset + parent_view.offset,
                .span = parent_view.span,
            });
        }
        for (parent_header.fields) |field_decl| {
            var cloned = field_decl;
            cloned.slot_index = parent_offset + field_decl.slot_index;
            try fields.append(cloned);
        }
        for (parent_header.methods) |method_decl| {
            var cloned = method_decl;
            cloned.receiver_offset = parent_offset + method_decl.receiver_offset;
            try methods.append(cloned);
        }
    }
}

fn appendDeclaredImportedMethods(
    ctx: *shared.Context,
    owner_type_name: []const u8,
    methods: *std.array_list.Managed(shared.MethodMember),
) !void {
    const prefix = try std.fmt.allocPrint(ctx.allocator, "{s}.", .{owner_type_name});
    for (ctx.imported_globals.functions) |function_decl| {
        if (!std.mem.startsWith(u8, function_decl.name, prefix)) continue;
        const leaf = function_decl.name[prefix.len..];
        if (std.mem.indexOfScalar(u8, leaf, '.') != null) continue;
        try methods.append(.{
            .name = leaf,
            .full_name = function_decl.name,
            .receiver_type_name = try ctx.allocator.dupe(u8, owner_type_name),
            .receiver_offset = 0,
            .params = if (function_decl.params.len > 0) function_decl.params[1..] else &.{},
            .return_type = function_decl.return_type,
            .span = .{ .start = 0, .end = 0 },
        });
    }
}

fn appendGeneratedAnnotationMethods(
    ctx: *shared.Context,
    type_decl: syntax.ast.TypeDecl,
    methods: *std.array_list.Managed(shared.MethodMember),
) !void {
    for (type_decl.annotations) |annotation| {
        const header = try shared.resolveAnnotationHeader(ctx, annotation.name);
        for (header.decl.generated_functions) |function_decl| {
            if (methodNameExists(methods.items, function_decl.name)) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM076",
                    .title = "duplicate generated member",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The annotation-generated function '{s}' conflicts with another inherited or generated method.", .{function_decl.name}),
                    .labels = &.{diagnostics.primaryLabel(function_decl.span, "duplicate generated function")},
                    .help = "Remove one annotation or capability that generates this member.",
                });
                return error.DiagnosticsEmitted;
            }
            try methods.append(.{
                .name = try ctx.allocator.dupe(u8, function_decl.name),
                .full_name = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ type_decl.name, function_decl.name }),
                .receiver_type_name = try ctx.allocator.dupe(u8, type_decl.name),
                .receiver_offset = 0,
                .generated_by = try ctx.allocator.dupe(u8, header.decl.name),
                .overridable = function_decl.overridable,
                .params = function_decl.params,
                .return_type = function_decl.return_type,
                .span = function_decl.span,
            });
        }
    }
}

fn applyLocalTypeMembers(
    ctx: *shared.Context,
    type_decl: syntax.ast.TypeDecl,
    fields: *std.array_list.Managed(model.Field),
    methods: *std.array_list.Managed(shared.MethodMember),
) !void {
    const inherited_field_count = fields.items.len;
    const inherited_method_count = methods.items.len;

    for (type_decl.members) |member| {
        if (member != .field_decl) continue;
        const field_decl = member.field_decl;

        if (field_decl.is_override) {
            const match = try findSingleInheritedField(ctx, fields.items[0..inherited_field_count], field_decl.name, field_decl.span);
            if (field_decl.annotations.len != 0) {
                try emitInvalidFieldOverride(ctx, field_decl.span, "Field overrides cannot add annotations.");
                return error.DiagnosticsEmitted;
            }
            if (field_decl.type_expr) |type_expr| {
                const explicit_type = try shared.typeFromSyntax(ctx.allocator, type_expr.*);
                if (!shared.canAssignExactly(match.field.ty, explicit_type)) {
                    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM059",
                        .title = "field override changes type",
                        .message = try std.fmt.allocPrint(ctx.allocator, "The override for '{s}' must keep the inherited field type {s}.", .{ field_decl.name, try shared.typeTextFromResolved(ctx.allocator, match.field.ty) }),
                        .labels = &.{diagnostics.primaryLabel(field_decl.span, "override changes the inherited field type")},
                        .help = "Remove the type annotation or keep it exactly equal to the inherited field type.",
                    });
                    return error.DiagnosticsEmitted;
                }
            }
            if (match.field.storage != @as(model.FieldStorage, @enumFromInt(@intFromEnum(field_decl.storage)))) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM060",
                    .title = "field override changes mutability",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The override for '{s}' must keep the inherited field mutability.", .{field_decl.name}),
                    .labels = &.{diagnostics.primaryLabel(field_decl.span, "override changes the inherited field mutability")},
                    .help = "Use the same `let` or `var` spelling as the inherited field.",
                });
                return error.DiagnosticsEmitted;
            }
            if (field_decl.value == null) {
                try emitInvalidFieldOverride(ctx, field_decl.span, "Field overrides must provide a replacement default value.");
                return error.DiagnosticsEmitted;
            }
            fields.items[match.inherited_offset].default_value = try lowerFieldDefaultExpr(ctx, field_decl.value.?);
            fields.items[match.inherited_offset].span = field_decl.span;
            continue;
        }

        if (fieldNameExists(fields.items, field_decl.name)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM062",
                .title = "field name conflicts with inherited member",
                .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' already exposes a field named '{s}'.", .{ type_decl.name, field_decl.name }),
                .labels = &.{diagnostics.primaryLabel(field_decl.span, "this field would create a shadow field")},
                .help = "Rename the field or use `override` to replace the inherited default value.",
            });
            return error.DiagnosticsEmitted;
        }

        var lowered = try lowerField(ctx, field_decl, null);
        lowered.owner_type_name = try ctx.allocator.dupe(u8, type_decl.name);
        lowered.slot_index = @as(u32, @intCast(fields.items.len));
        try fields.append(lowered);
    }

    var local_methods = std.array_list.Managed(shared.MethodMember).init(ctx.allocator);
    var overridden_method_names = std.StringHashMapUnmanaged(void){};
    defer overridden_method_names.deinit(ctx.allocator);

    for (type_decl.members) |member| {
        if (member != .function_decl) continue;
        const function_decl = member.function_decl;
        if (methodNameExists(local_methods.items, function_decl.name)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM064",
                .title = "duplicate method name",
                .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' declares more than one method named '{s}'.", .{ type_decl.name, function_decl.name }),
                .labels = &.{diagnostics.primaryLabel(function_decl.span, "duplicate method declaration")},
                .help = "Keep each method name unique within a type.",
            });
            return error.DiagnosticsEmitted;
        }

        const same_name = countMethodsByName(methods.items[0..inherited_method_count], function_decl.name);
        if (function_decl.is_override) {
            if (same_name == 0) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM054",
                    .title = "override has no matching inherited method",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The override '{s}' does not match any inherited method.", .{function_decl.name}),
                    .labels = &.{diagnostics.primaryLabel(function_decl.span, "no inherited method matches this override")},
                    .help = "Remove `override` or inherit a method with the same exact signature.",
                });
                return error.DiagnosticsEmitted;
            }
            const local_method = try makeDeclaredMethodMember(ctx, type_decl.name, function_decl);
            const exact_matches = countExactMethodMatches(methods.items[0..inherited_method_count], local_method);
            if (exact_matches == 0) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM055",
                    .title = "override signature mismatch",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The override '{s}' must match an inherited method signature exactly.", .{function_decl.name}),
                    .labels = &.{diagnostics.primaryLabel(function_decl.span, "override signature does not match any inherited method")},
                    .help = "Match the inherited parameter and return types exactly in v1.",
                });
                return error.DiagnosticsEmitted;
            }
            if (hasNonOverridableExactMethod(methods.items[0..inherited_method_count], local_method)) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM077",
                    .title = "generated member is not overridable",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The generated function '{s}' was not marked `overridable` by its annotation or capability.", .{function_decl.name}),
                    .labels = &.{diagnostics.primaryLabel(function_decl.span, "override targets a non-overridable generated member")},
                    .help = "Remove the override or mark the generated function `overridable` where it is declared.",
                });
                return error.DiagnosticsEmitted;
            }
            if (exact_matches != same_name) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM056",
                    .title = "ambiguous inherited method lookup",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The inherited method name '{s}' resolves to multiple different signatures.", .{function_decl.name}),
                    .labels = &.{diagnostics.primaryLabel(function_decl.span, "override does not resolve the inherited ambiguity")},
                    .help = "Rename one of the parent methods or qualify calls explicitly by parent type name.",
                });
                return error.DiagnosticsEmitted;
            }
            try overridden_method_names.put(ctx.allocator, function_decl.name, {});
            try local_methods.append(local_method);
            continue;
        }

        if (same_name != 0) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM054",
                .title = "override required for inherited method",
                .message = try std.fmt.allocPrint(ctx.allocator, "The method '{s}' already exists on an inherited parent type.", .{function_decl.name}),
                .labels = &.{diagnostics.primaryLabel(function_decl.span, "use `override` to replace the inherited method")},
                .help = "Mark the method with `override` and match the inherited signature exactly.",
            });
            return error.DiagnosticsEmitted;
        }

        try local_methods.append(try makeDeclaredMethodMember(ctx, type_decl.name, function_decl));
    }

    var final_methods = std.array_list.Managed(shared.MethodMember).init(ctx.allocator);
    for (methods.items[0..inherited_method_count]) |method_decl| {
        if (overridden_method_names.contains(method_decl.name)) continue;
        try final_methods.append(method_decl);
    }
    try final_methods.appendSlice(local_methods.items);
    methods.* = final_methods;
}

fn emitInvalidFieldOverride(ctx: *shared.Context, span: source_pkg.Span, message: []const u8) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM063",
        .title = "invalid field override",
        .message = message,
        .labels = &.{diagnostics.primaryLabel(span, "field override is not valid in this form")},
        .help = "Use `override let name = value` or `override var name = value` to replace only the inherited default value.",
    });
}

fn findSingleInheritedField(
    ctx: *shared.Context,
    fields: []const model.Field,
    field_name: []const u8,
    span: source_pkg.Span,
) !ResolvedFieldOverride {
    var match_index: ?u32 = null;
    for (fields, 0..) |field_decl, index| {
        if (!std.mem.eql(u8, field_decl.name, field_name)) continue;
        if (match_index != null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM058",
                .title = "ambiguous variable override target",
                .message = try std.fmt.allocPrint(ctx.allocator, "More than one inherited field named '{s}' is visible here.", .{field_name}),
                .labels = &.{diagnostics.primaryLabel(span, "override target is ambiguous")},
                .help = "Rename one of the conflicting parent fields or avoid overriding the ambiguous name.",
            });
            return error.DiagnosticsEmitted;
        }
        match_index = @as(u32, @intCast(index));
    }
    if (match_index == null) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM054",
            .title = "override has no matching inherited field",
            .message = try std.fmt.allocPrint(ctx.allocator, "The override '{s}' does not match any inherited field.", .{field_name}),
            .labels = &.{diagnostics.primaryLabel(span, "no inherited field matches this override")},
            .help = "Remove `override` or inherit a field with the same name first.",
        });
        return error.DiagnosticsEmitted;
    }
    return .{
        .field = fields[match_index.?],
        .inherited_offset = match_index.?,
    };
}

fn fieldNameExists(fields: []const model.Field, field_name: []const u8) bool {
    for (fields) |field_decl| {
        if (std.mem.eql(u8, field_decl.name, field_name)) return true;
    }
    return false;
}

fn methodNameExists(methods: []const shared.MethodMember, method_name: []const u8) bool {
    for (methods) |method_decl| {
        if (std.mem.eql(u8, method_decl.name, method_name)) return true;
    }
    return false;
}

fn countMethodsByName(methods: []const shared.MethodMember, method_name: []const u8) usize {
    var count: usize = 0;
    for (methods) |method_decl| {
        if (std.mem.eql(u8, method_decl.name, method_name)) count += 1;
    }
    return count;
}

fn countExactMethodMatches(methods: []const shared.MethodMember, candidate: shared.MethodMember) usize {
    var count: usize = 0;
    for (methods) |method_decl| {
        if (!std.mem.eql(u8, method_decl.name, candidate.name)) continue;
        if (sameMethodSignature(method_decl, candidate)) count += 1;
    }
    return count;
}

fn hasNonOverridableExactMethod(methods: []const shared.MethodMember, candidate: shared.MethodMember) bool {
    for (methods) |method_decl| {
        if (!std.mem.eql(u8, method_decl.name, candidate.name)) continue;
        if (sameMethodSignature(method_decl, candidate) and !method_decl.overridable) return true;
    }
    return false;
}

fn sameMethodSignature(lhs: shared.MethodMember, rhs: shared.MethodMember) bool {
    if (lhs.params.len != rhs.params.len) return false;
    if (!shared.canAssignExactly(lhs.return_type, rhs.return_type)) return false;
    for (lhs.params, rhs.params) |lhs_param, rhs_param| {
        if (!shared.canAssignExactly(lhs_param, rhs_param)) return false;
    }
    return true;
}

fn makeDeclaredMethodMember(
    ctx: *shared.Context,
    owner_type_name: []const u8,
    function_decl: syntax.ast.FunctionDecl,
) !shared.MethodMember {
    var params = std.array_list.Managed(model.ResolvedType).init(ctx.allocator);
    for (function_decl.params) |param| {
        if (param.type_expr) |type_expr| {
            try params.append(try shared.typeFromSyntax(ctx.allocator, type_expr.*));
        } else {
            try params.append(.{ .kind = .unknown });
        }
    }
    return .{
        .name = try ctx.allocator.dupe(u8, function_decl.name),
        .full_name = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ owner_type_name, function_decl.name }),
        .receiver_type_name = try ctx.allocator.dupe(u8, owner_type_name),
        .receiver_offset = 0,
        .params = try params.toOwnedSlice(),
        .return_type = if (function_decl.return_type) |return_type| try shared.typeFromSyntax(ctx.allocator, return_type.*) else .{ .kind = .unknown },
        .span = function_decl.span,
    };
}

fn registerTypeMethodHeaders(
    ctx: *shared.Context,
    type_decl: syntax.ast.TypeDecl,
    function_headers: *std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    for (type_decl.members) |member| {
        if (member != .function_decl) continue;
        const function_decl = member.function_decl;
        const annotation_info = try shared.resolveFunctionAnnotations(ctx, function_decl.annotations);
        const foreign = try shared.resolveForeignFunction(ctx, function_decl.annotations, function_decl.span);
        var param_types = std.array_list.Managed(model.ResolvedType).init(ctx.allocator);
        try param_types.append(.{ .kind = .named, .name = type_decl.name });
        for (function_decl.params) |param| {
            if (param.type_expr) |type_expr| {
                try param_types.append(try shared.typeFromSyntax(ctx.allocator, type_expr.*));
            } else {
                try param_types.append(.{ .kind = .unknown });
            }
        }
        const method_name = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ type_decl.name, function_decl.name });
        try function_headers.put(ctx.allocator, method_name, .{
            .id = @as(u32, @intCast(function_headers.count())),
            .params = try param_types.toOwnedSlice(),
            .execution = if (foreign != null and annotation_info.execution == .inherited) .native else annotation_info.execution,
            .return_type = if (function_decl.return_type) |return_type| try shared.typeFromSyntax(ctx.allocator, return_type.*) else .{ .kind = .unknown },
            .is_extern = foreign != null,
            .foreign = foreign,
            .span = function_decl.span,
        });
    }
}

fn lowerTypeMethods(
    ctx: *shared.Context,
    type_decl: syntax.ast.TypeDecl,
    imports: []const model.Import,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) ![]model.Function {
    var methods = std.array_list.Managed(model.Function).init(ctx.allocator);
    for (type_decl.members) |member| {
        if (member != .function_decl) continue;
        try methods.append(try lowerMethodFunction(ctx, type_decl.name, member.function_decl, imports, function_headers));
    }
    return methods.toOwnedSlice();
}

fn lowerMethodFunction(
    ctx: *shared.Context,
    owner_type_name: []const u8,
    function_decl: syntax.ast.FunctionDecl,
    imports: []const model.Import,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !model.Function {
    const self_type_expr = try ctx.allocator.create(syntax.ast.TypeExpr);
    const self_segments = try ctx.allocator.alloc(syntax.ast.NameSegment, 1);
    self_segments[0] = .{ .text = owner_type_name, .span = function_decl.span };
    self_type_expr.* = .{ .named = .{
        .segments = self_segments,
        .span = function_decl.span,
    } };

    var params = std.array_list.Managed(syntax.ast.ParamDecl).init(ctx.allocator);
    try params.append(.{
        .annotations = &.{},
        .name = "self",
        .type_expr = self_type_expr,
        .span = function_decl.span,
    });
    try params.appendSlice(function_decl.params);

    const lowered = try lowerFunction(ctx, .{
        .annotations = function_decl.annotations,
        .name = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ owner_type_name, function_decl.name }),
        .params = try params.toOwnedSlice(),
        .return_type = function_decl.return_type,
        .body = function_decl.body,
        .span = function_decl.span,
    }, imports, function_headers);
    return lowered;
}

fn lowerConstructForm(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    imports: []const model.Import,
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
) !model.ConstructForm {
    try shared.validateAnnotationPlacement(ctx, form_decl.annotations, .construct_form_decl, null);
    const construct_name = try shared.qualifiedNameText(ctx.allocator, form_decl.construct_name);
    const construct_root = form_decl.construct_name.segments[0].text;
    const imported_construct_visible = form_decl.construct_name.segments.len == 1 and ctx.imported_globals.hasConstruct(construct_name);

    var construct_model: ?model.Construct = null;
    if (construct_headers.get(construct_name)) |header| {
        construct_model = constructs[header.index];
    } else if (!imported_construct_visible and !shared.isImportedRoot(construct_root, imports)) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM020",
            .title = "unknown construct",
            .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not find a construct named '{s}'.", .{construct_name}),
            .labels = &.{
                diagnostics.primaryLabel(form_decl.construct_name.span, "unknown construct"),
            },
            .help = "Declare the construct before using its declaration form, or import the library that provides it.",
        });
        return error.DiagnosticsEmitted;
    }

    var fields = std.array_list.Managed(model.Field).init(ctx.allocator);
    var lifecycle_hooks = std.array_list.Managed(model.LifecycleHook).init(ctx.allocator);
    var content: ?model.BuilderBlock = null;

    for (form_decl.body.members) |member| {
        switch (member) {
            .field_decl => |field_decl| try fields.append(try lowerField(ctx, field_decl, construct_model)),
            .content_section => |content_section| {
                try shared.validateAnnotationPlacement(ctx, content_section.annotations, .content_section, construct_model);
                content = try exprs.lowerBuilderBlock(ctx, content_section.builder, imports, null);
            },
            .lifecycle_hook => |hook| {
                if (construct_model) |construct_info| {
                    if (!shared.containsString(construct_info.allowed_lifecycle_hooks, hook.name)) {
                        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                            .severity = .@"error",
                            .code = "KSEM021",
                            .title = "invalid lifecycle hook",
                            .message = try std.fmt.allocPrint(ctx.allocator, "The construct '{s}' does not declare a lifecycle hook named '{s}'.", .{ construct_info.name, hook.name }),
                            .labels = &.{
                                diagnostics.primaryLabel(hook.span, "lifecycle hook is not declared by this construct"),
                            },
                            .help = "Declare the lifecycle hook in the construct's `lifecycle { ... }` section or remove it here.",
                        });
                        return error.DiagnosticsEmitted;
                    }
                }
                try lifecycle_hooks.append(.{
                    .name = try ctx.allocator.dupe(u8, hook.name),
                    .span = hook.span,
                });
            },
            else => {},
        }
    }

    if (construct_model) |construct_info| {
        if (construct_info.required_content and content == null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM022",
                .title = "missing required content block",
                .message = try std.fmt.allocPrint(ctx.allocator, "The construct '{s}' requires a `content {{ ... }}` block.", .{construct_info.name}),
                .labels = &.{
                    diagnostics.primaryLabel(form_decl.span, "required content block is missing"),
                },
                .help = "Add a `content { ... }` section to this declaration.",
            });
            return error.DiagnosticsEmitted;
        }
    }

    return .{
        .construct_name = construct_name,
        .name = try ctx.allocator.dupe(u8, form_decl.name),
        .fields = try fields.toOwnedSlice(),
        .content = content,
        .lifecycle_hooks = try lifecycle_hooks.toOwnedSlice(),
        .span = form_decl.span,
    };
}

fn lowerFunction(
    ctx: *shared.Context,
    function_decl: syntax.ast.FunctionDecl,
    imports: []const model.Import,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !model.Function {
    try shared.validateAnnotationPlacement(ctx, function_decl.annotations, .function_decl, null);
    const annotation_info = try shared.resolveFunctionAnnotations(ctx, function_decl.annotations);
    const foreign = try shared.resolveForeignFunction(ctx, function_decl.annotations, function_decl.span);

    var scope = model.Scope{};
    defer scope.deinit(ctx.allocator);
    var locals = std.array_list.Managed(model.LocalSymbol).init(ctx.allocator);
    var params = std.array_list.Managed(model.Parameter).init(ctx.allocator);
    var next_local_id: u32 = 0;

    for (function_decl.params) |param| {
        if (param.type_expr == null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM024",
                .title = "parameter type is required",
                .message = "Parameters do not have enough context for inference and must declare a type.",
                .labels = &.{
                    diagnostics.primaryLabel(param.span, "parameter type is missing"),
                },
                .help = "Write the parameter type explicitly, for example `value: Int`.",
            });
            return error.DiagnosticsEmitted;
        }

        const param_type = try shared.typeFromSyntax(ctx.allocator, param.type_expr.?.*);
        try scope.put(ctx.allocator, param.name, .{ .id = next_local_id, .ty = param_type, .storage = .immutable });
        try params.append(.{
            .id = next_local_id,
            .name = try ctx.allocator.dupe(u8, param.name),
            .ty = param_type,
            .span = param.span,
        });
        try locals.append(.{
            .id = next_local_id,
            .name = try ctx.allocator.dupe(u8, param.name),
            .ty = param_type,
            .is_param = true,
            .span = param.span,
        });
        next_local_id += 1;
    }

    if (annotation_info.is_main and function_decl.params.len != 0) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM023",
            .title = "invalid @Main signature",
            .message = "The @Main entrypoint must not declare parameters.",
            .labels = &.{
                diagnostics.primaryLabel(function_decl.span, "@Main entrypoint declares parameters"),
            },
            .help = "Move inputs into library-level code and keep the entrypoint parameter-free.",
        });
        return error.DiagnosticsEmitted;
    }

    if (foreign != null and function_decl.body != null) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM041",
            .title = "FFI extern must not declare a body",
            .message = "An @FFI.Extern function must be a declaration terminated with `;`.",
            .labels = &.{
                diagnostics.primaryLabel(function_decl.span, "FFI extern unexpectedly declares a body"),
            },
            .help = "Remove the body and keep only the signature for the foreign declaration.",
        });
        return error.DiagnosticsEmitted;
    }

    const explicit_return_type = if (function_decl.return_type) |return_type| try shared.typeFromSyntax(ctx.allocator, return_type.*) else model.ResolvedType{ .kind = .unknown };
    const body = if (function_decl.body) |syntax_body|
        try exprs.lowerBlockStatements(ctx, syntax_body, imports, &scope, &locals, &next_local_id, function_headers)
    else if (foreign != null)
        try ctx.allocator.alloc(model.Statement, 0)
    else {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM035",
            .title = "function body is required",
            .message = "This declaration does not have a function body, and non-FFI bodyless functions are not supported.",
            .labels = &.{
                diagnostics.primaryLabel(function_decl.span, "missing function body"),
            },
            .help = "Add a `{ ... }` body or mark the declaration with @FFI.Extern.",
        });
        return error.DiagnosticsEmitted;
    };
    const return_type = if (foreign != null)
        (if (explicit_return_type.kind == .unknown) model.ResolvedType{ .kind = .void } else explicit_return_type)
    else
        try exprs.resolveFunctionReturnType(ctx, explicit_return_type, body);
    const header = function_headers.get(function_decl.name).?;

    return .{
        .id = header.id,
        .name = try ctx.allocator.dupe(u8, function_decl.name),
        .is_main = annotation_info.is_main,
        .execution = header.execution,
        .is_extern = foreign != null,
        .foreign = foreign,
        .annotations = annotation_info.annotations,
        .params = try params.toOwnedSlice(),
        .locals = try locals.toOwnedSlice(),
        .return_type = return_type,
        .body = body,
        .span = function_decl.span,
    };
}

fn lowerField(ctx: *shared.Context, field_decl: syntax.ast.FieldDecl, construct_model: ?model.Construct) !model.Field {
    try shared.validateAnnotationPlacement(ctx, field_decl.annotations, .field_decl, construct_model);
    const field_type = try exprs.resolveValueType(ctx, field_decl.type_expr, field_decl.value, field_decl.span);
    return .{
        .name = try ctx.allocator.dupe(u8, field_decl.name),
        .owner_type_name = "",
        .storage = @enumFromInt(@intFromEnum(field_decl.storage)),
        .slot_index = 0,
        .ty = field_type,
        .explicit_type = field_decl.type_expr != null,
        .default_value = if (field_decl.value) |value| try lowerFieldDefaultExpr(ctx, value) else null,
        .annotations = try shared.lowerAnnotations(ctx, field_decl.annotations),
        .span = field_decl.span,
    };
}

fn lowerFieldDefaultExpr(ctx: *shared.Context, expr: *syntax.ast.Expr) !*model.Expr {
    const lowered = try ctx.allocator.create(model.Expr);
    lowered.* = switch (expr.*) {
        .integer => |node| .{ .integer = .{
            .value = node.value,
            .ty = .{ .kind = .integer },
            .span = node.span,
        } },
        .float => |node| .{ .float = .{
            .value = node.value,
            .ty = .{ .kind = .float },
            .span = node.span,
        } },
        .string => |node| .{ .string = .{
            .value = try ctx.allocator.dupe(u8, node.value),
            .ty = .{ .kind = .string },
            .span = node.span,
        } },
        .bool => |node| .{ .boolean = .{
            .value = node.value,
            .ty = .{ .kind = .boolean },
            .span = node.span,
        } },
        .unary => |node| blk: {
            const operand = try lowerFieldDefaultExpr(ctx, node.operand);
            break :blk .{ .unary = .{
                .operand = operand,
                .op = @enumFromInt(@intFromEnum(node.op)),
                .ty = model.hir.exprType(operand.*),
                .span = node.span,
            } };
        },
        else => {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM049",
                .title = "unsupported field default value",
                .message = "Field default values in the executable pipeline currently require a literal or simple unary literal.",
                .labels = &.{diagnostics.primaryLabel(defaultExprSpan(expr.*), "unsupported field default value")},
                .help = "Use a literal default such as `7`, `true`, `1.5`, or `-1`.",
            });
            return error.DiagnosticsEmitted;
        },
    };
    return lowered;
}

fn defaultExprSpan(expr: syntax.ast.Expr) source_pkg.Span {
    return switch (expr) {
        .integer => |node| node.span,
        .float => |node| node.span,
        .string => |node| node.span,
        .bool => |node| node.span,
        .identifier => |node| node.span,
        .array => |node| node.span,
        .unary => |node| node.span,
        .binary => |node| node.span,
        .conditional => |node| node.span,
        .member => |node| node.span,
        .call => |node| node.span,
    };
}

fn lowerImportedParams(allocator: std.mem.Allocator, param_types: []const model.ResolvedType) ![]model.Parameter {
    var params = std.array_list.Managed(model.Parameter).init(allocator);
    for (param_types, 0..) |param_type, index| {
        try params.append(.{
            .id = @as(u32, @intCast(index)),
            .name = try std.fmt.allocPrint(allocator, "arg_{d}", .{index}),
            .ty = param_type,
            .span = .{ .start = 0, .end = 0 },
        });
    }
    return params.toOwnedSlice();
}
