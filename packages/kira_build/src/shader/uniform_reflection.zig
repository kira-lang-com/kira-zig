const std = @import("std");
const shader_model = @import("kira_shader_model");

// Renders a compact, backend-independent uniform-block descriptor string from a
// shader Reflection. This is the honest bridge between the KSL shader compiler's
// real reflection (uniform names, std140 sizes, group/binding slots, per-stage
// visibility, and member layout) and the Sokol native backend, which used to
// hardcode exactly two uniform blocks ("scene"/"object"). The `ksl!` macro embeds
// this string in the KslArtifact so the engine can configure per-shader uniform
// blocks with zero source grepping.
//
// Grammar (identifiers are `[A-Za-z0-9_]`, so the delimiters never collide):
//
//   reflection := block (';' block)*
//   block      := name ':' binding ':' sizeBytes ':' stageMask ':' memberCount (':' members)?
//   members    := member (',' member)*
//   member     := name '@' offset '#' size
//
//   binding   = WGSL @group(0) @binding(N) index (also the app's public bind slot)
//   sizeBytes = std140 block size in bytes
//   stageMask = bit0 vertex | bit1 fragment | bit2 compute
//
// An empty string means the shader declares no uniform blocks.
pub fn render(allocator: std.mem.Allocator, reflection: shader_model.Reflection) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;

    var block_index: usize = 0;
    for (reflection.resources) |resource_decl| {
        if (resource_decl.resource_kind != .uniform) continue;

        const binding = if (resource_decl.backend_bindings.len > 0)
            resource_decl.backend_bindings[0].binding_index
        else
            0;

        var stage_mask: u32 = 0;
        for (resource_decl.visibility) |stage| {
            stage_mask |= switch (stage) {
                .vertex => @as(u32, 1) << 0,
                .fragment => @as(u32, 1) << 1,
                .compute => @as(u32, 1) << 2,
            };
        }

        const layout = uniformLayoutFor(reflection, resource_decl.type_name);
        const size_bytes: u32 = if (layout) |l| l.size else 0;
        const fields: []const shader_model.ReflectedLayoutField = if (layout) |l| l.fields else &.{};

        if (block_index != 0) try writer.writeByte(';');
        block_index += 1;

        try writer.print("{s}:{d}:{d}:{d}:{d}", .{
            resource_decl.resource_name,
            binding,
            size_bytes,
            stage_mask,
            fields.len,
        });
        if (fields.len > 0) {
            try writer.writeByte(':');
            for (fields, 0..) |field, field_index| {
                if (field_index != 0) try writer.writeByte(',');
                try writer.print("{s}@{d}#{d}", .{ field.name, field.offset, field.size });
            }
        }
    }

    return out.toOwnedSlice();
}

fn uniformLayoutFor(reflection: shader_model.Reflection, type_name: []const u8) ?shader_model.ReflectedLayout {
    for (reflection.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, type_name)) return type_decl.uniform_layout;
    }
    return null;
}

test "compact uniform reflection encodes camera block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fields = [_]shader_model.ReflectedLayoutField{
        .{ .name = "viewProj", .offset = 0, .alignment = 16, .size = 64 },
    };
    const types = [_]shader_model.ReflectedType{
        .{
            .name = "CameraUniform",
            .fields = &.{},
            .uniform_layout = .{ .class = "uniform", .alignment = 16, .size = 64, .fields = &fields },
        },
    };
    const visibility = [_]shader_model.Stage{.vertex};
    const bindings = [_]shader_model.BackendBinding{
        .{ .target = .wgsl, .group_index = 0, .binding_index = 0 },
    };
    const resources = [_]shader_model.ReflectedResource{
        .{
            .group_name = "Frame",
            .group_class = .frame,
            .group_index = 0,
            .resource_name = "camera",
            .resource_kind = .uniform,
            .type_name = "CameraUniform",
            .visibility = &visibility,
            .backend_bindings = &bindings,
        },
    };
    const reflection = shader_model.Reflection{
        .shader_name = "Cube",
        .shader_kind = .graphics,
        .backend = .wgsl,
        .types = &types,
        .resources = &resources,
    };

    const text = try render(allocator, reflection);
    try std.testing.expectEqualStrings("camera:0:64:1:1:viewProj@0#64", text);
}

test "compact uniform reflection skips textures and is empty without uniforms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bindings = [_]shader_model.BackendBinding{
        .{ .target = .wgsl, .group_index = 1, .binding_index = 0 },
    };
    const resources = [_]shader_model.ReflectedResource{
        .{
            .group_name = "Material",
            .group_class = .material,
            .group_index = 1,
            .resource_name = "albedo",
            .resource_kind = .texture,
            .type_name = "texture2d",
            .visibility = &.{},
            .backend_bindings = &bindings,
        },
    };
    const reflection = shader_model.Reflection{
        .shader_name = "Textured",
        .shader_kind = .graphics,
        .backend = .wgsl,
        .resources = &resources,
    };

    const text = try render(allocator, reflection);
    try std.testing.expectEqualStrings("", text);
}
