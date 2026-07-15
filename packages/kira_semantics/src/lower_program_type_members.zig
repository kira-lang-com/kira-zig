//! Local type member application (fields, overrides, method uniqueness/override
//! rules) and method-function lowering with the implicit `self` receiver. Split
//! from lower_program_types.zig.
const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const parent = @import("lower_program.zig");
const ResolvedFieldOverride = parent.ResolvedFieldOverride;
const lowerFieldDefaultExprExpected = parent.lowerFieldDefaultExprExpected;
const lowerField = parent.lowerField;
const lowerFunction = parent.lowerFunction;

pub fn applyLocalTypeMembers(
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
                const explicit_type = try shared.typeFromSyntaxChecked(ctx, type_expr.*);
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
            fields.items[match.inherited_offset].default_value = try lowerFieldDefaultExprExpected(ctx, field_decl.value.?, match.field.ty, ctx.function_headers);
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

        if (field_decl.body != null) continue;

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

pub fn emitInvalidFieldOverride(ctx: *shared.Context, span: source_pkg.Span, message: []const u8) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM063",
        .title = "invalid field override",
        .message = message,
        .labels = &.{diagnostics.primaryLabel(span, "field override is not valid in this form")},
        .help = "Use `override let name = value` or `override var name = value` to replace only the inherited default value.",
    });
}

pub fn findSingleInheritedField(
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

pub fn fieldNameExists(fields: []const model.Field, field_name: []const u8) bool {
    for (fields) |field_decl| {
        if (std.mem.eql(u8, field_decl.name, field_name)) return true;
    }
    return false;
}

pub fn methodNameExists(methods: []const shared.MethodMember, method_name: []const u8) bool {
    for (methods) |method_decl| {
        if (std.mem.eql(u8, method_decl.name, method_name)) return true;
    }
    return false;
}

pub fn countMethodsByName(methods: []const shared.MethodMember, method_name: []const u8) usize {
    var count: usize = 0;
    for (methods) |method_decl| {
        if (std.mem.eql(u8, method_decl.name, method_name)) count += 1;
    }
    return count;
}

pub fn countExactMethodMatches(methods: []const shared.MethodMember, candidate: shared.MethodMember) usize {
    var count: usize = 0;
    for (methods) |method_decl| {
        if (!std.mem.eql(u8, method_decl.name, candidate.name)) continue;
        if (sameMethodSignature(method_decl, candidate)) count += 1;
    }
    return count;
}

pub fn hasNonOverridableExactMethod(methods: []const shared.MethodMember, candidate: shared.MethodMember) bool {
    for (methods) |method_decl| {
        if (!std.mem.eql(u8, method_decl.name, candidate.name)) continue;
        if (sameMethodSignature(method_decl, candidate) and !method_decl.overridable) return true;
    }
    return false;
}

pub fn sameMethodSignature(lhs: shared.MethodMember, rhs: shared.MethodMember) bool {
    if (lhs.params.len != rhs.params.len) return false;
    if (!shared.canAssignExactly(lhs.return_type, rhs.return_type)) return false;
    if (lhs.return_ownership != rhs.return_ownership) return false;
    for (lhs.params, rhs.params) |lhs_param, rhs_param| {
        if (!shared.canAssignExactly(lhs_param, rhs_param)) return false;
    }
    // Ownership modes (borrow/owned/move/copy) are part of the exact signature, so an
    // override cannot silently change a parameter's ownership. Members carrying no
    // ownership metadata (imported surfaces may leave the array empty) are not
    // compared, preserving their existing match behavior.
    if (lhs.param_ownership.len == rhs.param_ownership.len) {
        for (lhs.param_ownership, rhs.param_ownership) |lhs_mode, rhs_mode| {
            if (lhs_mode != rhs_mode) return false;
        }
    }
    return true;
}

pub fn makeDeclaredMethodMember(
    ctx: *shared.Context,
    owner_type_name: []const u8,
    function_decl: syntax.ast.FunctionDecl,
) !shared.MethodMember {
    var params = std.array_list.Managed(model.ResolvedType).init(ctx.allocator);
    var param_ownership = std.array_list.Managed(model.OwnershipMode).init(ctx.allocator);
    for (function_decl.params) |param| {
        try param_ownership.append(shared.ownershipModeFromSyntax(param.type_expr));
        if (param.type_expr) |type_expr| {
            try params.append(try shared.typeFromSyntaxChecked(ctx, type_expr.*));
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
        .param_ownership = try param_ownership.toOwnedSlice(),
        .return_type = if (function_decl.return_type) |return_type| try shared.typeFromSyntaxChecked(ctx, return_type.*) else .{ .kind = .unknown },
        .return_ownership = shared.ownershipModeFromSyntax(function_decl.return_type),
        .span = function_decl.span,
    };
}

pub fn registerTypeMethodHeaders(
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
        var param_ownership = std.array_list.Managed(model.OwnershipMode).init(ctx.allocator);
        var param_defaults = std.array_list.Managed(?*syntax.ast.Expr).init(ctx.allocator);
        try param_types.append(.{ .kind = .named, .name = type_decl.name });
        try param_ownership.append(.borrow_read);
        try param_defaults.append(null);
        for (function_decl.params) |param| {
            try param_ownership.append(shared.ownershipModeFromSyntax(param.type_expr));
            try param_defaults.append(param.default_value);
            if (param.type_expr) |type_expr| {
                try param_types.append(try shared.typeFromSyntaxChecked(ctx, type_expr.*));
            } else {
                try param_types.append(.{ .kind = .unknown });
            }
        }
        const method_name = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ type_decl.name, function_decl.name });
        try function_headers.put(ctx.allocator, method_name, .{
            .id = @as(u32, @intCast(function_headers.count())),
            .params = try param_types.toOwnedSlice(),
            .param_ownership = try param_ownership.toOwnedSlice(),
            .param_defaults = try param_defaults.toOwnedSlice(),
            .execution = if (foreign != null and annotation_info.execution == .inherited) .native else annotation_info.execution,
            .return_type = if (function_decl.return_type) |return_type| try shared.typeFromSyntaxChecked(ctx, return_type.*) else .{ .kind = .unknown },
            .return_ownership = shared.ownershipModeFromSyntax(function_decl.return_type),
            .is_extern = foreign != null,
            .foreign = foreign,
            .span = function_decl.span,
        });
    }
}

pub fn lowerTypeMethods(
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

pub fn lowerMethodFunction(
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
    // A consuming method (`@Consuming`, or a `body` accessor, or an
    // implementation of a consuming family method) takes `self` OWNED — the
    // call transfers the receiver, the callee owns and drops the shell, and
    // content fields may partial-move out (`{ content }` in body blocks).
    // Everything else keeps the borrowed receiver.
    const self_param_type_expr = if (shared.methodConsumesSelf(ctx, owner_type_name, function_decl.name, function_decl.annotations))
        self_type_expr
    else blk: {
        const borrowed_self_type_expr = try ctx.allocator.create(syntax.ast.TypeExpr);
        borrowed_self_type_expr.* = .{ .ownership = .{
            .mode = .borrow_read,
            .target = self_type_expr,
            .span = function_decl.span,
        } };
        break :blk borrowed_self_type_expr;
    };

    var params = std.array_list.Managed(syntax.ast.ParamDecl).init(ctx.allocator);
    try params.append(.{
        .annotations = &.{},
        .name = "self",
        .type_expr = self_param_type_expr,
        .span = function_decl.span,
    });
    try params.appendSlice(function_decl.params);

    const lowered = try lowerFunction(ctx, .{
        .annotations = function_decl.annotations,
        // Carry the declaration modifiers through the synthetic decl so a method's
        // override/comptime/async semantics are not silently dropped before lowering.
        // (The member parser currently only produces `override` on methods, but the
        // pass-through keeps this correct if async/comptime methods are ever parsed.)
        .is_override = function_decl.is_override,
        .is_comptime = function_decl.is_comptime,
        .is_async = function_decl.is_async,
        .name = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ owner_type_name, function_decl.name }),
        .params = try params.toOwnedSlice(),
        .return_type = function_decl.return_type,
        .body = function_decl.body,
        .span = function_decl.span,
    }, imports, function_headers);
    return lowered;
}
