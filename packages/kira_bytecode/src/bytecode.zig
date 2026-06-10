const std = @import("std");
const instruction = @import("instruction.zig");
const ownership_mode = @import("ownership_mode.zig");

pub const Module = struct {
    constructs: []Construct = &.{},
    construct_implementations: []ConstructImplementation = &.{},
    types: []TypeDecl = &.{},
    enums: []EnumTypeDecl = &.{},
    functions: []Function,
    entry_function_id: ?u32,

    pub fn writeToFile(self: Module, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{ .truncate = true });
        defer file.close(std.Options.debug_io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(std.Options.debug_io, &buffer);
        defer writer.interface.flush() catch {};
        try serialize(&writer.interface, self);
    }

    pub fn readFromFile(allocator: std.mem.Allocator, path: []const u8) !Module {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024 * 1024));
        return deserialize(allocator, bytes);
    }

    pub fn findFunctionById(self: Module, function_id: u32) ?Function {
        for (self.functions) |function_decl| {
            if (function_decl.id == function_id) return function_decl;
        }
        return null;
    }
};

pub const Function = struct {
    id: u32,
    name: []const u8,
    param_count: u32 = 0,
    param_ownership: []const OwnershipMode = &.{},
    return_type: instruction.TypeRef = .{ .kind = .void },
    return_ownership: OwnershipMode = .owned,
    register_count: u32,
    local_count: u32,
    local_types: []instruction.TypeRef = &.{},
    instructions: []instruction.Instruction,
};

pub const Construct = struct {
    name: []const u8,
};

pub const ConstructImplementation = struct {
    type_name: []const u8,
    construct_constraint: instruction.TypeRef.ConstructConstraint,
    fields: []Field,
    has_content: bool,
    lifecycle_hooks: []LifecycleHook,
};

pub const LifecycleHook = struct {
    name: []const u8,
};

pub const TypeDecl = struct {
    name: []const u8,
    kind: TypeKind = .struct_decl,
    fields: []Field,
    methods: []MethodMember = &.{},
};

pub const OwnershipMode = ownership_mode.OwnershipMode;

pub const TypeKind = enum(u8) {
    class,
    struct_decl,
};

pub const MethodMember = struct {
    name: []const u8,
    function_id: u32,
    receiver_offset: u32,
};

pub const EnumTypeDecl = struct {
    name: []const u8,
    variants: []EnumVariantDecl,
};

pub const EnumVariantDecl = struct {
    name: []const u8,
    discriminant: u32,
    payload_ty: ?instruction.TypeRef = null,
};

pub const Field = struct {
    name: []const u8,
    ty: instruction.TypeRef,
};

pub const serialize = @import("serialization.zig").serialize;
pub const deserialize = @import("serialization.zig").deserialize;

test {
    _ = @import("serialization.zig");
}
