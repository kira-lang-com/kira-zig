//! Execution-path unit tests for the VM interpreter: calls, hooks,
//! struct argument copying, printing, and ownership of construct-any
//! values across nested calls.

const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const Vm = @import("vm.zig").Vm;

test "executes nested runtime calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = &.{},
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .call_runtime = .{ .function_id = 1, .args = &.{} } },
                    .{ .ret = .{ .src = null } },
                }),
            },
            .{
                .id = 1,
                .name = "helper",
                .param_count = 0,
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .const_int = .{ .dst = 0, .value = 42 } },
                    .{ .print = .{ .src = 0, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .ret = .{ .src = null } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    try vm.runMain(&module, &stream);
    try std.testing.expectEqualStrings("42\n", stream.buffered());
}

test "prints struct values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = @constCast(&[_]bytecode.TypeDecl{
            .{
                .name = "Color",
                .fields = @constCast(&[_]bytecode.Field{
                    .{ .name = "r", .ty = .{ .kind = .integer, .name = "I64" } },
                    .{ .name = "g", .ty = .{ .kind = .integer, .name = "I64" } },
                    .{ .name = "b", .ty = .{ .kind = .integer, .name = "I64" } },
                }),
            },
        }),
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 8,
                .local_count = 0,
                .local_types = &.{},
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Color" } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Color", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 2, .value = 255 } },
                    .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .field_ptr = .{ .dst = 3, .base = 0, .base_type_name = "Color", .field_index = 1, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 4, .value = 0 } },
                    .{ .store_indirect = .{ .ptr = 3, .src = 4, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .field_ptr = .{ .dst = 5, .base = 0, .base_type_name = "Color", .field_index = 2, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 6, .value = 0 } },
                    .{ .store_indirect = .{ .ptr = 5, .src = 6, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .print = .{ .src = 0, .ty = .{ .kind = .ffi_struct, .name = "Color" } } },
                    .{ .ret = .{ .src = null } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    try vm.runMain(&module, &stream);
    try std.testing.expectEqualStrings("Color(r: 255, g: 0, b: 0)\n", stream.buffered());
}

test "resolves function constants through hooks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = &.{},
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .const_function = .{ .dst = 0, .function_id = 7 } },
                    .{ .ret = .{ .src = 0 } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var discard_buffer: [1]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&discard_buffer);
    const result = try vm.runFunctionById(&module, 0, &.{}, &discarding.writer, .{
        .resolve_function = struct {
            fn resolve(_: ?*anyopaque, function_id: u32) !usize {
                return 0x1000 + function_id;
            }
        }.resolve,
    });

    try std.testing.expectEqual(@as(usize, 0x1007), result.raw_ptr);
}

test "copies struct arguments by value for runtime calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = @constCast(&[_]bytecode.TypeDecl{
            .{
                .name = "Pair",
                .fields = @constCast(&[_]bytecode.Field{
                    .{ .name = "left", .ty = .{ .kind = .integer, .name = "I64" } },
                    .{ .name = "right", .ty = .{ .kind = .integer, .name = "I64" } },
                }),
            },
        }),
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 6,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{.{ .kind = .ffi_struct, .name = "Pair" }}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Pair" } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Pair", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 2, .value = 1 } },
                    .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .store_local = .{ .local = 0, .src = 0 } },
                    .{ .call_runtime = .{ .function_id = 1, .args = &.{0} } },
                    .{ .field_ptr = .{ .dst = 3, .base = 0, .base_type_name = "Pair", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .load_indirect = .{ .dst = 4, .ptr = 3, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .ret = .{ .src = 4 } },
                }),
            },
            .{
                .id = 1,
                .name = "mutate",
                .param_count = 1,
                .register_count = 3,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{.{ .kind = .ffi_struct, .name = "Pair" }}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .load_local = .{ .dst = 0, .local = 0 } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Pair", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 2, .value = 99 } },
                    .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .ret = .{ .src = null } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var discard_buffer_6: [1]u8 = undefined;
    var discarding_6: std.Io.Writer.Discarding = .init(&discard_buffer_6);
    const result = try vm.runFunctionById(&module, 0, &.{}, &discarding_6.writer, .{});
    try std.testing.expectEqual(@as(i64, 1), result.integer);
}

test "copyStruct tolerates null nested ffi struct pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = @constCast(&[_]bytecode.TypeDecl{
            .{
                .name = "Child",
                .fields = @constCast(&[_]bytecode.Field{.{ .name = "x", .ty = .{ .kind = .integer, .name = "I64" } }}),
            },
            .{
                .name = "Parent",
                .fields = @constCast(&[_]bytecode.Field{.{ .name = "child", .ty = .{ .kind = .ffi_struct, .name = "Child" } }}),
            },
        }),
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 7,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{.{ .kind = .ffi_struct, .name = "Parent" }}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Parent" } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Parent", .field_index = 0, .field_ty = .{ .kind = .ffi_struct, .name = "Child" } } },
                    .{ .const_null_ptr = .{ .dst = 2 } },
                    .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = .{ .kind = .ffi_struct, .name = "Child" } } },
                    .{ .call_runtime = .{ .function_id = 1, .args = &.{0} } },
                    .{ .ret = .{ .src = null } },
                }),
            },
            .{
                .id = 1,
                .name = "touch",
                .param_count = 1,
                .register_count = 4,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{.{ .kind = .ffi_struct, .name = "Parent" }}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .load_local = .{ .dst = 0, .local = 0 } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Parent", .field_index = 0, .field_ty = .{ .kind = .ffi_struct, .name = "Child" } } },
                    .{ .load_indirect = .{ .dst = 2, .ptr = 1, .ty = .{ .kind = .ffi_struct, .name = "Child" } } },
                    .{ .field_ptr = .{ .dst = 3, .base = 2, .base_type_name = "Child", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 2, .value = 7 } },
                    .{ .store_indirect = .{ .ptr = 3, .src = 2, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .ret = .{ .src = null } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var discard_buffer_2: [1]u8 = undefined;
    var discarding_2: std.Io.Writer.Discarding = .init(&discard_buffer_2);
    try vm.runMain(&module, &discarding_2.writer);
}

test "construct any values survive nested runtime calls without leaking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const any_widget = bytecode.TypeRef{
        .kind = .construct_any,
        .name = "any Widget",
        .construct_constraint = .{ .construct_name = "Widget" },
    };
    const module = bytecode.Module{
        .constructs = @constCast(&[_]bytecode.Construct{.{ .name = "Widget" }}),
        .construct_implementations = @constCast(&[_]bytecode.ConstructImplementation{
            .{ .type_name = "Button", .construct_constraint = .{ .construct_name = "Widget" }, .fields = &.{}, .has_content = false, .lifecycle_hooks = &.{} },
            .{ .type_name = "Label", .construct_constraint = .{ .construct_name = "Widget" }, .fields = &.{}, .has_content = false, .lifecycle_hooks = &.{} },
        }),
        .types = @constCast(&[_]bytecode.TypeDecl{
            .{ .name = "Button", .fields = &.{} },
            .{ .name = "Label", .fields = &.{} },
        }),
        .functions = @constCast(&[_]bytecode.Function{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 2,
                .local_count = 0,
                .local_types = &.{},
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Button" } },
                    .{ .call_runtime = .{ .function_id = 1, .args = &.{0} } },
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Label" } },
                    .{ .call_runtime = .{ .function_id = 1, .args = &.{0} } },
                    .{ .ret = .{ .src = null } },
                }),
            },
            .{
                .id = 1,
                .name = "forward",
                .param_count = 1,
                .return_type = any_widget,
                .register_count = 2,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{any_widget}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .load_local = .{ .dst = 0, .local = 0 } },
                    .{ .call_runtime = .{ .function_id = 2, .args = &.{0}, .dst = 1 } },
                    .{ .ret = .{ .src = 1 } },
                }),
            },
            .{
                .id = 2,
                .name = "identity",
                .param_count = 1,
                .return_type = any_widget,
                .register_count = 1,
                .local_count = 1,
                .local_types = @constCast(&[_]bytecode.TypeRef{any_widget}),
                .instructions = @constCast(&[_]bytecode.Instruction{
                    .{ .load_local = .{ .dst = 0, .local = 0 } },
                    .{ .ret = .{ .src = 0 } },
                }),
            },
        }),
        .entry_function_id = 0,
    };

    var discard_buffer_7: [1]u8 = undefined;
    var discarding_7: std.Io.Writer.Discarding = .init(&discard_buffer_7);
    try vm.runMain(&module, &discarding_7.writer);
    try std.testing.expectEqual(@as(usize, 0), vm.heap.count());
}
