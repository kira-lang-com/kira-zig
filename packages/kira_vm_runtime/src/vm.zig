const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const builtins = @import("builtins.zig");

pub const NativeCallHook = *const fn (?*anyopaque, u32) anyerror!void;

pub const Hooks = struct {
    context: ?*anyopaque = null,
    call_native: ?NativeCallHook = null,
};

pub const Vm = struct {
    allocator: std.mem.Allocator,
    last_error_buffer: [256]u8 = [_]u8{0} ** 256,
    last_error_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Vm {
        return .{ .allocator = allocator };
    }

    pub fn runMain(self: *Vm, module: *const bytecode.Module, writer: anytype) anyerror!void {
        const entry_function_id = module.entry_function_id orelse {
            self.rememberError("bytecode module has no runtime entrypoint");
            return error.RuntimeFailure;
        };
        try self.runFunctionById(module, entry_function_id, writer, .{});
    }

    pub fn runFunctionById(self: *Vm, module: *const bytecode.Module, function_id: u32, writer: anytype, hooks: Hooks) anyerror!void {
        const function_decl = module.findFunctionById(function_id) orelse {
            self.rememberError("bytecode function id is out of range");
            return error.RuntimeFailure;
        };
        try self.runFunction(module, function_decl, writer, hooks);
    }

    pub fn lastError(self: *const Vm) ?[]const u8 {
        if (self.last_error_len == 0) return null;
        return self.last_error_buffer[0..self.last_error_len];
    }

    fn runFunction(self: *Vm, module: *const bytecode.Module, function_decl: bytecode.Function, writer: anytype, hooks: Hooks) anyerror!void {
        const registers = try self.allocator.alloc(runtime_abi.Value, function_decl.register_count);
        defer self.allocator.free(registers);
        const locals = try self.allocator.alloc(runtime_abi.Value, function_decl.local_count);
        defer self.allocator.free(locals);

        for (registers) |*slot| slot.* = .{ .void = {} };
        for (locals) |*slot| slot.* = .{ .void = {} };

        for (function_decl.instructions) |inst| {
            switch (inst) {
                .const_int => |value| registers[value.dst] = .{ .integer = value.value },
                .const_string => |value| registers[value.dst] = .{ .string = value.value },
                .add => |value| {
                    const lhs = registers[value.lhs];
                    const rhs = registers[value.rhs];
                    if (lhs != .integer or rhs != .integer) {
                        self.rememberError("vm add expects integer operands");
                        return error.RuntimeFailure;
                    }
                    registers[value.dst] = .{ .integer = lhs.integer + rhs.integer };
                },
                .store_local => |value| locals[value.local] = registers[value.src],
                .load_local => |value| registers[value.dst] = locals[value.local],
                .print => |value| try builtins.printValue(writer, registers[value.src]),
                .call_runtime => |value| try self.runFunctionById(module, value.function_id, writer, hooks),
                .call_native => |value| {
                    const callback = hooks.call_native orelse {
                        self.rememberError("vm native bridge was not installed");
                        return error.RuntimeFailure;
                    };
                    try callback(hooks.context, value.function_id);
                },
                .ret_void => return,
            }
        }
    }

    fn rememberError(self: *Vm, message: []const u8) void {
        const length = @min(message.len, self.last_error_buffer.len);
        @memcpy(self.last_error_buffer[0..length], message[0..length]);
        self.last_error_len = length;
    }
};

test "executes nested runtime calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .functions = &.{
            .{
                .id = 0,
                .name = "main",
                .register_count = 1,
                .local_count = 0,
                .instructions = &.{
                    .{ .call_runtime = .{ .function_id = 1 } },
                    .{ .ret_void = {} },
                },
            },
            .{
                .id = 1,
                .name = "helper",
                .register_count = 1,
                .local_count = 0,
                .instructions = &.{
                    .{ .const_int = .{ .dst = 0, .value = 42 } },
                    .{ .print = .{ .src = 0 } },
                    .{ .ret_void = {} },
                },
            },
        },
        .entry_function_id = 0,
    };

    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try vm.runMain(&module, stream.writer());
    try std.testing.expectEqualStrings("42\n", stream.getWritten());
}
