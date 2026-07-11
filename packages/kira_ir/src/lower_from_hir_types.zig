const std = @import("std");
const ir = @import("ir.zig");
const model = @import("kira_semantics_model");

pub fn lowerResolvedTypeSlice(allocator: std.mem.Allocator, program: model.Program, types: []const model.ResolvedType) ![]ir.ValueType {
    const lowered = try allocator.alloc(ir.ValueType, types.len);
    for (types, 0..) |ty, index| lowered[index] = try lowerResolvedType(program, ty);
    return lowered;
}

// Tracks the FFI-alias names currently being resolved so that a self- or
// mutually-referential alias (e.g. the autobound `@FFI.Alias { target: X }
// struct X {}`) is lowered to an opaque type instead of recursing forever.
const VisitedNames = struct {
    buf: [64][]const u8 = undefined,
    len: usize = 0,

    fn contains(self: *const VisitedNames, name: []const u8) bool {
        for (self.buf[0..self.len]) |seen| {
            if (std.mem.eql(u8, seen, name)) return true;
        }
        return false;
    }

    /// Records `name` as in-progress. Returns false when the fixed buffer is
    /// full: callers must fail closed (treat the type as opaque) rather than
    /// recurse, otherwise an alias cycle longer than `buf.len` distinct names
    /// would slip past `contains` and recurse until stack overflow.
    fn push(self: *VisitedNames, name: []const u8) bool {
        if (self.len < self.buf.len) {
            self.buf[self.len] = name;
            self.len += 1;
            return true;
        }
        return false;
    }
};

// An FFI type that can only be treated opaquely: a `*_ptr` binding is a raw
// pointer, anything else is an opaque foreign struct value.
fn opaqueFfiType(name: []const u8) ir.ValueType {
    if (std.mem.endsWith(u8, name, "_ptr")) return .{ .kind = .raw_ptr, .name = name };
    return .{ .kind = .ffi_struct, .name = name };
}

pub fn lowerResolvedType(program: model.Program, ty: model.ResolvedType) !ir.ValueType {
    var seen = VisitedNames{};
    return lowerResolvedTypeInner(program, ty, &seen);
}

pub fn lowerNamedType(program: model.Program, name: []const u8) anyerror!ir.ValueType {
    var seen = VisitedNames{};
    return lowerNamedTypeInner(program, name, &seen);
}

fn lowerResolvedTypeInner(program: model.Program, ty: model.ResolvedType, seen: *VisitedNames) anyerror!ir.ValueType {
    return switch (ty.kind) {
        .void => .{ .kind = .void },
        .integer => .{ .kind = .integer, .name = ty.name },
        .float => .{ .kind = .float, .name = ty.name },
        .string => .{ .kind = .string },
        .boolean => .{ .kind = .boolean, .name = ty.name },
        .construct_any => .{ .kind = .construct_any, .name = ty.name, .construct_constraint = if (ty.construct_constraint) |constraint| .{ .construct_name = constraint.construct_name } else null },
        .array => .{ .kind = .array, .name = ty.name },
        .raw_ptr, .c_string, .callback, .native_state, .native_state_view => .{ .kind = .raw_ptr, .name = ty.name },
        .enum_instance => .{ .kind = .enum_instance, .name = ty.name },
        .named => if (ty.name) |name| lowerNamedTypeInner(program, name, seen) else return error.UnsupportedType,
        .ffi_struct, .unknown => return error.UnsupportedType,
    };
}

fn lowerNamedTypeInner(program: model.Program, name: []const u8, seen: *VisitedNames) anyerror!ir.ValueType {
    for (program.types) |type_decl| {
        if (!std.mem.eql(u8, type_decl.name, name)) continue;
        if (type_decl.ffi) |ffi_info| {
            return switch (ffi_info) {
                .pointer, .callback => .{ .kind = .raw_ptr, .name = name },
                .alias => |value| blk: {
                    // A degenerate self-referential alias (or an A -> B -> A
                    // cycle) has no concrete target; treat it as opaque.
                    if (seen.contains(name)) break :blk opaqueFfiType(name);
                    // Fail closed if we can no longer track this name: an
                    // untracked deep chain could otherwise recurse unbounded.
                    if (!seen.push(name)) break :blk opaqueFfiType(name);
                    break :blk lowerResolvedTypeInner(program, value.target, seen);
                },
                .ffi_struct => .{ .kind = .ffi_struct, .name = name },
                .array => .{ .kind = .raw_ptr, .name = name },
            };
        }
        return .{ .kind = .ffi_struct, .name = name };
    }
    for (program.enums) |enum_decl| {
        if (std.mem.eql(u8, enum_decl.name, name)) return .{ .kind = .enum_instance, .name = name };
    }
    if (std.mem.endsWith(u8, name, "_ptr")) return .{ .kind = .raw_ptr, .name = name };
    return error.UnsupportedType;
}

pub fn lowerExecutableCompareOperandType(program: model.Program, ty: model.ResolvedType, op: model.hir.BinaryOp) !ir.ValueType {
    const lowered = try lowerResolvedType(program, ty);
    return switch (lowered.kind) {
        .integer => lowered,
        .float => lowered,
        .boolean => switch (op) {
            .equal, .not_equal => lowered,
            else => error.UnsupportedExecutableFeature,
        },
        .raw_ptr, .ffi_struct, .enum_instance => switch (op) {
            .equal, .not_equal => lowered,
            else => error.UnsupportedExecutableFeature,
        },
        // String content equality; ordering (`<`/`>`) is not defined.
        .string => switch (op) {
            .equal, .not_equal => lowered,
            else => error.UnsupportedExecutableFeature,
        },
        else => error.UnsupportedExecutableFeature,
    };
}

pub fn lowerExecutableIntegerType(program: model.Program, ty: model.ResolvedType) !ir.ValueType {
    const lowered = try lowerResolvedType(program, ty);
    if (lowered.kind != .integer) return error.UnsupportedExecutableFeature;
    return lowered;
}

pub fn lowerExecutableNumericType(program: model.Program, ty: model.ResolvedType) !ir.ValueType {
    const lowered = try lowerResolvedType(program, ty);
    return switch (lowered.kind) {
        .integer, .float => lowered,
        else => error.UnsupportedExecutableFeature,
    };
}

pub fn lowerExecutableBooleanType(program: model.Program, ty: model.ResolvedType) !ir.ValueType {
    const lowered = try lowerResolvedType(program, ty);
    if (lowered.kind != .boolean) return error.UnsupportedExecutableFeature;
    return lowered;
}

pub fn valueTypesEqual(lhs: ir.ValueType, rhs: ir.ValueType) bool {
    if (lhs.kind != rhs.kind) return false;
    if (lhs.construct_constraint) |constraint| {
        const rhs_constraint = rhs.construct_constraint orelse return false;
        if (!std.mem.eql(u8, constraint.construct_name, rhs_constraint.construct_name)) return false;
    } else if (rhs.construct_constraint != null) {
        return false;
    }
    if (lhs.name == null and rhs.name == null) return true;
    if (lhs.name == null or rhs.name == null) return false;
    return std.mem.eql(u8, lhs.name.?, rhs.name.?);
}

pub fn findTypeDeclByName(program: model.Program, name: []const u8) ?model.TypeDecl {
    for (program.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
    }
    return null;
}

pub fn resolveConstructFieldIndex(
    type_decl: model.TypeDecl,
    filled: []bool,
    next_index: *usize,
    field_init: model.hir.ConstructFieldInit,
) !usize {
    if (field_init.field_index) |field_index| return field_index;
    if (field_init.field_name) |field_name| {
        return fieldIndexByName(type_decl, field_name) orelse return error.UnsupportedExecutableFeature;
    }

    while (next_index.* < filled.len and filled[next_index.*]) next_index.* += 1;
    if (next_index.* >= filled.len) return error.UnsupportedExecutableFeature;
    const resolved = next_index.*;
    next_index.* += 1;
    return resolved;
}

pub fn fieldIndexByName(type_decl: model.TypeDecl, field_name: []const u8) ?usize {
    for (type_decl.fields, 0..) |field_decl, index| {
        if (std.mem.eql(u8, field_decl.name, field_name)) return index;
    }
    return null;
}

pub fn nativeStateTypeId(type_name: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (type_name) |byte| {
        hash ^= @as(u64, byte);
        hash *%= 1099511628211;
    }
    return hash & 0x7fff_ffff_ffff_ffff;
}
