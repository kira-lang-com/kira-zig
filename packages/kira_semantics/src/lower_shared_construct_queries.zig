// Construct-surface ownership queries, split out of lower_shared.zig (Core
// Law #5): which family methods CONSUME their receiver (`@Consuming`, `body`
// accessors), and whether a type transitively carries type-erased
// (construct_any) storage — the two predicates every ownership edge for
// existential values keys off (KIR002/KSEM157 gates, partial-move rules,
// owned-self method lowering).
const std = @import("std");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");

const Context = shared.Context;

// A type-erased (some/any) FIELD READ flowing into an OWNED position — a
// construct-literal field, an owned call argument, or an array element being
// built — is a PARTIAL MOVE out of its owner (`{ content }`, `[content]`,
// `f(self.children)` inside a consuming method). Record the move on the root
// binding (KSEM layer) and re-tag the read `.moved` so every backend
// nulls/voids the field slot: the destination owns the value, and the owner's
// shell teardown must not free it again (the editor content-forward
// double-free). Borrowed roots are left untouched — the mid-IR KIR002 gate
// rejects moving Any out of a borrow. No-op for non-field values and
// non-Any-storage types.
pub fn markAnyFieldMovedIntoOwned(ctx: *Context, scope: *model.Scope, value: *model.Expr, span: @import("kira_source").Span) void {
    if (value.* != .field) return;
    const field_node = &value.field;
    if (field_node.ty.kind != .construct_any and !containsConstructAnyStorage(ctx, field_node.ty)) return;
    if (field_node.object.* != .local) return;
    const binding = scope.entries.getPtr(field_node.object.local.name) orelse return;
    if (binding.ownership == .borrow_read or binding.ownership == .borrow_mut) return;
    if (binding.moved) return;
    binding.markFieldMoved(ctx.allocator, field_node.field_name) catch return;
    if (binding.move_span == null) binding.move_span = span;
    field_node.moved = true;
}

// Does `<owner_type_name>.<function_name>` take `self` OWNED (a consuming
// method — Rust `self` receiver)? True when:
//   - the decl itself carries `@Consuming` (family declaration methods), or
//   - the method is named `body` and the owner participates in a construct
//     family (the synthesized body accessor consumes the node it expands), or
//   - a family the owner satisfies declares a `@Consuming` method of this name
//     (implementations inherit the owned receiver so dispatch stays uniform).
// The virtual-call receiver ownership (mid IR) and the callee's owned-param
// teardown both key off the resolved function's param_ownership[0], so this
// decision must be identical at every registration/lowering site.
pub fn methodConsumesSelf(
    ctx: *const Context,
    owner_type_name: []const u8,
    function_name: []const u8,
    annotations: []const syntax.ast.Annotation,
) bool {
    for (annotations) |annotation| {
        if (annotation.name.segments.len == 1 and std.mem.eql(u8, annotation.name.segments[0].text, "Consuming")) return true;
    }
    const in_family_world = blk: {
        if (ctx.form_families) |families| {
            if (families.get(owner_type_name) != null) break :blk true;
        }
        if (ctx.construct_headers) |headers| {
            if (headers.get(owner_type_name) != null) break :blk true;
        }
        break :blk false;
    };
    if (!in_family_world) return false;
    if (std.mem.eql(u8, function_name, "body")) return true;
    const constructs = ctx.constructs orelse return false;
    // Owner is itself a family: consult its surface (and ancestors via parents).
    if (constructFamilyConsumes(constructs, owner_type_name, function_name, 0)) return true;
    // Owner is a concrete form: consult every family it satisfies.
    if (ctx.form_families) |families| {
        if (families.get(owner_type_name)) |names| {
            for (names) |family_name| {
                if (constructFamilyConsumes(constructs, family_name, function_name, 0)) return true;
            }
        }
    }
    return false;
}

fn constructFamilyConsumes(constructs: []const model.Construct, family_name: []const u8, function_name: []const u8, depth: u32) bool {
    if (depth > 16) return false;
    for (constructs) |construct_decl| {
        if (!std.mem.eql(u8, construct_decl.name, family_name)) continue;
        for (construct_decl.consuming_functions) |name| {
            if (std.mem.eql(u8, name, function_name)) return true;
        }
        for (construct_decl.parents) |parent| {
            if (constructFamilyConsumes(constructs, parent.name, function_name, depth + 1)) return true;
        }
        return false;
    }
    return false;
}

const max_construct_any_storage_depth: u32 = 64;

pub fn containsConstructAnyStorage(ctx: *const Context, ty: model.ResolvedType) bool {
    return containsConstructAnyStorageDepth(ctx, ty, 0);
}

fn containsConstructAnyStorageDepth(ctx: *const Context, ty: model.ResolvedType, depth: u32) bool {
    if (depth >= max_construct_any_storage_depth) return false;
    return switch (ty.kind) {
        .construct_any => true,
        .array => if (ty.name) |name|
            containsConstructAnyStorageDepth(ctx, shared.resolvedTypeFromText(name) catch return false, depth + 1)
        else
            false,
        .named => if (shared.namedTypeHeader(ctx, ty)) |header|
            fieldsContainConstructAnyStorage(ctx, header.fields, depth + 1)
        else if (ctx.imported_globals.findType(ty.name orelse "")) |type_decl|
            importedFieldsContainConstructAnyStorage(ctx, type_decl.fields, depth + 1)
        else
            false,
        .enum_instance => if (ty.name) |name|
            enumContainsConstructAnyStorage(ctx, name, depth + 1)
        else
            false,
        else => false,
    };
}

fn fieldsContainConstructAnyStorage(ctx: *const Context, fields: []const model.Field, depth: u32) bool {
    for (fields) |field| {
        if (containsConstructAnyStorageDepth(ctx, field.ty, depth)) return true;
    }
    return false;
}

fn importedFieldsContainConstructAnyStorage(ctx: *const Context, fields: []const @import("imported_globals.zig").ImportedField, depth: u32) bool {
    for (fields) |field| {
        if (containsConstructAnyStorageDepth(ctx, field.ty, depth)) return true;
    }
    return false;
}

fn enumContainsConstructAnyStorage(ctx: *const Context, name: []const u8, depth: u32) bool {
    if (ctx.concrete_enums) |enums| {
        if (enums.get(name)) |enum_decl| {
            for (enum_decl.variants) |variant| {
                if (variant.payload_ty) |payload| {
                    if (containsConstructAnyStorageDepth(ctx, payload, depth)) return true;
                }
            }
            return false;
        }
    }
    if (ctx.enum_headers) |headers| {
        if (headers.get(name)) |enum_decl| {
            for (enum_decl.variants) |variant| {
                if (variant.payload_ty) |payload| {
                    if (containsConstructAnyStorageDepth(ctx, payload, depth)) return true;
                }
            }
        }
    }
    return false;
}
