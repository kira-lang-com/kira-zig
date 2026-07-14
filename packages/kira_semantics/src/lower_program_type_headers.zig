//! Type-header resolution for local and imported struct/class declarations:
//! inheritance-aware field/method flattening (parent views), imported method
//! surfaces, and annotation-generated methods. Split from lower_program_types.zig.
const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const parent = @import("lower_program.zig");
const type_members = @import("lower_program_type_members.zig");
const TypeSource = parent.TypeSource;
const LocalTypeMap = parent.LocalTypeMap;
const ResolverState = parent.ResolverState;
const applyLocalTypeMembers = type_members.applyLocalTypeMembers;
const methodNameExists = type_members.methodNameExists;

pub fn registerImportedFunctionHeaders(
    ctx: *shared.Context,
    function_headers: *std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    for (ctx.imported_globals.functions) |function_decl| {
        if (!function_decl.is_extern) continue;
        try function_headers.put(ctx.allocator, function_decl.name, .{
            .id = @as(u32, @intCast(function_headers.count())),
            .params = function_decl.params,
            .param_ownership = function_decl.param_ownership,
            .execution = if (function_decl.execution == .inherited) .native else function_decl.execution,
            .return_type = function_decl.return_type,
            .return_ownership = function_decl.return_ownership,
            .is_extern = true,
            .foreign = function_decl.foreign,
            .span = .{ .start = 0, .end = 0 },
        });
    }
}

pub fn resolveTypeHeader(
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
        .local => |type_decl| blk: {
            // A local type's field/annotation types are resolved exactly once, here. Bind
            // the DECLARING file (imports are file-scoped) so those types are gated by the
            // file that wrote them — including when this resolution was reached recursively
            // from a subtype declared in a different file.
            const previous_package = ctx.current_package;
            const previous_source_path = ctx.current_source_path;
            if (ctx.local_type_origins) |origins| {
                if (origins.get(type_name)) |origin| {
                    ctx.current_package = origin.package_name;
                    ctx.current_source_path = origin.source_path;
                }
            }
            defer {
                ctx.current_package = previous_package;
                ctx.current_source_path = previous_source_path;
            }
            break :blk try resolveLocalTypeHeader(ctx, local_types, resolver_states, type_headers, type_decl);
        },
        .imported => |type_decl| try resolveImportedTypeHeader(ctx, local_types, resolver_states, type_headers, type_decl),
    };

    try type_headers.put(ctx.allocator, type_name, header);
    try resolver_states.put(ctx.allocator, type_name, .resolved);
    return header;
}

pub fn resolveLocalTypeHeader(
    ctx: *shared.Context,
    local_types: *const LocalTypeMap,
    resolver_states: *std.StringHashMapUnmanaged(ResolverState),
    type_headers: *std.StringHashMapUnmanaged(shared.TypeHeader),
    type_decl: syntax.ast.TypeDecl,
) anyerror!shared.TypeHeader {
    try shared.validateAnnotationPlacement(ctx, type_decl.annotations, if (type_decl.kind == .class) .class_decl else .struct_decl, null);
    const execution = try @import("lower_shared_annotations.zig").resolveTypeExecutionAnnotations(
        ctx,
        type_decl.annotations,
        if (type_decl.kind == .class) .class else .struct_decl,
    );
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
        .execution = execution,
        .fields = try fields.toOwnedSlice(),
        .methods = try methods.toOwnedSlice(),
        .parent_views = try parent_views.toOwnedSlice(),
        .ffi = ffi_type,
        .is_printable = hasAnnotationNamed(type_decl.annotations, "Printable"),
        .derive_copy = type_decl.derive_copy,
        .span = type_decl.span,
    };
}

pub fn resolveImportedTypeHeader(
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
        .kind = type_decl.kind,
        .execution = type_decl.execution,
        .fields = try fields.toOwnedSlice(),
        .methods = try methods.toOwnedSlice(),
        .parent_views = try parent_views.toOwnedSlice(),
        .ffi = type_decl.ffi,
        .is_printable = false,
        .span = .{ .start = 0, .end = 0 },
    };
}

pub fn typeSourceSpan(source: TypeSource) source_pkg.Span {
    return switch (source) {
        .local => |type_decl| type_decl.span,
        .imported => .{ .start = 0, .end = 0 },
    };
}

pub fn findTypeSource(ctx: *shared.Context, local_types: *const LocalTypeMap, type_name: []const u8) ?TypeSource {
    if (local_types.get(type_name)) |type_decl| return .{ .local = type_decl };
    if (ctx.imported_globals.findType(type_name)) |type_decl| return .{ .imported = type_decl };
    return null;
}

pub fn appendResolvedParents(
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

pub fn appendImportedParents(
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

pub fn appendDeclaredImportedMethods(
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
            .param_ownership = if (function_decl.param_ownership.len > 0) function_decl.param_ownership[1..] else &.{},
            .return_type = function_decl.return_type,
            .return_ownership = function_decl.return_ownership,
            .span = .{ .start = 0, .end = 0 },
        });
    }
}

pub fn appendGeneratedAnnotationMethods(
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
                .param_ownership = function_decl.param_ownership,
                .return_type = function_decl.return_type,
                .return_ownership = function_decl.return_ownership,
                .span = function_decl.span,
            });
        }
    }
}

fn hasAnnotationNamed(annotations: []const syntax.ast.Annotation, name: []const u8) bool {
    for (annotations) |annotation| {
        const leaf = annotation.name.segments[annotation.name.segments.len - 1].text;
        if (std.mem.eql(u8, leaf, name)) return true;
    }
    return false;
}
