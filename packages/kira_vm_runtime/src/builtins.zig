const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");

pub fn printValue(writer: anytype, module: *const bytecode.Module, value: runtime_abi.Value, ty: bytecode.TypeRef) !void {
    try formatValue(writer, module, value, ty);
    try writer.writeByte('\n');
}

fn formatValue(writer: anytype, module: *const bytecode.Module, value: runtime_abi.Value, ty: bytecode.TypeRef) !void {
    if (!valueMatchesTypeRef(value, ty)) return error.RuntimeFailure;
    switch (ty.kind) {
        .void => try writer.writeAll("void"),
        .integer => try writer.print("{d}", .{value.integer}),
        .float => try writer.print("{d}", .{value.float}),
        .string => try writer.writeAll(value.string),
        .boolean => try writer.writeAll(if (value.boolean) "true" else "false"),
        .array => try writer.print("array(len: {d})", .{(@as(*const ArrayObject, @ptrFromInt(value.raw_ptr))).len}),
        .raw_ptr => try writer.print("0x{x}", .{value.raw_ptr}),
        .ffi_struct => {
            const type_name = ty.name orelse return error.RuntimeFailure;
            const type_decl = findType(module, type_name) orelse return error.RuntimeFailure;
            try writer.print("{s}(", .{type_name});
            const base_ptr: [*]const runtime_abi.Value = @ptrFromInt(value.raw_ptr);
            for (type_decl.fields, 0..) |field_decl, index| {
                if (index != 0) try writer.writeAll(", ");
                try writer.print("{s}: ", .{field_decl.name});
                try formatValue(writer, module, base_ptr[index], field_decl.ty);
            }
            try writer.writeByte(')');
        },
    }
}

fn valueMatchesTypeRef(value: runtime_abi.Value, ty: bytecode.TypeRef) bool {
    return switch (ty.kind) {
        .void => value == .void,
        .integer => value == .integer,
        .float => value == .float,
        .string => value == .string,
        .boolean => value == .boolean,
        .array, .raw_ptr, .ffi_struct => value == .raw_ptr,
    };
}

const ArrayObject = extern struct {
    len: usize,
    items: [*]runtime_abi.BridgeValue,
};

fn findType(module: *const bytecode.Module, name: []const u8) ?bytecode.TypeDecl {
    for (module.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
    }
    return null;
}

test "printValue fails cleanly on mismatched runtime value" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();
    const module: bytecode.Module = .{
        .types = &.{},
        .functions = &.{},
        .entry_function_id = null,
    };

    try std.testing.expectError(error.RuntimeFailure, printValue(
        buffer.writer(),
        &module,
        .{ .void = {} },
        .{ .kind = .integer },
    ));
}
