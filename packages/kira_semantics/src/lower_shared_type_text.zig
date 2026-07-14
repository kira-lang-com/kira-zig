const std = @import("std");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const function_types = @import("function_types.zig");
const shared = @import("lower_shared.zig");
const Context = shared.Context;
const resolveTypeAlias = shared.resolveTypeAlias;
const stripOwnershipType = shared.stripOwnershipType;
const ownershipModeFromSyntax = shared.ownershipModeFromSyntax;

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

/// Maps a primitive numeric type name used as a cast call target — `Int(x)`,
/// `Float(x)`, and every width-specific form (`U64(x)`, `I32(x)`, `F32(x)`, …) —
/// to its resolved target type, or null when `name` is not a numeric cast.
///
/// Width is carried in `.name`; the runtime representation of every integer
/// (and of every float) is identical, so a same-kind cast lowers to the
/// existing int↔float `convert` instruction as an identity copy — no new
/// opcode or backend support is required. This is the single source of truth
/// for which names are numeric casts, so the full set stays consistent with the
/// width types `typeFromSyntax` accepts below.
pub fn numericCastTargetType(name: []const u8) ?model.ResolvedType {
    if (std.mem.eql(u8, name, "Int")) return .{ .kind = .integer };
    if (std.mem.eql(u8, name, "Float")) return .{ .kind = .float };
    const integer_names = [_][]const u8{ "I8", "U8", "I16", "U16", "I32", "U32", "I64", "U64" };
    for (integer_names) |integer_name| {
        if (std.mem.eql(u8, name, integer_name)) return .{ .kind = .integer, .name = name };
    }
    if (std.mem.eql(u8, name, "F32") or std.mem.eql(u8, name, "F64")) {
        return .{ .kind = .float, .name = name };
    }
    return null;
}

pub fn typeFromSyntax(ctx: *const Context, ty: syntax.ast.TypeExpr) anyerror!model.ResolvedType {
    return switch (ty) {
        .array => |info| .{ .kind = .array, .name = try typeTextFromSyntax(ctx, info.element_type.*) },
        .function => |info| .{ .kind = .callback, .name = try functionTypeTextFromSyntax(ctx, info) },
        .ownership => |info| try typeFromSyntax(ctx, info.target.*),
        .any => |info| switch (info.target.*) {
            .named => |name| .{
                .kind = .construct_any,
                .name = try typeTextFromSyntax(ctx, .{ .any = info }),
                .construct_constraint = .{ .construct_name = try ctx.allocator.dupe(u8, name.segments[name.segments.len - 1].text) },
            },
            else => .{ .kind = .construct_any, .name = try typeTextFromSyntax(ctx, .{ .any = info }) },
        },
        .named => |name| blk: {
            const leaf = name.segments[name.segments.len - 1].text;
            if (try resolveTypeAlias(ctx, leaf)) |alias_type| break :blk alias_type;
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
            if (ctx.enum_headers) |headers| {
                if (headers.get(leaf)) |enum_decl| {
                    if (enum_decl.type_params.len == 0) break :blk .{ .kind = .enum_instance, .name = leaf };
                }
            }
            if (ctx.construct_headers) |headers| {
                if (headers.get(leaf) != null) {
                    break :blk .{
                        .kind = .construct_any,
                        .name = try std.fmt.allocPrint(ctx.allocator, "any {s}", .{leaf}),
                        .construct_constraint = .{ .construct_name = try ctx.allocator.dupe(u8, leaf) },
                    };
                }
            }
            break :blk .{ .kind = .named, .name = leaf };
        },
        .generic => |info| .{
            .kind = .enum_instance,
            .name = try genericTypeTextFromSyntax(ctx, info),
        },
    };
}

pub fn typeTextFromSyntax(ctx: *const Context, ty: syntax.ast.TypeExpr) anyerror![]const u8 {
    return switch (ty) {
        .array => |info| std.fmt.allocPrint(ctx.allocator, "[{s}]", .{try typeTextFromSyntax(ctx, info.element_type.*)}),
        .function => |info| functionTypeTextFromSyntax(ctx, info),
        .ownership => |info| switch (info.mode) {
            .borrow_read => std.fmt.allocPrint(ctx.allocator, "borrow {s}", .{try typeTextFromSyntax(ctx, info.target.*)}),
            .borrow_mut => std.fmt.allocPrint(ctx.allocator, "borrow mut {s}", .{try typeTextFromSyntax(ctx, info.target.*)}),
            .move => std.fmt.allocPrint(ctx.allocator, "move {s}", .{try typeTextFromSyntax(ctx, info.target.*)}),
            .copy => std.fmt.allocPrint(ctx.allocator, "copy {s}", .{try typeTextFromSyntax(ctx, info.target.*)}),
            .owned => typeTextFromSyntax(ctx, info.target.*),
        },
        // Keyword-independent by design: `some Target` and `any Target` are the same existential
        // `construct_any` today, and this text feeds resolved type NAMES used for coercion/dispatch
        // matching. The surface keyword is surfaced only in display paths (ast_dump, diagnostics).
        .any => |info| std.fmt.allocPrint(ctx.allocator, "any {s}", .{try typeTextFromSyntax(ctx, info.target.*)}),
        .named => |name| blk: {
            const leaf = name.segments[name.segments.len - 1].text;
            if (try resolveTypeAlias(ctx, leaf)) |alias_type| break :blk typeTextFromResolved(ctx.allocator, alias_type);
            break :blk ctx.allocator.dupe(u8, leaf);
        },
        .generic => |info| genericTypeTextFromSyntax(ctx, info),
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
        .construct_any => if (ty.name) |name| allocator.dupe(u8, name) else std.fmt.allocPrint(allocator, "any {s}", .{(ty.construct_constraint orelse return allocator.dupe(u8, "any Unknown")).construct_name}),
        .native_state => std.fmt.allocPrint(allocator, "NativeState<{s}>", .{ty.name orelse "Unknown"}),
        .native_state_view => std.fmt.allocPrint(allocator, "NativeStateView<{s}>", .{ty.name orelse "Unknown"}),
        .callback, .ffi_struct, .named, .enum_instance => allocator.dupe(u8, ty.name orelse "Unknown"),
        .array => std.fmt.allocPrint(allocator, "[{s}]", .{ty.name orelse ""}),
        .unknown => allocator.dupe(u8, "Unknown"),
    };
}

pub fn resolvedTypeFromText(text: []const u8) !model.ResolvedType {
    if (std.mem.startsWith(u8, text, "any ")) {
        return .{
            .kind = .construct_any,
            .name = text,
            .construct_constraint = .{ .construct_name = text[4..] },
        };
    }
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

fn functionTypeTextFromSyntax(ctx: *const Context, info: syntax.ast.FunctionTypeExpr) anyerror![]const u8 {
    var params = std.array_list.Managed(model.ResolvedType).init(ctx.allocator);
    var param_ownership = std.array_list.Managed(model.OwnershipMode).init(ctx.allocator);
    for (info.params) |param| {
        try params.append(try typeFromSyntax(ctx, stripOwnershipType(param.*)));
        try param_ownership.append(ownershipModeFromSyntax(param));
    }
    return function_types.signatureText(
        ctx.allocator,
        params.items,
        param_ownership.items,
        try typeFromSyntax(ctx, stripOwnershipType(info.result.*)),
    );
}

fn genericTypeTextFromSyntax(ctx: *const Context, info: syntax.ast.GenericTypeExpr) ![]const u8 {
    const base_name = info.base.segments[info.base.segments.len - 1].text;
    var text = std.array_list.Managed(u8).init(ctx.allocator);
    try text.appendSlice(base_name);
    for (info.args) |arg| {
        try text.appendSlice("__");
        const arg_text = try typeTextFromSyntax(ctx, arg.*);
        for (arg_text) |byte| {
            if (std.ascii.isAlphanumeric(byte)) {
                try text.append(byte);
            } else {
                try text.append('_');
            }
        }
    }
    return text.toOwnedSlice();
}
