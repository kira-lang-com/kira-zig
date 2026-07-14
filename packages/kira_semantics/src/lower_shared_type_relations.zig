const std = @import("std");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const Context = shared.Context;
const TypeHeader = shared.TypeHeader;

pub fn namedTypeInfo(ctx: *const Context, ty: model.ResolvedType) ?model.NamedTypeInfo {
    if (ty.kind != .named or ty.name == null) return null;
    if (ctx.type_headers) |headers| {
        if (headers.get(ty.name.?)) |header| return header.ffi;
    }
    if (ctx.imported_globals.findType(ty.name.?)) |type_decl| return type_decl.ffi;
    return null;
}

pub fn namedTypeHeader(ctx: *const Context, ty: model.ResolvedType) ?TypeHeader {
    if (ty.kind != .named or ty.name == null) return null;
    if (ctx.type_headers) |headers| {
        if (headers.get(ty.name.?)) |header| return header;
    }
    return null;
}

pub fn namedTypeKind(ctx: *const Context, ty: model.ResolvedType) ?model.TypeKind {
    if (ty.kind != .named or ty.name == null) return null;
    if (ctx.type_headers) |headers| {
        if (headers.get(ty.name.?)) |header| return header.kind;
    }
    if (ctx.imported_globals.findType(ty.name.?)) |type_decl| return type_decl.kind;
    return null;
}

pub fn isClassType(ctx: *const Context, ty: model.ResolvedType) bool {
    return namedTypeKind(ctx, ty) == .class;
}

pub fn hasKnownSubclass(ctx: *const Context, type_name: []const u8) bool {
    if (ctx.type_headers) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.kind != .class) continue;
            if (std.mem.eql(u8, entry.key_ptr.*, type_name)) continue;
            for (entry.value_ptr.parent_views) |parent_view| {
                if (std.mem.eql(u8, parent_view.type_name, type_name)) return true;
            }
        }
    }
    for (ctx.imported_globals.types) |type_decl| {
        if (type_decl.kind != .class) continue;
        if (std.mem.eql(u8, type_decl.name, type_name)) continue;
        if (classNameMatchesOrInherits(ctx, type_decl.name, type_name)) return true;
    }
    return false;
}

pub fn isAssignableClassValue(ctx: *const Context, target: model.ResolvedType, actual: model.ResolvedType) bool {
    if (target.kind != .named or actual.kind != .named) return false;
    if (!isClassType(ctx, target) or !isClassType(ctx, actual)) return false;
    const target_name = target.name orelse return false;
    const actual_name = actual.name orelse return false;
    return classNameMatchesOrInherits(ctx, actual_name, target_name);
}

// The least common `any Family` of two construct-backed declaration values (or of an `any Family`
// and a declaration), so a heterogeneous widget array literal (`[Text(...), Spacer()]`) unifies to
// `[any Widget]`. Returns null when the values share no construct family.
pub fn commonConstructAnyType(
    allocator: std.mem.Allocator,
    ctx: *const Context,
    lhs: model.ResolvedType,
    rhs: model.ResolvedType,
) ?model.ResolvedType {
    const lhs_families = familyList(allocator, ctx, lhs) orelse return null;
    const rhs_families = familyList(allocator, ctx, rhs) orelse return null;
    for (lhs_families) |candidate| {
        for (rhs_families) |other| {
            if (std.mem.eql(u8, candidate, other)) return constructAnyType(allocator, candidate) catch null;
        }
    }
    return null;
}

// The construct families a value satisfies: a concrete declaration's recorded families, or the
// single constraint of an `any Family` value.
fn familyList(allocator: std.mem.Allocator, ctx: *const Context, ty: model.ResolvedType) ?[]const []const u8 {
    if (ty.kind == .construct_any) {
        const constraint = (ty.construct_constraint orelse return null).construct_name;
        const single = allocator.alloc([]const u8, 1) catch return null;
        single[0] = constraint;
        return single;
    }
    const name = ty.name orelse return null;
    const families = ctx.form_families orelse return null;
    return families.get(name);
}

fn constructAnyType(allocator: std.mem.Allocator, family: []const u8) !model.ResolvedType {
    return .{
        .kind = .construct_any,
        .name = try std.fmt.allocPrint(allocator, "any {s}", .{family}),
        .construct_constraint = .{ .construct_name = family },
    };
}

pub fn commonClassType(
    ctx: *const Context,
    lhs: model.ResolvedType,
    rhs: model.ResolvedType,
) ?model.ResolvedType {
    if (lhs.kind != .named or rhs.kind != .named) return null;
    if (!isClassType(ctx, lhs) or !isClassType(ctx, rhs)) return null;
    const lhs_name = lhs.name orelse return null;
    const rhs_name = rhs.name orelse return null;

    if (classNameMatchesOrInherits(ctx, rhs_name, lhs_name)) return lhs;
    if (classNameMatchesOrInherits(ctx, lhs_name, rhs_name)) return rhs;

    if (ctx.type_headers) |headers| {
        if (headers.get(lhs_name)) |header| {
            for (header.parent_views) |parent_view| {
                if (classNameMatchesOrInherits(ctx, rhs_name, parent_view.type_name)) {
                    return .{ .kind = .named, .name = parent_view.type_name };
                }
            }
        }
    }

    var current = ctx.imported_globals.findType(lhs_name);
    while (current) |type_decl| {
        for (type_decl.parents) |parent_name| {
            if (classNameMatchesOrInherits(ctx, rhs_name, parent_name)) {
                return .{ .kind = .named, .name = parent_name };
            }
        }
        if (type_decl.parents.len == 0) break;
        current = ctx.imported_globals.findType(type_decl.parents[0]);
    }

    return null;
}

fn classNameMatchesOrInherits(ctx: *const Context, actual_name: []const u8, target_name: []const u8) bool {
    if (std.mem.eql(u8, actual_name, target_name)) return true;
    if (ctx.type_headers) |headers| {
        if (headers.get(actual_name)) |header| {
            if (header.kind != .class) return false;
            for (header.parent_views) |parent_view| {
                if (std.mem.eql(u8, parent_view.type_name, target_name)) return true;
            }
            return false;
        }
    }
    if (ctx.imported_globals.findType(actual_name)) |type_decl| {
        if (type_decl.kind != .class) return false;
        for (type_decl.parents) |parent_name| {
            if (std.mem.eql(u8, parent_name, target_name)) return true;
            if (classNameMatchesOrInherits(ctx, parent_name, target_name)) return true;
        }
    }
    return false;
}

pub fn namedTypeFields(ctx: *const Context, ty: model.ResolvedType) []const model.Field {
    if (namedTypeHeader(ctx, ty)) |header| return header.fields;
    return &.{};
}

pub fn isPointerLike(ctx: *const Context, ty: model.ResolvedType) bool {
    return switch (ty.kind) {
        .raw_ptr, .c_string => true,
        .named => if (namedTypeInfo(ctx, ty)) |info|
            switch (info) {
                .pointer, .callback => true,
                .alias => |value| isPointerLike(ctx, value.target),
                .ffi_struct, .array => false,
            }
        else
            false,
        else => false,
    };
}

pub fn callbackInfo(ctx: *const Context, ty: model.ResolvedType) ?model.CallbackInfo {
    if (ty.kind != .named) return null;
    return if (namedTypeInfo(ctx, ty)) |info|
        switch (info) {
            .callback => |value| value,
            .alias => |value| callbackInfo(ctx, value.target),
            else => null,
        }
    else
        null;
}
