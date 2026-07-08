//! Rust-style `Copy` classification for the Mid IR ownership checker. A type is
//! copyable exactly when every component it owns is itself copyable, so a by-value
//! use can be a shallow (bitwise) copy with no aliased heap and therefore no
//! double-free — mirroring Rust's `#[derive(Copy)]` eligibility. This lives apart
//! from `mid_ir_check.zig` so the control-flow traversal and diagnostics core stays
//! focused; the functions operate on `*const Checker` and are re-exposed there as
//! `Checker.isCopyableType`.
const std = @import("std");
const model = @import("kira_semantics_model");
const place_algebra = @import("mid_ir_place.zig");
const check = @import("mid_ir_check.zig");

const Checker = check.Checker;
const isTriviallyCopyableType = place_algebra.isTriviallyCopyableType;

// Bound on how deep the structural copy check recurses through nested aggregates.
// Value types cannot contain themselves by value (that would be infinitely sized),
// so any chain longer than this is pathological/cyclic and is treated conservatively
// as non-copyable rather than looping forever. Retained as a backstop; the primary
// cycle guard is now the per-name `visiting` set in `TypeClass`.
const max_copyable_depth: u32 = 64;

/// Program-scoped memo for the two structural type classifications below. Both
/// `isCopyableType` and `containsConstructAny` are pure functions of a type's
/// definition (identical across every function in the program), yet the old code
/// recomputed them — each doing an O(types) linear scan to resolve a name and then
/// recursing per field — for every value in every function. On the project-matter
/// editor these two walks were the single largest lowering cost after reachability.
///
/// Results are keyed by type name. A `visiting` set breaks reference cycles
/// deterministically (a name seen mid-computation classifies conservatively, exactly
/// as the depth cap did) so the cached answer is depth-independent and safe to reuse.
/// Cache writes are best-effort (`catch {}`) so these stay non-erroring `bool` calls;
/// on the rare allocation failure the depth cap still guarantees termination.
pub const TypeClass = struct {
    allocator: std.mem.Allocator,
    copyable: std.StringHashMapUnmanaged(bool) = .{},
    contains_any: std.StringHashMapUnmanaged(bool) = .{},
    copyable_visiting: std.StringHashMapUnmanaged(void) = .{},
    contains_any_visiting: std.StringHashMapUnmanaged(void) = .{},

    pub fn init(allocator: std.mem.Allocator) TypeClass {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TypeClass) void {
        self.copyable.deinit(self.allocator);
        self.contains_any.deinit(self.allocator);
        self.copyable_visiting.deinit(self.allocator);
        self.contains_any_visiting.deinit(self.allocator);
    }
};

/// A value type that is duplicated rather than moved when passed by value. Trivially
/// copyable scalars are the base case; an enum is copyable when every variant payload
/// is copyable (a fieldless enum trivially so); a struct is copyable when every field
/// is. A type that owns heap (string, array) or hides ownership behind an opaque
/// payload (callback, native state) is never copyable and must move, which is what
/// keeps the latent enum-copy use-after-free impossible.
pub fn isCopyableType(self: *const Checker, ty: model.ResolvedType) bool {
    return isCopyableTypeDepth(self, ty, 0);
}

pub fn containsConstructAny(self: *const Checker, ty: model.ResolvedType) bool {
    return containsConstructAnyDepth(self, ty, 0);
}

fn isCopyableTypeDepth(self: *const Checker, ty: model.ResolvedType, depth: u32) bool {
    if (isTriviallyCopyableType(ty)) return true;
    if (depth >= max_copyable_depth) return false;
    return switch (ty.kind) {
        .enum_instance, .named => blk: {
            const name = ty.name orelse break :blk false;
            const cache = self.type_class;
            if (cache.copyable.get(name)) |cached| break :blk cached;
            // Cycle: a type referenced while still being classified is conservatively
            // non-copyable, matching the former depth-cap behaviour.
            if (cache.copyable_visiting.contains(name)) break :blk false;
            cache.copyable_visiting.put(cache.allocator, name, {}) catch {};
            const result = if (ty.kind == .enum_instance)
                isCopyableEnumType(self, ty, depth)
            else
                isCopyableStructType(self, ty, depth);
            _ = cache.copyable_visiting.remove(name);
            cache.copyable.put(cache.allocator, name, result) catch {};
            break :blk result;
        },
        else => false,
    };
}

fn isCopyableEnumType(self: *const Checker, ty: model.ResolvedType, depth: u32) bool {
    const name = ty.name orelse return false;
    for (self.program.source_program.enums) |enum_decl| {
        if (!std.mem.eql(u8, enum_decl.name, name)) continue;
        for (enum_decl.variants) |variant| {
            if (variant.payload_ty) |payload| {
                if (!isCopyableTypeDepth(self, payload, depth + 1)) return false;
            }
        }
        return true;
    }
    return false;
}

fn isCopyableStructType(self: *const Checker, ty: model.ResolvedType, depth: u32) bool {
    const name = ty.name orelse return false;
    for (self.program.source_program.types) |type_decl| {
        if (type_decl.kind != .struct_decl) continue;
        if (!std.mem.eql(u8, type_decl.name, name)) continue;
        for (type_decl.fields) |field| {
            if (!isCopyableTypeDepth(self, field.ty, depth + 1)) return false;
        }
        return true;
    }
    return false;
}

fn containsConstructAnyDepth(self: *const Checker, ty: model.ResolvedType, depth: u32) bool {
    if (depth >= max_copyable_depth) return false;
    return switch (ty.kind) {
        .construct_any => true,
        .array => if (ty.name) |name|
            containsConstructAnyDepth(self, resolvedTypeFromStorageText(name) orelse return false, depth + 1)
        else
            false,
        .named, .enum_instance => blk: {
            const name = ty.name orelse break :blk false;
            const cache = self.type_class;
            if (cache.contains_any.get(name)) |cached| break :blk cached;
            // Cycle: conservatively "does not contain", matching the depth-cap default.
            if (cache.contains_any_visiting.contains(name)) break :blk false;
            cache.contains_any_visiting.put(cache.allocator, name, {}) catch {};
            const result = if (ty.kind == .named)
                containsConstructAnyStructType(self, ty, depth)
            else
                containsConstructAnyEnumType(self, ty, depth);
            _ = cache.contains_any_visiting.remove(name);
            cache.contains_any.put(cache.allocator, name, result) catch {};
            break :blk result;
        },
        else => false,
    };
}

fn containsConstructAnyEnumType(self: *const Checker, ty: model.ResolvedType, depth: u32) bool {
    const name = ty.name orelse return false;
    for (self.program.source_program.enums) |enum_decl| {
        if (!std.mem.eql(u8, enum_decl.name, name)) continue;
        for (enum_decl.variants) |variant| {
            if (variant.payload_ty) |payload| {
                if (containsConstructAnyDepth(self, payload, depth + 1)) return true;
            }
        }
        return false;
    }
    return false;
}

fn containsConstructAnyStructType(self: *const Checker, ty: model.ResolvedType, depth: u32) bool {
    const name = ty.name orelse return false;
    for (self.program.source_program.types) |type_decl| {
        if (!std.mem.eql(u8, type_decl.name, name)) continue;
        for (type_decl.fields) |field| {
            if (containsConstructAnyDepth(self, field.ty, depth + 1)) return true;
        }
        return false;
    }
    return false;
}

fn resolvedTypeFromStorageText(text: []const u8) ?model.ResolvedType {
    if (std.mem.startsWith(u8, text, "any ")) {
        return .{
            .kind = .construct_any,
            .name = text,
            .construct_constraint = .{ .construct_name = text[4..] },
        };
    }
    if (text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']') {
        return .{ .kind = .array, .name = text[1 .. text.len - 1] };
    }
    return .{ .kind = .named, .name = text };
}

test {
    std.testing.refAllDecls(@This());
}
