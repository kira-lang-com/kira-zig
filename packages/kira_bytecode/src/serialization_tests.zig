const std = @import("std");
const instruction = @import("instruction.zig");
const bytecode = @import("bytecode.zig");
const runtime_abi = @import("kira_runtime_abi");
const serialization = @import("serialization.zig");

const Module = bytecode.Module;
const serialize = serialization.serialize;
const deserialize = serialization.deserialize;

test "round-trips struct metadata and print instructions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const module: Module = .{
        .types = &.{
            .{
                .name = "Color",
                .fields = &.{
                    .{ .name = "r", .ty = .{ .kind = .integer, .name = "I64" } },
                    .{ .name = "g", .ty = .{ .kind = .integer, .name = "I64" } },
                    .{ .name = "b", .ty = .{ .kind = .integer, .name = "I64" } },
                },
            },
        },
        .functions = &.{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Color" } },
                    .{ .print = .{ .src = 0, .ty = .{ .kind = .ffi_struct, .name = "Color" } } },
                    .{ .ret = .{ .src = null } },
                },
            },
        },
        .entry_function_id = 0,
    };

    var buffer: [2048]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    try serialize(&stream, module);

    const round_tripped = try deserialize(allocator, stream.buffered());
    try std.testing.expectEqual(@as(usize, 1), round_tripped.types.len);
    try std.testing.expectEqualStrings("Color", round_tripped.types[0].name);
    try std.testing.expectEqual(@as(usize, 3), round_tripped.types[0].fields.len);
    try std.testing.expectEqual(@as(?u32, 0), round_tripped.entry_function_id);
    try std.testing.expect(round_tripped.functions[0].instructions[0] == .alloc_struct);
    try std.testing.expect(round_tripped.functions[0].instructions[1] == .print);
    try std.testing.expectEqualStrings("Color", round_tripped.functions[0].instructions[1].print.ty.name.?);
}

test "round-trips function constants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const module: Module = .{
        .types = &.{},
        .functions = &.{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{
                    .{ .const_function = .{ .dst = 0, .function_id = 42 } },
                    .{ .ret = .{ .src = null } },
                },
            },
        },
        .entry_function_id = 0,
    };

    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try serialize(&bytes.writer, module);

    const round_tripped = try deserialize(allocator, bytes.written());
    try std.testing.expect(round_tripped.functions[0].instructions[0] == .const_function);
    try std.testing.expectEqual(@as(u32, 42), round_tripped.functions[0].instructions[0].const_function.function_id);
}

test "round-trips foreign FFI metadata for VM direct dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const module: Module = .{
        .types = &.{},
        .functions = &.{
            .{
                .id = 7,
                .name = "kira_ffi_add",
                .param_count = 2,
                .param_types = &.{
                    .{ .kind = .integer, .name = "I32" },
                    .{ .kind = .integer, .name = "I32" },
                },
                .return_type = .{ .kind = .integer, .name = "I32" },
                .is_extern = true,
                .foreign = .{
                    .library_name = "ffimath",
                    .symbol_name = "kira_ffi_add",
                    .calling_convention = .c,
                },
                .register_count = 0,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{},
            },
        },
        .entry_function_id = null,
    };

    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try serialize(&bytes.writer, module);

    const round_tripped = try deserialize(allocator, bytes.written());
    const func = round_tripped.functions[0];
    try std.testing.expect(func.is_extern);
    try std.testing.expect(func.foreign != null);
    try std.testing.expectEqualStrings("ffimath", func.foreign.?.library_name);
    try std.testing.expectEqualStrings("kira_ffi_add", func.foreign.?.symbol_name);
    try std.testing.expectEqual(runtime_abi.CallingConvention.c, func.foreign.?.calling_convention);
    try std.testing.expectEqual(@as(usize, 2), func.param_types.len);
    try std.testing.expectEqualStrings("I32", func.param_types[0].name.?);
    try std.testing.expectEqualStrings("I32", func.return_type.name.?);
}

test "round-trips construct metadata and constrained types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const module: Module = .{
        .constructs = &.{.{ .name = "Widget" }},
        .construct_implementations = &.{.{
            .type_name = "Button",
            .construct_constraint = .{ .construct_name = "Widget" },
            .families = &.{ "Widget", "Renderable" },
            .fields = &.{.{ .name = "title", .ty = .{ .kind = .string } }},
            .has_content = true,
            .lifecycle_hooks = &.{.{ .name = "onAppear" }},
        }},
        .types = &.{},
        .functions = &.{.{
            .id = 0,
            .name = "main",
            .param_count = 1,
            .return_type = .{ .kind = .construct_any, .name = "any Widget", .construct_constraint = .{ .construct_name = "Widget" } },
            .register_count = 0,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &.{.{ .ret = .{ .src = null } }},
        }},
        .entry_function_id = 0,
    };

    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try serialize(&bytes.writer, module);

    const round_tripped = try deserialize(allocator, bytes.written());
    try std.testing.expectEqual(@as(usize, 1), round_tripped.constructs.len);
    try std.testing.expectEqualStrings("Widget", round_tripped.constructs[0].name);
    try std.testing.expectEqual(@as(usize, 1), round_tripped.construct_implementations.len);
    try std.testing.expectEqualStrings("Button", round_tripped.construct_implementations[0].type_name);
    try std.testing.expectEqualStrings("Widget", round_tripped.construct_implementations[0].construct_constraint.construct_name);
    try std.testing.expectEqual(@as(usize, 2), round_tripped.construct_implementations[0].families.len);
    try std.testing.expectEqualStrings("Renderable", round_tripped.construct_implementations[0].families[1]);
    try std.testing.expect(round_tripped.construct_implementations[0].has_content);
    try std.testing.expectEqual(instruction.TypeRef.Kind.construct_any, round_tripped.functions[0].return_type.kind);
    try std.testing.expectEqualStrings("Widget", round_tripped.functions[0].return_type.construct_constraint.?.construct_name);
}
