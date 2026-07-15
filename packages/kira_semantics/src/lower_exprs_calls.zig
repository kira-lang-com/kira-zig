const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const function_types = @import("function_types.zig");
const comptime_eval = @import("lower_exprs_comptime.zig");
const async_spine = @import("lower_exprs_async.zig");
const parent = @import("lower_exprs.zig");
const lowerExpr = parent.lowerExpr;
const lowerExpectedValue = parent.lowerExpectedValue;
const lowerImplicitSelfFieldExpr = parent.lowerImplicitSelfFieldExpr;
const lowerImplicitSelfMethodCall = parent.lowerImplicitSelfMethodCall;
const lowerParentQualifiedFieldExpr = parent.lowerParentQualifiedFieldExpr;
const lowerParentQualifiedMethodCall = parent.lowerParentQualifiedMethodCall;
const resolveFieldType = parent.resolveFieldType;
const resolveFieldContainerType = parent.resolveFieldContainerType;
const resolveMethodMember = parent.resolveMethodMember;
const resolveMethodMemberOrNull = parent.resolveMethodMemberOrNull;
const buildDispatchedMethodCallExpr = parent.buildDispatchedMethodCallExpr;
const functionTypeFromHeader = parent.functionTypeFromHeader;
const lowerCallArgument = parent.lowerCallArgument;
const trailingCallbackType = parent.trailingCallbackType;
const lowerTrailingCallbackValue = parent.lowerTrailingCallbackValue;
const lowerBuilderBlock = parent.lowerBuilderBlock;
const isCallableValueExpr = parent.isCallableValueExpr;
const flattenCalleeName = parent.flattenCalleeName;
const flattenMemberExpr = parent.flattenMemberExpr;
const qualifiedLeaf = parent.qualifiedLeaf;
const lowerComptimeCall = comptime_eval.lowerComptimeCall;

/// Lowers the built-in String inspection methods (`charAt`, `substring`,
/// `indexOf`) when `method` names one, returning null so ordinary method
/// resolution can proceed for any other name. `object` is the already-lowered
/// String receiver. Follows the array `.append` method precedent: recognized
/// structurally, not via a user-visible declaration. UTF-8 semantics are
/// byte-oriented in v1 (a code unit, not a codepoint). Out-of-range `charAt`
/// / `substring` trap on the VM (consistent with array indexing).
pub fn lowerStringMethodOrNull(
    ctx: *shared.Context,
    object: *model.Expr,
    method: []const u8,
    node: syntax.ast.CallExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) anyerror!?model.Expr {
    const is_char_at = std.mem.eql(u8, method, "charAt");
    const is_substring = std.mem.eql(u8, method, "substring");
    const is_index_of = std.mem.eql(u8, method, "indexOf");
    if (!is_char_at and !is_substring and !is_index_of) return null;

    const expected_args: usize = if (is_substring) 2 else 1;
    if (node.args.len != expected_args or (node.args.len > 0 and node.args[0].label != null) or
        (node.args.len > 1 and node.args[1].label != null))
    {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM042",
            .title = "wrong number of arguments",
            .message = try std.fmt.allocPrint(ctx.allocator, "String method '{s}' expects {d} positional argument(s).", .{ method, expected_args }),
            .labels = &.{diagnostics.primaryLabel(node.span, "string method call has the wrong arguments")},
            .help = "Call `s.charAt(i)`, `s.substring(start, end)`, or `s.indexOf(needle)`.",
        });
        return error.DiagnosticsEmitted;
    }

    if (is_char_at or is_substring) {
        const index_expr = try lowerExpr(ctx, node.args[0].value, imports, scope, function_headers);
        if (model.hir.exprType(index_expr.*).kind != .integer) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM042",
                .title = "invalid string method argument",
                .message = try std.fmt.allocPrint(ctx.allocator, "String method '{s}' expects an `Int` offset.", .{method}),
                .labels = &.{diagnostics.primaryLabel(node.span, "argument is not an Int")},
                .help = "Pass an Int byte offset.",
            });
            return error.DiagnosticsEmitted;
        }
        if (is_char_at) {
            return model.Expr{ .string_char_at = .{ .object = object, .index = index_expr, .span = node.span } };
        }
        const end_expr = try lowerExpr(ctx, node.args[1].value, imports, scope, function_headers);
        if (model.hir.exprType(end_expr.*).kind != .integer) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM042",
                .title = "invalid string method argument",
                .message = "String method 'substring' expects two `Int` offsets.",
                .labels = &.{diagnostics.primaryLabel(node.span, "end offset is not an Int")},
                .help = "Pass Int start and end byte offsets.",
            });
            return error.DiagnosticsEmitted;
        }
        return model.Expr{ .string_substring = .{ .object = object, .start = index_expr, .end = end_expr, .span = node.span } };
    }

    // indexOf(needle: String)
    const needle_expr = try lowerExpr(ctx, node.args[0].value, imports, scope, function_headers);
    if (model.hir.exprType(needle_expr.*).kind != .string) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM042",
            .title = "invalid string method argument",
            .message = "String method 'indexOf' expects a `String` needle.",
            .labels = &.{diagnostics.primaryLabel(node.span, "argument is not a String")},
            .help = "Pass the String to search for.",
        });
        return error.DiagnosticsEmitted;
    }
    return model.Expr{ .string_index_of = .{ .object = object, .needle = needle_expr, .span = node.span } };
}

/// A lowered value that *aliases* existing owned storage rather than producing a fresh
/// owned value: a bare local read (unless explicitly `move`d), a field read, or an element
/// read. Fresh values (array/struct/enum literals, calls, conditionals) own what they yield.
pub fn isAliasingAggregateRead(value: model.Expr) bool {
    return switch (value) {
        .local => |node| node.ownership != .move,
        .field, .index => true,
        else => false,
    };
}

/// Reject initializing an array-typed struct field from an aliasing array read.
///
/// Kira has no deep copy for arrays (KSEM116) and the backend cannot transfer ownership of
/// an array *field* out of a struct, so `Foo { items: other.items }` / `Foo { items: local }`
/// would make the new struct share the source's backing store. When the source is then
/// dropped (e.g. a by-value parameter at function exit), the field dangles — the latent
/// use-after-free behind the widget-lowering `enum native copy could not resolve discriminant`
/// crash. Until ownership transfer/copy of array fields is implemented, this is rejected at
/// `check` instead of detonating at runtime under allocation churn.
pub fn rejectAliasedArrayField(
    ctx: *shared.Context,
    field_ty: model.ResolvedType,
    field_value: *const model.Expr,
    span: source_pkg.Span,
) !void {
    if (field_ty.kind != .array) return;
    if (!isAliasingAggregateRead(field_value.*)) return;
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM118",
        .title = "array field aliases an existing array",
        .message = "Initializing an array-typed field from an existing array value shares its backing store. Kira cannot yet copy or transfer ownership of an array field, so the field would dangle when the source is freed.",
        .labels = &.{diagnostics.primaryLabel(span, "this array field aliases an existing array")},
        .help = "Build the array fresh in place (an array literal, or a call that returns a new array), or `move` an owned local array into the field.",
    });
    return error.DiagnosticsEmitted;
}

pub fn lowerStructLiteralExpr(
    ctx: *shared.Context,
    node: syntax.ast.StructLiteralExpr,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !model.Expr {
    const callee_name = try shared.qualifiedNameText(ctx.allocator, node.type_name);
    const callee_leaf = node.type_name.segments[node.type_name.segments.len - 1].text;
    return lowerTypeConstruction(ctx, callee_name, callee_leaf, null, node.fields, node.span, imports, scope, function_headers);
}

pub fn lowerTypeConstruction(
    ctx: *shared.Context,
    callee_name: []const u8,
    callee_leaf: []const u8,
    call_args: ?[]const syntax.ast.CallArg,
    literal_fields: []const syntax.ast.StructLiteralField,
    span: source_pkg.Span,
    imports: []const model.Import,
    scope: *model.Scope,
    function_headers: ?*const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !model.Expr {
    const type_header = if (ctx.type_headers) |headers| headers.get(callee_name) orelse headers.get(callee_leaf) else null;
    const imported_type = ctx.imported_globals.findType(callee_name) orelse ctx.imported_globals.findType(callee_leaf);
    // Imports are file-scoped: constructing a dependency package's type (struct,
    // class, or construct-backed form) requires this FILE to import its module —
    // a sibling file's import must not leak here.
    if (type_header != null or imported_type != null) {
        if (ctx.missingImportForSymbol(callee_leaf)) |module| {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM078",
                .title = "unknown type in struct literal",
                .message = try std.fmt.allocPrint(ctx.allocator, "'{s}' is defined in module '{s}', which this file does not import.", .{ callee_leaf, module }),
                .labels = &.{diagnostics.primaryLabel(span, "type is not visible in this file")},
                .help = try std.fmt.allocPrint(ctx.allocator, "Add `import {s}` to this file (imports are per-file).", .{module}),
            });
            return error.DiagnosticsEmitted;
        }
    }
    if (type_header == null and imported_type == null) {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM078",
            .title = "unknown type in struct literal",
            .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not find a type named '{s}'.", .{callee_name}),
            .labels = &.{diagnostics.primaryLabel(span, "unknown type")},
            .help = "Declare the type first or import the module that provides it.",
        });
        return error.DiagnosticsEmitted;
    }

    const field_count: usize = if (type_header) |header| header.fields.len else imported_type.?.fields.len;
    const is_ffi_struct = if (type_header) |header|
        header.ffi != null and header.ffi.? == .ffi_struct
    else
        imported_type.?.ffi != null and imported_type.?.ffi.? == .ffi_struct;
    var filled = try ctx.allocator.alloc(bool, field_count);
    @memset(filled, false);
    var fields = std.array_list.Managed(model.ConstructFieldInit).init(ctx.allocator);
    var required_missing = false;

    if (call_args) |items| {
        var next_index: usize = 0;
        for (items) |arg| {
            const field_index = if (arg.label) |label|
                resolveTypeConstructionFieldIndex(ctx, callee_name, callee_leaf, type_header, imported_type, label, arg.span) orelse return error.DiagnosticsEmitted
            else blk: {
                if (next_index >= field_count) {
                    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM079",
                        .title = "too many constructor arguments",
                        .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' declares only {d} field(s).", .{ callee_leaf, field_count }),
                        .labels = &.{diagnostics.primaryLabel(arg.span, "extra constructor argument")},
                        .help = "Remove the extra argument or add a field to the type.",
                    });
                    return error.DiagnosticsEmitted;
                }
                while (next_index < field_count and filled[next_index]) next_index += 1;
                if (next_index >= field_count) {
                    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM079",
                        .title = "too many constructor arguments",
                        .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' declares only {d} field(s).", .{ callee_leaf, field_count }),
                        .labels = &.{diagnostics.primaryLabel(arg.span, "extra constructor argument")},
                        .help = "Remove the extra argument or add a field to the type.",
                    });
                    return error.DiagnosticsEmitted;
                }
                break :blk next_index;
            };
            if (filled[field_index]) {
                const duplicate_name = if (type_header) |header| header.fields[field_index].name else imported_type.?.fields[field_index].name;
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM080",
                    .title = "duplicate struct field",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The field '{s}' is initialized more than once.", .{duplicate_name}),
                    .labels = &.{diagnostics.primaryLabel(arg.span, "duplicate field initializer")},
                    .help = "Initialize each field at most once.",
                });
                return error.DiagnosticsEmitted;
            }
            const field_ty = if (type_header) |header| header.fields[field_index].ty else imported_type.?.fields[field_index].ty;
            const field_value = if (function_headers) |headers|
                try lowerExpectedValue(ctx, arg.value, field_ty, imports, scope, headers, arg.span)
            else
                try lowerExpr(ctx, arg.value, imports, scope, function_headers);
            try rejectAliasedArrayField(ctx, field_ty, field_value, arg.span);
            shared.markAnyFieldMovedIntoOwned(ctx, scope, field_value, arg.span);
            const field_name = if (type_header) |header| header.fields[field_index].name else imported_type.?.fields[field_index].name;
            try fields.append(.{
                .field_name = try ctx.allocator.dupe(u8, field_name),
                .field_index = @as(u32, @intCast(field_index)),
                .value = field_value,
                .span = arg.span,
            });
            filled[field_index] = true;
        }
    } else {
        for (literal_fields) |field| {
            const field_index = resolveTypeConstructionFieldIndex(ctx, callee_name, callee_leaf, type_header, imported_type, field.name, field.span) orelse return error.DiagnosticsEmitted;
            if (filled[field_index]) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM080",
                    .title = "duplicate struct field",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The field '{s}' is initialized more than once.", .{field.name}),
                    .labels = &.{diagnostics.primaryLabel(field.span, "duplicate field initializer")},
                    .help = "Initialize each field at most once.",
                });
                return error.DiagnosticsEmitted;
            }
            const field_ty = if (type_header) |header| header.fields[field_index].ty else imported_type.?.fields[field_index].ty;
            const field_value = if (function_headers) |headers|
                try lowerExpectedValue(ctx, field.value, field_ty, imports, scope, headers, field.span)
            else
                try lowerExpr(ctx, field.value, imports, scope, function_headers);
            try rejectAliasedArrayField(ctx, field_ty, field_value, field.span);
            shared.markAnyFieldMovedIntoOwned(ctx, scope, field_value, field.span);
            try fields.append(.{
                .field_name = try ctx.allocator.dupe(u8, field.name),
                .field_index = @as(u32, @intCast(field_index)),
                .value = field_value,
                .span = field.span,
            });
            filled[field_index] = true;
        }
    }

    for (0..field_count) |index| {
        if (filled[index]) continue;
        if (is_ffi_struct) continue;
        if (type_header) |header| {
            if (isTypeConstantField(header.fields[index].ty, header.fields[index].storage, callee_leaf)) {
                continue;
            }
            if (header.fields[index].default_value) |default_value| {
                try fields.append(.{
                    .field_name = try ctx.allocator.dupe(u8, header.fields[index].name),
                    .field_index = @as(u32, @intCast(index)),
                    .value = default_value,
                    .span = span,
                });
                filled[index] = true;
                continue;
            }
        } else if (imported_type.?.fields[index].default_value) |default_value| {
            try fields.append(.{
                .field_name = try ctx.allocator.dupe(u8, imported_type.?.fields[index].name),
                .field_index = @as(u32, @intCast(index)),
                .value = default_value,
                .span = span,
            });
            filled[index] = true;
            continue;
        }
        required_missing = true;
        const field_name = if (type_header) |header| header.fields[index].name else imported_type.?.fields[index].name;
        // Construct 2.0 (item 2): a construct/form field marked `@Required` that is satisfied by
        // neither a constructor argument nor a `let field = value` override block is reported with
        // the construct-flavored KSEM161; a plain struct field keeps KSEM081.
        const is_required_member = if (type_header) |header| fieldHasRequiredAnnotation(header.fields[index]) else false;
        if (is_required_member) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM161",
                .title = "missing @Required field",
                .message = try std.fmt.allocPrint(ctx.allocator, "Constructing '{s}' does not provide its `@Required` field '{s}'.", .{ callee_leaf, field_name }),
                .labels = &.{diagnostics.primaryLabel(span, "required field is not provided")},
                .help = try std.fmt.allocPrint(ctx.allocator, "Pass '{s}' as a constructor argument `{s}({s} = ...)` or an override block `{s} {{ let {s} = ... }}`.", .{ field_name, callee_leaf, field_name, callee_leaf, field_name }),
            });
            break;
        }
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM081",
            .title = "missing required struct field",
            .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' requires a value for field '{s}'.", .{ callee_leaf, field_name }),
            .labels = &.{diagnostics.primaryLabel(span, "required field is missing")},
            .help = "Initialize the missing field or add a default value on the type declaration.",
        });
        break;
    }
    if (required_missing) return error.DiagnosticsEmitted;

    return .{ .construct = .{
        .type_name = try ctx.allocator.dupe(u8, callee_leaf),
        .fields = try fields.toOwnedSlice(),
        .fill_mode = if (is_ffi_struct) .zeroed_ffi_c_layout else .defaults,
        .ty = .{ .kind = .named, .name = try ctx.allocator.dupe(u8, callee_leaf) },
        .span = span,
    } };
}

pub fn fieldHasRequiredAnnotation(field: model.Field) bool {
    for (field.annotations) |annotation| {
        if (std.mem.eql(u8, annotation.name, "Required")) return true;
    }
    return false;
}

pub fn isTypeConstantField(field_ty: model.ResolvedType, storage: model.FieldStorage, owner_type_name: []const u8) bool {
    return storage == .immutable and field_ty.kind == .named and field_ty.name != null and std.mem.eql(u8, field_ty.name.?, owner_type_name);
}

pub fn resolveTypeConstructionFieldIndex(
    ctx: *shared.Context,
    callee_name: []const u8,
    callee_leaf: []const u8,
    type_header: ?shared.TypeHeader,
    imported_type: ?@import("imported_globals.zig").ImportedType,
    field_name: []const u8,
    span: source_pkg.Span,
) ?usize {
    if (type_header) |header| {
        for (header.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, field_name)) return index;
        }
    } else if (imported_type) |type_decl| {
        for (type_decl.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, field_name)) return index;
        }
    }
    diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM082",
        .title = "unknown struct field",
        .message = std.fmt.allocPrint(ctx.allocator, "The type '{s}' does not declare a field named '{s}'.", .{ callee_leaf, field_name }) catch return null,
        .labels = &.{diagnostics.primaryLabel(span, "unknown field")},
        .help = "Use a declared field name or update the type definition.",
    }) catch return null;
    _ = callee_name;
    return null;
}

// Build the field arguments for a declaration construction `Foo(...) { ... }` whose `@Content`
// fields are filled by the trailing block. Returns null when `Foo` has no content fields or no
// trailing block (ordinary construction). Explicit `(...)` args are preserved, then each content
// field is filled: a `[Widget]` field from all block items as an array literal, a single `Widget`
// field from one item, and multiple fields from named fills (`header { ... }`). Arity/type are
// already validated by the widget-content pass.
pub fn buildContentArgs(
    ctx: *shared.Context,
    callee_name: []const u8,
    callee_leaf: []const u8,
    node: syntax.ast.CallExpr,
) !?[]syntax.ast.CallArg {
    const content_fields: ?[]const shared.ContentFieldRef = if (ctx.form_content_fields) |map|
        map.get(callee_leaf)
    else
        null;

    // Construct 2.0 HARD RULE: a child slot (`@Content` or `some X` / `[some X]` slot-by-type)
    // is filled by the trailing content block, never by a constructor parens argument. A labeled
    // argument that names a slot field is rejected (KSEM162), even without a trailing block.
    if (content_fields) |fields| {
        for (node.args) |arg| {
            const label = arg.label orelse continue;
            if (findContentField(fields, label)) |field| {
                try emitSlotViaArg(ctx, callee_leaf, field.name, arg.span);
                return error.DiagnosticsEmitted;
            }
        }
    }

    const builder = node.trailing_builder orelse return null;

    var args = std.array_list.Managed(syntax.ast.CallArg).init(ctx.allocator);
    try args.appendSlice(node.args);

    // Partition the trailing block: `let field = value` override members become labeled field
    // arguments (Construct 2.0 items 1/5), while bare children fill the `some X` / `[some X]` slot.
    var child_items = std.array_list.Managed(syntax.ast.BuilderItem).init(ctx.allocator);
    var saw_override = false;
    for (builder.items) |item| {
        if (item == .field_override) {
            saw_override = true;
            const override = item.field_override;
            // A slot field is filled by children, never by an override member (KSEM162).
            if (content_fields) |fields| {
                if (findContentField(fields, override.name)) |field| {
                    try emitSlotViaArg(ctx, callee_leaf, field.name, override.span);
                    return error.DiagnosticsEmitted;
                }
            }
            // The override must name a real field of the constructed type (KSEM163).
            if (!typeHasField(ctx, callee_name, callee_leaf, override.name)) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM163",
                    .title = "unknown override field",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The type '{s}' does not declare a field named '{s}' for a `let {s} = ...` override.", .{ callee_leaf, override.name, override.name }),
                    .labels = &.{diagnostics.primaryLabel(override.span, "unknown override field")},
                    .help = "Use a declared field name, or set a child slot by placing bare children in the block.",
                });
                return error.DiagnosticsEmitted;
            }
            try args.append(.{ .label = override.name, .value = override.value, .span = override.span });
            continue;
        }
        try child_items.append(item);
    }

    if (content_fields) |fields| {
        if (fields.len == 1) {
            if (try contentArg(ctx, fields[0], child_items.items, node.span)) |arg| try args.append(arg);
        } else {
            for (child_items.items) |item| {
                if (item != .expr) continue;
                const value = item.expr.expr;
                if (value.* != .call) continue;
                const fill = value.*.call;
                const name = calleeIdentifierName(fill.callee) orelse continue;
                const field = findContentField(fields, name) orelse continue;
                const inner = fill.trailing_builder orelse continue;
                if (try contentArg(ctx, field, inner.items, fill.span)) |arg| try args.append(arg);
            }
        }
        return try args.toOwnedSlice();
    }

    // No content slot: only override members are meaningful. When the block carried overrides,
    // return the augmented argument list; otherwise leave the construction untouched.
    if (saw_override) return try args.toOwnedSlice();
    return null;
}

pub fn emitSlotViaArg(
    ctx: *shared.Context,
    callee_leaf: []const u8,
    field_name: []const u8,
    span: source_pkg.Span,
) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM162",
        .title = "slot filled by constructor argument",
        .message = try std.fmt.allocPrint(ctx.allocator, "The child slot '{s}' of '{s}' is filled by the trailing content block, not by a constructor argument or override.", .{ field_name, callee_leaf }),
        .labels = &.{diagnostics.primaryLabel(span, "slot fields cannot be filled with a constructor argument or override")},
        .help = try std.fmt.allocPrint(ctx.allocator, "Provide '{s}' as bare children in the trailing `{{ ... }}` block.", .{field_name}),
    });
}

// True when the constructed type declares a field named `name` (local type header or imported
// type). Used to validate `let field = value` override members without emitting the ordinary
// struct-field diagnostic (KSEM082).
pub fn typeHasField(
    ctx: *shared.Context,
    callee_name: []const u8,
    callee_leaf: []const u8,
    name: []const u8,
) bool {
    if (ctx.type_headers) |headers| {
        if (headers.get(callee_name) orelse headers.get(callee_leaf)) |header| {
            for (header.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) return true;
            }
            return false;
        }
    }
    if (ctx.imported_globals.findType(callee_name) orelse ctx.imported_globals.findType(callee_leaf)) |type_decl| {
        for (type_decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return true;
        }
    }
    return false;
}

pub fn contentArg(
    ctx: *shared.Context,
    field: shared.ContentFieldRef,
    items: []const syntax.ast.BuilderItem,
    span: source_pkg.Span,
) !?syntax.ast.CallArg {
    if (field.is_list) {
        var all_expr_items = true;
        var elements = std.array_list.Managed(*syntax.ast.Expr).init(ctx.allocator);
        for (items) |item| {
            if (item == .expr) {
                // Preserve full modifier chains inside content-array fields so a widget list
                // sees the same runtime values the author wrote, including chained `extend`
                // modifiers such as `.padding(..)` / `.background(..)`.
                try elements.append(item.expr.expr);
                continue;
            }
            all_expr_items = false;
        }
        const array_expr = try ctx.allocator.create(syntax.ast.Expr);
        if (all_expr_items) {
            array_expr.* = .{ .array = .{ .elements = try elements.toOwnedSlice(), .span = span } };
        } else {
            array_expr.* = .{ .builder_array = .{ .builder = .{ .items = try ctx.allocator.dupe(syntax.ast.BuilderItem, items), .span = span }, .span = span } };
        }
        return .{ .label = field.name, .value = array_expr, .span = span };
    }
    for (items) |item| {
        if (item == .expr) return .{ .label = field.name, .value = item.expr.expr, .span = span };
    }
    return null;
}

pub fn calleeIdentifierName(callee: *const syntax.ast.Expr) ?[]const u8 {
    return switch (callee.*) {
        .identifier => |ident| if (ident.name.segments.len == 1) ident.name.segments[0].text else null,
        else => null,
    };
}

pub fn findContentField(fields: []const shared.ContentFieldRef, name: []const u8) ?shared.ContentFieldRef {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

pub fn localOrImportedTypeFieldCount(
    ctx: *shared.Context,
    callee_name: []const u8,
    callee_leaf: []const u8,
) ?usize {
    if (ctx.type_headers) |headers| {
        if (headers.get(callee_name)) |header| return header.fields.len;
        if (headers.get(callee_leaf)) |header| return header.fields.len;
    }
    if (ctx.imported_globals.findType(callee_name)) |type_decl| return type_decl.fields.len;
    if (ctx.imported_globals.findType(callee_leaf)) |type_decl| return type_decl.fields.len;
    return null;
}

pub fn requiredExplicitArgCount(param_defaults: []const ?*syntax.ast.Expr, explicit_param_count: usize) usize {
    var required = explicit_param_count;
    while (required > 0) {
        const default_index = required - 1;
        if (default_index >= param_defaults.len) break;
        if (param_defaults[default_index] == null) break;
        required -= 1;
    }
    return required;
}
