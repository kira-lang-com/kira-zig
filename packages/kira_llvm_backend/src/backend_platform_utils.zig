const std = @import("std");
const builtin = @import("builtin");
const ir = @import("kira_ir");
const runtime_abi = @import("kira_runtime_abi");
const backend_api = @import("kira_backend_api");

pub fn resolveExecution(execution: runtime_abi.FunctionExecution, mode: backend_api.BackendMode) runtime_abi.FunctionExecution {
    return switch (execution) {
        .inherited => switch (mode) {
            .llvm_native => .native,
            .hybrid => .runtime,
            .vm_bytecode => .runtime,
        },
        else => execution,
    };
}

pub fn requiresTextIrFallback(
    shouldLowerFunction: fn (runtime_abi.FunctionExecution, backend_api.BackendMode) bool,
    functionExecutionById: fn (ir.Program, u32) ?runtime_abi.FunctionExecution,
    program: ir.Program,
    mode: backend_api.BackendMode,
) bool {
    if (mode == .vm_bytecode) return false;

    for (program.functions) |function_decl| {
        if (!shouldLowerFunction(function_decl.execution, mode)) continue;
        if (functionDeclNeedsTextIrFallback(shouldLowerFunction, functionExecutionById, program, function_decl, mode)) return true;
    }
    return false;
}

pub fn functionDeclNeedsTextIrFallback(
    shouldLowerFunction: fn (runtime_abi.FunctionExecution, backend_api.BackendMode) bool,
    functionExecutionById: fn (ir.Program, u32) ?runtime_abi.FunctionExecution,
    program: ir.Program,
    function_decl: ir.Function,
    mode: backend_api.BackendMode,
) bool {
    _ = shouldLowerFunction;
    if (function_decl.is_extern) return true;
    if (function_decl.param_types.len != 0) return true;
    if (function_decl.return_type.kind != .void) return true;

    for (function_decl.local_types) |local_type| {
        if (local_type.kind == .ffi_struct or local_type.kind == .array or local_type.kind == .enum_instance) return true;
    }

    for (function_decl.instructions) |instruction| {
        switch (instruction) {
            .const_int, .const_string, .const_bool, .const_null_ptr, .add, .subtract, .multiply, .divide, .modulo, .unary, .store_local, .load_local, .local_ptr => {},
            .const_float => return true,
            .compare, .branch, .jump, .label => return true,
            .alloc_struct, .alloc_enum, .alloc_native_state, .alloc_array, .const_function, .const_closure, .subobject_ptr, .field_ptr, .recover_native_state, .native_state_field_get, .native_state_field_set, .array_len, .array_get, .array_set, .enum_tag, .enum_payload, .load_indirect, .store_indirect, .copy_indirect => return true,
            .print => |value| if (value.ty.kind != .integer and value.ty.kind != .string and value.ty.kind != .float and value.ty.kind != .enum_instance) return true,
            .call => |value| {
                if (value.args.len != 0 or value.dst != null) return true;
                const callee_execution = functionExecutionById(program, value.callee) orelse return true;
                if (resolveExecution(callee_execution, mode) == .runtime and mode != .hybrid) return true;
            },
            .call_value => return true,
            .ret => |value| if (value.src != null) return true,
        }
    }

    return false;
}

pub fn hostTargetTriple(allocator: std.mem.Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => allocator.dupe(u8, if (builtin.abi == .gnu) "x86_64-pc-windows-gnu" else "x86_64-pc-windows-msvc"),
            else => error.UnsupportedTarget,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => allocator.dupe(u8, "x86_64-pc-linux-gnu"),
            else => error.UnsupportedTarget,
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => allocator.dupe(u8, "arm64-apple-macosx"),
            else => error.UnsupportedTarget,
        },
        else => error.UnsupportedTarget,
    };
}

pub fn ensureParentDir(path: []const u8) !void {
    const maybe_dir = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, maybe_dir);
}

pub fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const rendered = try std.fmt.allocPrint(allocator, fmt, args);
    return allocator.dupeZ(u8, rendered);
}

test "detects fallback features for llvm c api lowering" {
    const program = ir.Program{
        .types = &.{},
        .functions = &.{
            .{
                .id = 0,
                .name = "main",
                .execution = .native,
                .param_types = &.{},
                .return_type = .{ .kind = .void },
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{
                    .{ .const_function = .{ .dst = 0, .function_id = 1 } },
                    .{ .ret = .{ .src = null } },
                },
            },
            .{
                .id = 1,
                .name = "callback",
                .execution = .native,
                .param_types = &.{},
                .return_type = .{ .kind = .void },
                .register_count = 0,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{.{ .ret = .{ .src = null } }},
            },
        },
        .entry_index = 0,
    };

    try std.testing.expect(requiresTextIrFallback(dummyShouldLowerFunction, dummyFunctionExecutionById, program, .llvm_native));
}

fn dummyShouldLowerFunction(execution: runtime_abi.FunctionExecution, mode: backend_api.BackendMode) bool {
    _ = mode;
    return execution != .runtime;
}

fn dummyFunctionExecutionById(program: ir.Program, function_id: u32) ?runtime_abi.FunctionExecution {
    for (program.functions) |function_decl| {
        if (function_decl.id == function_id) return function_decl.execution;
    }
    return null;
}
