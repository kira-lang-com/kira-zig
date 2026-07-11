const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const exprs = @import("lower_exprs.zig");
const form_surface = @import("construct_form_surface.zig");
const content_validation = @import("lower_construct_content_validation.zig");
const requirements = @import("lower_construct_requirements.zig");
const form_lowering = @import("lower_program_forms.zig");
const ffi_boundary = @import("lower_program_ffi_boundary.zig");
const type_impl = @import("lower_program_types.zig");
const construct_members = @import("lower_construct_members.zig");
const parent = @import("lower_program.zig");

pub fn lowerConstructForm(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    imports: []const model.Import,
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    form_parent: *const std.StringHashMapUnmanaged([]const u8),
) !model.ConstructForm {
    try shared.validateAnnotationPlacement(ctx, form_decl.annotations, .construct_form_decl, null);
    const construct_name = try shared.qualifiedNameText(ctx.allocator, form_decl.construct_name);
    const construct_root = form_decl.construct_name.segments[0].text;
    const imported_construct_visible = form_decl.construct_name.segments.len == 1 and ctx.imported_globals.hasConstruct(construct_name);

    var construct_model: ?model.Construct = null;
    if (requirements.resolveFamilyConstructModel(constructs, construct_headers, form_parent, construct_name)) |family| {
        construct_model = family;
    } else if (!imported_construct_visible and !shared.isImportedRoot(ctx, construct_root, imports)) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM020",
            .title = "unknown construct",
            .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not find a construct named '{s}'.", .{construct_name}),
            .labels = &.{diagnostics.primaryLabel(form_decl.construct_name.span, "unknown construct")},
            .help = "Declare the construct before using its declaration form, or import the library that provides it.",
        });
        return error.DiagnosticsEmitted;
    }

    var fields = std.array_list.Managed(model.Field).init(ctx.allocator);
    var lifecycle_hooks = std.array_list.Managed(model.LifecycleHook).init(ctx.allocator);
    var content: ?model.BuilderBlock = null;

    const body_members = try form_surface.effectiveMembers(ctx, form_decl);
    for (body_members) |member| {
        switch (member) {
            .field_decl => |field_decl| {
                if (field_decl.body != null) continue;
                if (construct_members.hasContentAnnotation(field_decl.annotations)) continue;
                try fields.append(try parent.lowerField(ctx, field_decl, construct_model));
            },
            .content_section => |content_section| {
                try shared.validateAnnotationPlacement(ctx, content_section.annotations, .content_section, construct_model);
                const lowered_content = try exprs.lowerBuilderBlock(ctx, content_section.builder, imports, null, ctx.function_headers);
                if (construct_model) |construct_info| {
                    if (construct_info.content_element_type) |element_type| {
                        try content_validation.validateBlock(ctx, lowered_content, element_type);
                    }
                }
                content = lowered_content;
            },
            .lifecycle_hook => |hook| {
                if (construct_model) |construct_info| {
                    if (!shared.containsString(construct_info.allowed_lifecycle_hooks, hook.name)) {
                        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                            .severity = .@"error",
                            .code = "KSEM021",
                            .title = "invalid lifecycle hook",
                            .message = try std.fmt.allocPrint(ctx.allocator, "The construct '{s}' does not declare a lifecycle hook named '{s}'.", .{ construct_info.name, hook.name }),
                            .labels = &.{diagnostics.primaryLabel(hook.span, "lifecycle hook is not declared by this construct")},
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
        try type_impl.validateFormProperties(ctx, form_decl, construct_info, constructs, construct_headers);
        try type_impl.validateFormContentChannels(ctx, form_decl, construct_info, constructs, construct_headers);
    }

    return .{
        .construct = .{ .construct_name = construct_name },
        .name = try ctx.allocator.dupe(u8, form_decl.name),
        .families = try form_lowering.formFamiliesFor(ctx, form_decl.name),
        .fields = try fields.toOwnedSlice(),
        .content = content,
        .lifecycle_hooks = try lifecycle_hooks.toOwnedSlice(),
        .span = form_decl.span,
    };
}

pub fn lowerFunction(
    ctx: *shared.Context,
    function_decl: syntax.ast.FunctionDecl,
    imports: []const model.Import,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !model.Function {
    // Suspend-free async spine: an `async function` with no reactor-backed
    // suspend point is semantically identical to a synchronous function (the
    // zero-cost, direct-style model). It lowers through the ordinary path with
    // `is_async` preserved as metadata so later phases (executor/reactor/IO)
    // can attach real suspension without re-discovering async intent. Suspend
    // points are not yet wired, so nothing here parks the caller.
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
                .labels = &.{diagnostics.primaryLabel(param.span, "parameter type is missing")},
                .help = "Write the parameter type explicitly, for example `value: Int`.",
            });
            return error.DiagnosticsEmitted;
        }

        const param_type = try shared.typeFromSyntaxChecked(ctx, param.type_expr.?.*);
        const param_ownership = shared.ownershipModeFromSyntax(param.type_expr);
        const local_ownership: model.OwnershipMode = switch (param_ownership) {
            .borrow_read, .borrow_mut => param_ownership,
            .owned, .move, .copy => .owned,
        };
        try scope.put(ctx.allocator, param.name, .{
            .id = next_local_id,
            .ty = param_type,
            .storage = .immutable,
            .ownership = local_ownership,
            .initialized = true,
            .decl_span = param.span,
        });
        try params.append(.{
            .id = next_local_id,
            .name = try ctx.allocator.dupe(u8, param.name),
            .ty = param_type,
            .ownership = param_ownership,
            .span = param.span,
        });
        try locals.append(.{
            .id = next_local_id,
            .name = try ctx.allocator.dupe(u8, param.name),
            .ty = param_type,
            .ownership = local_ownership,
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
            .labels = &.{diagnostics.primaryLabel(function_decl.span, "@Main entrypoint declares parameters")},
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
            .labels = &.{diagnostics.primaryLabel(function_decl.span, "FFI extern unexpectedly declares a body")},
            .help = "Remove the body and keep only the signature for the foreign declaration.",
        });
        return error.DiagnosticsEmitted;
    }

    const explicit_return_ownership = shared.ownershipModeFromSyntax(function_decl.return_type);
    if (explicit_return_ownership == .borrow_read or explicit_return_ownership == .borrow_mut) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM112",
            .title = "returned borrow is not supported yet",
            .message = "Borrowed return types are reserved, but this compiler slice does not validate returned-borrow lifetimes yet.",
            .labels = &.{diagnostics.primaryLabel(function_decl.return_type.?.ownership.span, "borrowed return type is not implemented yet")},
            .help = "Return an owned value for now. Returned borrows will be enabled with input-borrow lifetime validation.",
        });
        return error.DiagnosticsEmitted;
    }

    const explicit_return_type = if (function_decl.return_type) |return_type| try shared.typeFromSyntaxChecked(ctx, return_type.*) else model.ResolvedType{ .kind = .unknown };
    const body = if (function_decl.body) |syntax_body| blk: {
        const previous_locals = ctx.active_locals;
        const previous_next_local_id = ctx.active_next_local_id;
        ctx.active_locals = &locals;
        ctx.active_next_local_id = &next_local_id;
        defer {
            ctx.active_locals = previous_locals;
            ctx.active_next_local_id = previous_next_local_id;
        }
        break :blk try exprs.lowerBlockStatements(ctx, syntax_body, imports, &scope, &locals, &next_local_id, function_headers, 0, explicit_return_type);
    } else if (foreign != null)
        try ctx.allocator.alloc(model.Statement, 0)
    else {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM035",
            .title = "function body is required",
            .message = "This declaration does not have a function body, and non-FFI bodyless functions are not supported.",
            .labels = &.{diagnostics.primaryLabel(function_decl.span, "missing function body")},
            .help = "Add a `{ ... }` body or mark the declaration with @FFI.Extern.",
        });
        return error.DiagnosticsEmitted;
    };
    if (foreign == null) try exprs.rejectOutstandingMovedFields(ctx, &scope);

    const return_type = if (foreign != null)
        (if (explicit_return_type.kind == .unknown) model.ResolvedType{ .kind = .void } else explicit_return_type)
    else
        try exprs.resolveFunctionReturnType(ctx, explicit_return_type, body);
    const header = shared.findFunctionHeader(ctx, function_headers, function_decl.name).?;
    try ffi_boundary.validateDirectFfiBoundary(ctx, function_decl.name, header, body, function_headers);

    return .{
        .id = header.id,
        .name = try ctx.allocator.dupe(u8, function_decl.name),
        .is_main = annotation_info.is_main,
        .is_async = function_decl.is_async,
        .execution = header.execution,
        .is_extern = foreign != null,
        .foreign = foreign,
        .annotations = annotation_info.annotations,
        .params = try params.toOwnedSlice(),
        .locals = try locals.toOwnedSlice(),
        .return_type = return_type,
        .return_ownership = explicit_return_ownership,
        .body = body,
        .span = function_decl.span,
    };
}

pub fn lowerTypeMethodMembers(
    allocator: std.mem.Allocator,
    methods: []const shared.MethodMember,
) ![]model.MethodMember {
    const lowered = try allocator.alloc(model.MethodMember, methods.len);
    for (methods, 0..) |method_decl, index| {
        lowered[index] = .{
            .name = try allocator.dupe(u8, method_decl.name),
            .full_name = try allocator.dupe(u8, method_decl.full_name),
            .receiver_offset = method_decl.receiver_offset,
            .span = method_decl.span,
        };
    }
    return lowered;
}

pub fn lowerImportedParams(allocator: std.mem.Allocator, param_types: []const model.ResolvedType, param_ownership: []const model.OwnershipMode) ![]model.Parameter {
    var params = std.array_list.Managed(model.Parameter).init(allocator);
    for (param_types, 0..) |param_type, index| {
        try params.append(.{
            .id = @as(u32, @intCast(index)),
            .name = try std.fmt.allocPrint(allocator, "arg_{d}", .{index}),
            .ty = param_type,
            .ownership = if (index < param_ownership.len) param_ownership[index] else .owned,
            .span = .{ .start = 0, .end = 0 },
        });
    }
    return params.toOwnedSlice();
}

pub fn hasFfiAnnotation(annotations: []const syntax.ast.Annotation) bool {
    for (annotations) |annotation| {
        if (annotation.name.segments.len >= 2 and std.mem.eql(u8, annotation.name.segments[0].text, "FFI")) {
            return true;
        }
    }
    return false;
}

pub fn ownedEnumSlice(
    allocator: std.mem.Allocator,
    concrete_enums: *const std.StringHashMapUnmanaged(model.EnumDecl),
) ![]model.EnumDecl {
    const owned = try allocator.alloc(model.EnumDecl, concrete_enums.count());
    var iterator = concrete_enums.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        owned[index] = entry.value_ptr.*;
    }
    return owned;
}

pub fn validatePrintableTypes(
    ctx: *shared.Context,
    type_headers: *const std.StringHashMapUnmanaged(shared.TypeHeader),
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    var iterator = type_headers.iterator();
    while (iterator.next()) |entry| {
        if (!entry.value_ptr.is_printable) continue;
        const method_key = try std.fmt.allocPrint(ctx.allocator, "{s}.onPrint", .{entry.key_ptr.*});
        const header = function_headers.get(method_key);
        if (header == null or header.?.return_type.kind != .string) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM102",
                .title = "missing onPrint for @Printable type",
                .message = try std.fmt.allocPrint(ctx.allocator, "The @Printable type '{s}' must declare `function onPrint() -> String`.", .{entry.key_ptr.*}),
                .labels = &.{diagnostics.primaryLabel(entry.value_ptr.span, "@Printable type is missing a compatible onPrint method")},
                .help = "Add `function onPrint() -> String` to the type, or remove @Printable.",
            });
            return error.DiagnosticsEmitted;
        }
    }
}
