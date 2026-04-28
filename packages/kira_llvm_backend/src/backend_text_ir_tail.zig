const std = @import("std");
const ir = @import("kira_ir");
const backend_api = @import("kira_backend_api");
const core = @import("backend_text_ir_core.zig");
const writeLlvmSymbol = @import("backend.zig").writeLlvmSymbol;

pub fn buildTextMainBody(
    allocator: std.mem.Allocator,
    entry_function_name: []const u8,
) ![]const u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    errdefer body.deinit();

    var writer = &body.writer;
    try writer.writeAll("define i32 @main() {\nentry:\n");
    try writer.writeAll("  call void ");
    try writeLlvmSymbol(writer, entry_function_name);
    try writer.writeAll("()\n  ret i32 0\n}\n");
    return body.toOwnedSlice();
}

test "emits native state helper calls in text llvm ir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var program = ir.Program{
        .types = &.{.{
            .name = "CounterState",
            .fields = &.{.{ .name = "count", .ty = .{ .kind = .integer, .name = "I64" } }},
        }},
        .functions = &.{.{
            .id = 0,
            .name = "main",
            .execution = .native,
            .param_types = &.{},
            .return_type = .{ .kind = .void },
            .register_count = 3,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &.{
                .{ .alloc_struct = .{ .dst = 0, .type_name = "CounterState" } },
                .{ .alloc_native_state = .{ .dst = 1, .src = 0, .type_name = "CounterState", .type_id = 77 } },
                .{ .recover_native_state = .{ .dst = 2, .state = 1, .type_name = "CounterState", .type_id = 77 } },
                .{ .ret = .{ .src = null } },
            },
        }},
        .entry_index = 0,
    };
    const request = backend_api.CompileRequest{
        .mode = .llvm_native,
        .program = &program,
        .module_name = "native_state_test",
        .emit = .{
            .object_path = "dummy.obj",
        },
    };

    const text = try core.buildTextLlvmIr(allocator, request, "x86_64-pc-windows-msvc");
    try std.testing.expect(std.mem.indexOf(u8, text, "kira_native_state_alloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "kira_native_state_recover") != null);
}

test "native state ffi struct field writes copy assigned values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var program = ir.Program{
        .types = &.{
            .{
                .name = "Handle",
                .fields = &.{.{ .name = "id", .ty = .{ .kind = .integer, .name = "I32" } }},
                .ffi = .ffi_struct,
            },
            .{
                .name = "AppState",
                .fields = &.{.{ .name = "handle", .ty = .{ .kind = .ffi_struct, .name = "Handle" } }},
            },
        },
        .functions = &.{.{
            .id = 0,
            .name = "main",
            .execution = .native,
            .param_types = &.{},
            .return_type = .{ .kind = .void },
            .register_count = 4,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &.{
                .{ .alloc_struct = .{ .dst = 0, .type_name = "AppState" } },
                .{ .alloc_native_state = .{ .dst = 1, .src = 0, .type_name = "AppState", .type_id = 77 } },
                .{ .recover_native_state = .{ .dst = 2, .state = 1, .type_name = "AppState", .type_id = 77 } },
                .{ .alloc_struct = .{ .dst = 3, .type_name = "Handle" } },
                .{ .native_state_field_set = .{
                    .state = 2,
                    .field_index = 0,
                    .src = 3,
                    .field_ty = .{ .kind = .ffi_struct, .name = "Handle" },
                } },
                .{ .ret = .{ .src = null } },
            },
        }},
        .entry_index = 0,
    };
    const request = backend_api.CompileRequest{
        .mode = .llvm_native,
        .program = &program,
        .module_name = "native_state_ffi_set_test",
        .emit = .{
            .object_path = "dummy.obj",
        },
    };

    const text = try core.buildTextLlvmIr(allocator, request, "x86_64-pc-windows-msvc");
    try std.testing.expect(std.mem.indexOf(u8, text, "native.state.set.struct.copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "native.state.set.struct.ptrint") != null);
}
