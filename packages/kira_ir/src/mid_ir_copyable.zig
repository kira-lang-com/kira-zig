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
// as non-copyable rather than looping forever.
const max_copyable_depth: u32 = 64;

/// A value type that is duplicated rather than moved when passed by value. Trivially
/// copyable scalars are the base case; an enum is copyable when every variant payload
/// is copyable (a fieldless enum trivially so); a struct is copyable when every field
/// is. A type that owns heap (string, array) or hides ownership behind an opaque
/// payload (callback, native state) is never copyable and must move, which is what
/// keeps the latent enum-copy use-after-free impossible.
pub fn isCopyableType(self: *const Checker, ty: model.ResolvedType) bool {
    return isCopyableTypeDepth(self, ty, 0);
}

fn isCopyableTypeDepth(self: *const Checker, ty: model.ResolvedType, depth: u32) bool {
    if (isTriviallyCopyableType(ty)) return true;
    if (depth >= max_copyable_depth) return false;
    return switch (ty.kind) {
        .enum_instance => isCopyableEnumType(self, ty, depth),
        .named => isCopyableStructType(self, ty, depth),
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

test {
    std.testing.refAllDecls(@This());
}
