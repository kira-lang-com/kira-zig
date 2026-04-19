const std = @import("std");
const shader_model = @import("kira_shader_model");

pub fn renderReflectionJson(allocator: std.mem.Allocator, reflection: shader_model.Reflection) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    const writer = out.writer();

    try writer.print(
        \\{{
        \\  "shader": "{s}",
        \\  "kind": "{s}",
        \\  "backend": "{s}",
        \\  "options": [
        \\
    , .{ reflection.shader_name, @tagName(reflection.shader_kind), @tagName(reflection.backend) });

    for (reflection.options, 0..) |option_decl, index| {
        if (index != 0) try writer.writeAll(",\n");
        try writer.print(
            \\    {{ "name": "{s}", "type": "{s}", "default": "{s}" }}
        , .{ option_decl.name, option_decl.type_name, option_decl.default_value });
    }

    try writer.writeAll(
        \\
        \\  ],
        \\  "stages": [
        \\
    );
    for (reflection.stages, 0..) |stage_decl, index| {
        if (index != 0) try writer.writeAll(",\n");
        try writer.print(
            \\    {{ "stage": "{s}", "entry": "{s}", "input": "{s}", "output": "{s}" }}
        , .{
            @tagName(stage_decl.stage),
            stage_decl.entry_name,
            stage_decl.input_type orelse "",
            stage_decl.output_type orelse "",
        });
    }

    try writer.writeAll(
        \\
        \\  ],
        \\  "types": [
        \\
    );
    for (reflection.types, 0..) |type_decl, index| {
        if (index != 0) try writer.writeAll(",\n");
        try writer.print("    {{ \"name\": \"{s}\"", .{type_decl.name});
        if (type_decl.uniform_layout) |layout| {
            try writer.print(", \"uniform_layout\": {{ \"alignment\": {d}, \"size\": {d}, \"fields\": [", .{ layout.alignment, layout.size });
            for (layout.fields, 0..) |field, field_index| {
                if (field_index != 0) try writer.writeAll(", ");
                try writer.print("{{ \"name\": \"{s}\", \"offset\": {d}, \"alignment\": {d}, \"size\": {d}, \"stride\": {d} }}", .{
                    field.name,
                    field.offset,
                    field.alignment,
                    field.size,
                    field.stride,
                });
            }
            try writer.writeAll("] }");
        }
        if (type_decl.storage_layout) |layout| {
            try writer.print(", \"storage_layout\": {{ \"alignment\": {d}, \"size\": {d}, \"fields\": [", .{ layout.alignment, layout.size });
            for (layout.fields, 0..) |field, field_index| {
                if (field_index != 0) try writer.writeAll(", ");
                try writer.print("{{ \"name\": \"{s}\", \"offset\": {d}, \"alignment\": {d}, \"size\": {d}, \"stride\": {d} }}", .{
                    field.name,
                    field.offset,
                    field.alignment,
                    field.size,
                    field.stride,
                });
            }
            try writer.writeAll("] }");
        }
        try writer.writeAll(" }");
    }

    try writer.writeAll(
        \\
        \\  ],
        \\  "resources": [
        \\
    );
    for (reflection.resources, 0..) |resource_decl, index| {
        if (index != 0) try writer.writeAll(",\n");
        try writer.print(
            \\    {{ "group": "{s}", "class": "{s}", "resource": "{s}", "kind": "{s}", "type": "{s}", "group_index": {d}, "binding_index": {d} }}
        , .{
            resource_decl.group_name,
            @tagName(resource_decl.group_class),
            resource_decl.resource_name,
            @tagName(resource_decl.resource_kind),
            resource_decl.type_name,
            resource_decl.group_index,
            resource_decl.backend_bindings[0].binding_index,
        });
    }

    try writer.writeAll(
        \\
        \\  ]
        \\}
        \\
    );
    return out.toOwnedSlice();
}
