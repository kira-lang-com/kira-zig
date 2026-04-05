const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const exprs = @import("lower_exprs.zig");
const ImportedGlobals = @import("imported_globals.zig").ImportedGlobals;

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

    var constructs = std.array_list.Managed(model.Construct).init(allocator);
    var types = std.array_list.Managed(model.TypeDecl).init(allocator);
    var forms = std.array_list.Managed(model.ConstructForm).init(allocator);
    var functions = std.array_list.Managed(model.Function).init(allocator);

    for (imported_globals.functions) |function_decl| {
        if (!function_decl.is_extern) continue;
        try function_headers.put(allocator, function_decl.name, .{
            .id = @as(u32, @intCast(function_headers.count())),
            .params = function_decl.params,
            .execution = if (function_decl.execution == .inherited) .native else function_decl.execution,
            .return_type = function_decl.return_type,
            .is_extern = true,
            .foreign = function_decl.foreign,
            .span = .{ .start = 0, .end = 0 },
        });
    }

    for (imported_globals.types) |type_decl| {
        var fields = std.array_list.Managed(model.Field).init(allocator);
        for (type_decl.fields) |field_decl| {
            try fields.append(.{
                .name = try allocator.dupe(u8, field_decl.name),
                .ty = field_decl.ty,
                .explicit_type = true,
                .annotations = &.{},
                .span = .{ .start = 0, .end = 0 },
            });
        }
        const lowered_fields = try fields.toOwnedSlice();
        try type_headers.put(allocator, type_decl.name, .{
            .fields = lowered_fields,
            .ffi = type_decl.ffi,
            .span = .{ .start = 0, .end = 0 },
        });
        try types.append(.{
            .name = try allocator.dupe(u8, type_decl.name),
            .fields = lowered_fields,
            .ffi = type_decl.ffi,
            .span = .{ .start = 0, .end = 0 },
        });
    }

    for (program.decls) |decl| {
        switch (decl) {
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
                const lowered = try lowerTypeDecl(&ctx, type_decl);
                try type_headers.put(allocator, lowered.name, .{
                    .fields = lowered.fields,
                    .ffi = lowered.ffi,
                    .span = lowered.span,
                });
                try types.append(lowered);
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
                        try param_types.append(shared.typeFromSyntax(type_expr.*));
                    } else {
                        try param_types.append(.{ .kind = .unknown });
                    }
                }
                try function_headers.put(allocator, function_decl.name, .{
                    .id = @as(u32, @intCast(function_headers.count())),
                    .params = try param_types.toOwnedSlice(),
                    .execution = if (foreign != null and annotation_info.execution == .inherited) .native else annotation_info.execution,
                    .return_type = if (function_decl.return_type) |return_type| shared.typeFromSyntax(return_type.*) else .{ .kind = .unknown },
                    .is_extern = foreign != null,
                    .foreign = foreign,
                    .span = function_decl.span,
                });
            },
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

fn lowerTypeDecl(ctx: *shared.Context, type_decl: syntax.ast.TypeDecl) !model.TypeDecl {
    try shared.validateAnnotationPlacement(ctx, type_decl.annotations, .type_decl, null);
    const ffi_type = try shared.resolveNamedTypeInfo(ctx, type_decl.annotations, type_decl.span);
    var fields = std.array_list.Managed(model.Field).init(ctx.allocator);
    for (type_decl.members) |member| {
        if (member == .field_decl and !member.field_decl.is_static) try fields.append(try lowerField(ctx, member.field_decl, null));
    }
    return .{
        .name = try ctx.allocator.dupe(u8, type_decl.name),
        .fields = try fields.toOwnedSlice(),
        .ffi = ffi_type,
        .span = type_decl.span,
    };
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
            .content_section => |content_section| content = try exprs.lowerBuilderBlock(ctx, content_section.builder, imports, null),
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

        const param_type = shared.typeFromSyntax(param.type_expr.?.*);
        try scope.put(ctx.allocator, param.name, .{ .id = next_local_id, .ty = param_type });
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

    const explicit_return_type = if (function_decl.return_type) |return_type| shared.typeFromSyntax(return_type.*) else model.ResolvedType{ .kind = .unknown };
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
        .ty = field_type,
        .explicit_type = field_decl.type_expr != null,
        .annotations = try shared.lowerAnnotations(ctx, field_decl.annotations),
        .span = field_decl.span,
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
