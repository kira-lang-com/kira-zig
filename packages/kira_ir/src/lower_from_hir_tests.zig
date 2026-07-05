//! Unit tests for HIR -> IR program lowering: sparse FFI construction
//! zero-fill behavior and deterministic generated-callback function ids under
//! parallel root-function lowering.
const std = @import("std");
const model = @import("kira_semantics_model");
const lower_from_hir = @import("lower_from_hir.zig");

const lowerProgram = lower_from_hir.lowerProgram;
const lowerProgramWithOptions = lower_from_hir.lowerProgramWithOptions;

test "lowers sparse FFI construction by zero-filling omitted fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const field_value = try allocator.create(model.Expr);
    field_value.* = .{ .integer = .{
        .value = 7,
        .span = .{ .start = 0, .end = 0 },
    } };

    const construct_value = try allocator.create(model.Expr);
    construct_value.* = .{ .construct = .{
        .type_name = "Example",
        .fields = &.{.{
            .field_name = "b",
            .field_index = 1,
            .value = field_value,
            .span = .{ .start = 0, .end = 0 },
        }},
        .fill_mode = .zeroed_ffi_c_layout,
        .ty = .{ .kind = .named, .name = "Example" },
        .span = .{ .start = 0, .end = 0 },
    } };

    const program = model.Program{
        .imports = &.{},
        .annotations = &.{},
        .capabilities = &.{},
        .constructs = &.{},
        .types = &.{.{
            .name = "Example",
            .fields = &.{
                .{ .name = "a", .owner_type_name = "Example", .storage = .mutable, .slot_index = 0, .ty = .{ .kind = .integer, .name = "U8" }, .explicit_type = true, .default_value = null, .annotations = &.{}, .span = .{ .start = 0, .end = 0 } },
                .{ .name = "b", .owner_type_name = "Example", .storage = .mutable, .slot_index = 1, .ty = .{ .kind = .integer, .name = "U8" }, .explicit_type = true, .default_value = null, .annotations = &.{}, .span = .{ .start = 0, .end = 0 } },
                .{ .name = "c", .owner_type_name = "Example", .storage = .mutable, .slot_index = 2, .ty = .{ .kind = .integer, .name = "U8" }, .explicit_type = true, .default_value = null, .annotations = &.{}, .span = .{ .start = 0, .end = 0 } },
            },
            .ffi = .{ .ffi_struct = .{ .layout = "c", .span = .{ .start = 0, .end = 0 } } },
            .span = .{ .start = 0, .end = 0 },
        }},
        .forms = &.{},
        .functions = &.{.{
            .id = 0,
            .name = "entry",
            .is_main = true,
            .execution = .runtime,
            .is_extern = false,
            .foreign = null,
            .annotations = &.{},
            .params = &.{},
            .locals = &.{.{ .id = 0, .name = "value", .ty = .{ .kind = .named, .name = "Example" }, .span = .{ .start = 0, .end = 0 } }},
            .return_type = .{ .kind = .void },
            .body = &.{
                .{ .let_stmt = .{ .local_id = 0, .ty = .{ .kind = .named, .name = "Example" }, .explicit_type = false, .value = construct_value, .span = .{ .start = 0, .end = 0 } } },
                .{ .return_stmt = .{ .value = null, .span = .{ .start = 0, .end = 0 } } },
            },
            .span = .{ .start = 0, .end = 0 },
        }},
        .entry_index = 0,
    };

    const lowered = try lowerProgram(allocator, program);
    const instructions = lowered.functions[0].instructions;

    var saw_field_b = false;
    var touched_other_field = false;
    for (instructions) |instruction| {
        if (instruction != .field_ptr) continue;
        if (instruction.field_ptr.field_index == 1) {
            saw_field_b = true;
        } else {
            touched_other_field = true;
        }
    }

    try std.testing.expect(saw_field_b);
    try std.testing.expect(!touched_other_field);
}

test "parallel root-function lowering preserves deterministic callback ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const callback_ty: model.ResolvedType = .{ .kind = .callback, .name = "Callback" };

    const callback_body = &.{model.Statement{
        .return_stmt = .{ .value = null, .span = .{ .start = 0, .end = 0 } },
    }};

    const callback_exprs = try allocator.alloc(*model.Expr, 4);
    for (callback_exprs) |*slot| {
        const expr = try allocator.create(model.Expr);
        expr.* = .{ .callback = .{
            .params = &.{},
            .captures = &.{},
            .locals = &.{},
            .body = callback_body,
            .return_type = .{ .kind = .void },
            .ty = callback_ty,
            .span = .{ .start = 0, .end = 0 },
        } };
        slot.* = expr;
    }

    const call_exprs = try allocator.alloc(*model.Expr, 3);
    for (call_exprs, 0..) |*slot, index| {
        const expr = try allocator.create(model.Expr);
        expr.* = .{ .call = .{
            .callee_name = switch (index) {
                0 => "helper_one",
                1 => "helper_two",
                else => "helper_three",
            },
            .function_id = @as(u32, @intCast(index + 1)),
            .args = &.{},
            .ty = .{ .kind = .void },
            .span = .{ .start = 0, .end = 0 },
        } };
        slot.* = expr;
    }

    const callback_local: model.LocalSymbol = .{
        .id = 0,
        .name = "cb",
        .ty = callback_ty,
        .span = .{ .start = 0, .end = 0 },
    };

    const entry_body = &.{
        model.Statement{ .let_stmt = .{
            .local_id = 0,
            .ty = callback_ty,
            .explicit_type = false,
            .value = callback_exprs[0],
            .span = .{ .start = 0, .end = 0 },
        } },
        model.Statement{ .expr_stmt = .{ .expr = call_exprs[0], .span = .{ .start = 0, .end = 0 } } },
        model.Statement{ .expr_stmt = .{ .expr = call_exprs[1], .span = .{ .start = 0, .end = 0 } } },
        model.Statement{ .expr_stmt = .{ .expr = call_exprs[2], .span = .{ .start = 0, .end = 0 } } },
        model.Statement{ .return_stmt = .{ .value = null, .span = .{ .start = 0, .end = 0 } } },
    };

    const helper_one_body = &.{
        model.Statement{ .let_stmt = .{
            .local_id = 0,
            .ty = callback_ty,
            .explicit_type = false,
            .value = callback_exprs[1],
            .span = .{ .start = 0, .end = 0 },
        } },
        model.Statement{ .return_stmt = .{ .value = null, .span = .{ .start = 0, .end = 0 } } },
    };
    const helper_two_body = &.{
        model.Statement{ .let_stmt = .{
            .local_id = 0,
            .ty = callback_ty,
            .explicit_type = false,
            .value = callback_exprs[2],
            .span = .{ .start = 0, .end = 0 },
        } },
        model.Statement{ .return_stmt = .{ .value = null, .span = .{ .start = 0, .end = 0 } } },
    };
    const helper_three_body = &.{
        model.Statement{ .let_stmt = .{
            .local_id = 0,
            .ty = callback_ty,
            .explicit_type = false,
            .value = callback_exprs[3],
            .span = .{ .start = 0, .end = 0 },
        } },
        model.Statement{ .return_stmt = .{ .value = null, .span = .{ .start = 0, .end = 0 } } },
    };

    const program = model.Program{
        .imports = &.{},
        .annotations = &.{},
        .capabilities = &.{},
        .constructs = &.{},
        .types = &.{},
        .forms = &.{},
        .functions = &.{
            .{
                .id = 0,
                .name = "entry",
                .is_main = true,
                .execution = .runtime,
                .annotations = &.{},
                .params = &.{},
                .locals = &.{callback_local},
                .return_type = .{ .kind = .void },
                .body = entry_body,
                .span = .{ .start = 0, .end = 0 },
            },
            .{
                .id = 1,
                .name = "helper_one",
                .is_main = false,
                .execution = .runtime,
                .annotations = &.{},
                .params = &.{},
                .locals = &.{callback_local},
                .return_type = .{ .kind = .void },
                .body = helper_one_body,
                .span = .{ .start = 0, .end = 0 },
            },
            .{
                .id = 2,
                .name = "helper_two",
                .is_main = false,
                .execution = .runtime,
                .annotations = &.{},
                .params = &.{},
                .locals = &.{callback_local},
                .return_type = .{ .kind = .void },
                .body = helper_two_body,
                .span = .{ .start = 0, .end = 0 },
            },
            .{
                .id = 3,
                .name = "helper_three",
                .is_main = false,
                .execution = .runtime,
                .annotations = &.{},
                .params = &.{},
                .locals = &.{callback_local},
                .return_type = .{ .kind = .void },
                .body = helper_three_body,
                .span = .{ .start = 0, .end = 0 },
            },
        },
        .entry_index = 0,
    };

    const lowered = try lowerProgramWithOptions(allocator, program, .{ .worker_count_override = 2 });
    try std.testing.expectEqual(@as(usize, 8), lowered.functions.len);
    try std.testing.expectEqual(@as(usize, 0), lowered.entry_index);

    for (lowered.functions[0..4], 0..) |function_decl, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), function_decl.id);
    }
    for (lowered.functions[4..], 0..) |function_decl, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index + 4)), function_decl.id);
    }
}
