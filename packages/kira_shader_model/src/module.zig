const std = @import("std");
const shader_types = @import("types.zig");

pub const ShaderKind = enum {
    graphics,
    compute,
};

pub const GroupClass = enum {
    frame,
    pass,
    material,
    object,
    draw,
    dispatch,
    custom,
};

pub const ResourceKind = enum {
    uniform,
    storage,
    texture,
    sampler,
};

pub const OptionDecl = struct {
    name: []const u8,
    ty: shader_types.Type,
};

pub const InterfaceField = struct {
    name: []const u8,
    ty: shader_types.Type,
    builtin: ?shader_types.Builtin = null,
    interpolation: ?shader_types.Interpolation = null,
};

pub const Interface = struct {
    name: []const u8,
    direction: shader_types.InterfaceDirection,
    fields: []const InterfaceField,
};

pub const Resource = struct {
    name: []const u8,
    kind: ResourceKind,
    ty: shader_types.Type,
    access: ?shader_types.AccessMode = null,
};

pub const ResourceGroup = struct {
    name: []const u8,
    class: GroupClass,
    resources: []const Resource,
};

pub const EntryPoint = struct {
    stage: shader_types.Stage,
    input_name: []const u8,
    output_name: ?[]const u8 = null,
};

pub const ShaderDecl = struct {
    name: []const u8,
    kind: ShaderKind,
    options: []const OptionDecl,
    groups: []const ResourceGroup,
    entries: []const EntryPoint,
};

pub fn classifyGroupName(name: []const u8) GroupClass {
    if (std.ascii.eqlIgnoreCase(name, "Frame")) return .frame;
    if (std.ascii.eqlIgnoreCase(name, "Pass")) return .pass;
    if (std.ascii.eqlIgnoreCase(name, "Material")) return .material;
    if (std.ascii.eqlIgnoreCase(name, "Object")) return .object;
    if (std.ascii.eqlIgnoreCase(name, "Draw")) return .draw;
    if (std.ascii.eqlIgnoreCase(name, "Dispatch")) return .dispatch;
    return .custom;
}

test "group classification follows canonical names" {
    try std.testing.expectEqual(GroupClass.frame, classifyGroupName("Frame"));
    try std.testing.expectEqual(GroupClass.dispatch, classifyGroupName("dispatch"));
    try std.testing.expectEqual(GroupClass.custom, classifyGroupName("Lighting"));
}
