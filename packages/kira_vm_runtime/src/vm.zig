const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const builtins = @import("builtins.zig");

pub const NativeCallHook = *const fn (?*anyopaque, u32, []const runtime_abi.Value) anyerror!runtime_abi.Value;

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
        _ = try self.runFunctionById(module, entry_function_id, &.{}, writer, .{});
    }

    pub fn runFunctionById(
        self: *Vm,
        module: *const bytecode.Module,
        function_id: u32,
        args: []const runtime_abi.Value,
        writer: anytype,
        hooks: Hooks,
    ) anyerror!runtime_abi.Value {
        const function_decl = module.findFunctionById(function_id) orelse {
            self.rememberError("bytecode function id is out of range");
            return error.RuntimeFailure;
        };
        return self.runFunction(module, function_decl, args, writer, hooks);
    }

    pub fn lastError(self: *const Vm) ?[]const u8 {
        if (self.last_error_len == 0) return null;
        return self.last_error_buffer[0..self.last_error_len];
    }

    fn runFunction(
        self: *Vm,
        module: *const bytecode.Module,
        function_decl: bytecode.Function,
        args: []const runtime_abi.Value,
        writer: anytype,
        hooks: Hooks,
    ) anyerror!runtime_abi.Value {
        const registers = try self.allocator.alloc(runtime_abi.Value, function_decl.register_count);
        defer self.allocator.free(registers);
        const locals = try self.allocator.alloc(runtime_abi.Value, function_decl.local_count);
        defer self.allocator.free(locals);

        for (registers) |*slot| slot.* = .{ .void = {} };
        for (locals) |*slot| slot.* = .{ .void = {} };
        for (function_decl.local_types, 0..) |local_ty, index| {
            if (local_ty.kind != .ffi_struct) continue;
            const type_name = local_ty.name orelse {
                self.rememberError("struct local type is missing a name");
                return error.RuntimeFailure;
            };
            locals[index] = .{ .raw_ptr = try self.allocateStruct(module, type_name) };
        }
        if (args.len != function_decl.param_count) {
            self.rememberError("bytecode function call used the wrong number of arguments");
            return error.RuntimeFailure;
        }
        for (args, 0..) |arg, index| {
            locals[index] = arg;
        }

        for (function_decl.instructions) |inst| {
            switch (inst) {
                .const_int => |value| registers[value.dst] = .{ .integer = value.value },
                .const_string => |value| registers[value.dst] = .{ .string = value.value },
                .const_bool => |value| registers[value.dst] = .{ .boolean = value.value },
                .const_null_ptr => |value| registers[value.dst] = .{ .raw_ptr = 0 },
                .alloc_struct => |value| registers[value.dst] = .{ .raw_ptr = try self.allocateStruct(module, value.type_name) },
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
                .field_ptr => |value| {
                    const base = registers[value.base];
                    if (base != .raw_ptr or base.raw_ptr == 0) {
                        self.rememberError("field access requires a valid struct pointer");
                        return error.RuntimeFailure;
                    }
                    const field_index = self.fieldIndex(module, value.owner_type_name, value.field_name) orelse {
                        self.rememberError("struct field could not be resolved");
                        return error.RuntimeFailure;
                    };
                    const base_ptr: [*]runtime_abi.Value = @ptrFromInt(base.raw_ptr);
                    registers[value.dst] = .{ .raw_ptr = @intFromPtr(&base_ptr[field_index]) };
                },
                .load_indirect => |value| {
                    const ptr = registers[value.ptr];
                    if (ptr != .raw_ptr or ptr.raw_ptr == 0) {
                        self.rememberError("indirect load requires a valid pointer");
                        return error.RuntimeFailure;
                    }
                    const slot_ptr: *runtime_abi.Value = @ptrFromInt(ptr.raw_ptr);
                    registers[value.dst] = slot_ptr.*;
                    _ = value.ty;
                },
                .store_indirect => |value| {
                    const ptr = registers[value.ptr];
                    if (ptr != .raw_ptr or ptr.raw_ptr == 0) {
                        self.rememberError("indirect store requires a valid pointer");
                        return error.RuntimeFailure;
                    }
                    const slot_ptr: *runtime_abi.Value = @ptrFromInt(ptr.raw_ptr);
                    slot_ptr.* = registers[value.src];
                    _ = value.ty;
                },
                .copy_indirect => |value| {
                    const dst_ptr_value = registers[value.dst_ptr];
                    const src_ptr_value = registers[value.src_ptr];
                    if (dst_ptr_value != .raw_ptr or src_ptr_value != .raw_ptr or dst_ptr_value.raw_ptr == 0 or src_ptr_value.raw_ptr == 0) {
                        self.rememberError("struct copy requires valid pointers");
                        return error.RuntimeFailure;
                    }
                    const field_count = self.typeFieldCount(module, value.type_name) orelse {
                        self.rememberError("struct type could not be resolved");
                        return error.RuntimeFailure;
                    };
                    const dst_ptr: [*]runtime_abi.Value = @ptrFromInt(dst_ptr_value.raw_ptr);
                    const src_ptr: [*]runtime_abi.Value = @ptrFromInt(src_ptr_value.raw_ptr);
                    for (0..field_count) |index| dst_ptr[index] = src_ptr[index];
                },
                .print => |value| try builtins.printValue(writer, module, registers[value.src], value.ty),
                .call_runtime => |value| {
                    const call_args = try collectArgs(self.allocator, registers, value.args);
                    defer self.allocator.free(call_args);
                    const result = try self.runFunctionById(module, value.function_id, call_args, writer, hooks);
                    if (value.dst) |dst| registers[dst] = result;
                },
                .call_native => |value| {
                    const callback = hooks.call_native orelse {
                        self.rememberError("vm native bridge was not installed");
                        return error.RuntimeFailure;
                    };
                    const call_args = try collectArgs(self.allocator, registers, value.args);
                    defer self.allocator.free(call_args);
                    const result = try callback(hooks.context, value.function_id, call_args);
                    if (value.dst) |dst| registers[dst] = result;
                },
                .ret => |value| return if (value.src) |src| registers[src] else .{ .void = {} },
            }
        }
        return .{ .void = {} };
    }

    fn rememberError(self: *Vm, message: []const u8) void {
        const length = @min(message.len, self.last_error_buffer.len);
        @memcpy(self.last_error_buffer[0..length], message[0..length]);
        self.last_error_len = length;
    }

    fn allocateStruct(self: *Vm, module: *const bytecode.Module, type_name: []const u8) !usize {
        const field_count = self.typeFieldCount(module, type_name) orelse {
            self.rememberError("struct type could not be resolved");
            return error.RuntimeFailure;
        };
        const fields = try self.allocator.alloc(runtime_abi.Value, field_count);
        for (fields) |*slot| slot.* = .{ .void = {} };
        return @intFromPtr(fields.ptr);
    }

    fn typeFieldCount(self: *Vm, module: *const bytecode.Module, type_name: []const u8) ?usize {
        _ = self;
        const type_decl = findType(module, type_name) orelse return null;
        return type_decl.fields.len;
    }

    fn fieldIndex(self: *Vm, module: *const bytecode.Module, type_name: []const u8, field_name: []const u8) ?usize {
        _ = self;
        const type_decl = findType(module, type_name) orelse return null;
        for (type_decl.fields, 0..) |field_decl, index| {
            if (std.mem.eql(u8, field_decl.name, field_name)) return index;
        }
        return null;
    }
};

fn collectArgs(allocator: std.mem.Allocator, registers: []const runtime_abi.Value, argument_registers: []const u32) ![]runtime_abi.Value {
    const values = try allocator.alloc(runtime_abi.Value, argument_registers.len);
    for (argument_registers, 0..) |register_index, index| {
        values[index] = registers[register_index];
    }
    return values;
}

fn findType(module: *const bytecode.Module, name: []const u8) ?bytecode.TypeDecl {
    for (module.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
    }
    return null;
}

test "executes nested runtime calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
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
                    .{ .call_runtime = .{ .function_id = 1 } },
                    .{ .ret = .{ .src = null } },
                },
            },
            .{
                .id = 1,
                .name = "helper",
                .param_count = 0,
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{
                    .{ .const_int = .{ .dst = 0, .value = 42 } },
                    .{ .print = .{ .src = 0, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .ret = .{ .src = null } },
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

test "prints struct values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
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
                .register_count = 8,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Color" } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .owner_type_name = "Color", .field_name = "r" } },
                    .{ .const_int = .{ .dst = 2, .value = 255 } },
                    .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .field_ptr = .{ .dst = 3, .base = 0, .owner_type_name = "Color", .field_name = "g" } },
                    .{ .const_int = .{ .dst = 4, .value = 0 } },
                    .{ .store_indirect = .{ .ptr = 3, .src = 4, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .field_ptr = .{ .dst = 5, .base = 0, .owner_type_name = "Color", .field_name = "b" } },
                    .{ .const_int = .{ .dst = 6, .value = 0 } },
                    .{ .store_indirect = .{ .ptr = 5, .src = 6, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .print = .{ .src = 0, .ty = .{ .kind = .ffi_struct, .name = "Color" } } },
                    .{ .ret = .{ .src = null } },
                },
            },
        },
        .entry_function_id = 0,
    };

    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try vm.runMain(&module, stream.writer());
    try std.testing.expectEqualStrings("Color(r: 255, g: 0, b: 0)\n", stream.getWritten());
}
