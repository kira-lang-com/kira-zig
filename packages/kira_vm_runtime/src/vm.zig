const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const builtins = @import("builtins.zig");

const ArrayObject = extern struct {
    len: usize,
    items: [*]runtime_abi.BridgeValue,
};

const NativeStateBox = extern struct {
    type_id: u64,
    payload: usize,
};

pub const NativeCallHook = *const fn (?*anyopaque, u32, []const runtime_abi.Value) anyerror!runtime_abi.Value;
pub const ResolveFunctionHook = *const fn (?*anyopaque, u32) anyerror!usize;

pub const Hooks = struct {
    context: ?*anyopaque = null,
    call_native: ?NativeCallHook = null,
    resolve_function: ?ResolveFunctionHook = null,
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
        const label_offsets = try buildLabelOffsets(self.allocator, function_decl.instructions);
        defer self.allocator.free(label_offsets);

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
            if (function_decl.local_types[index].kind == .ffi_struct) {
                if (arg != .raw_ptr or arg.raw_ptr == 0) {
                    self.rememberError("struct argument requires a valid pointer");
                    return error.RuntimeFailure;
                }
                const type_name = function_decl.local_types[index].name orelse {
                    self.rememberError("struct local type is missing a name");
                    return error.RuntimeFailure;
                };
                const type_decl = findType(module, type_name) orelse {
                    self.rememberError("struct type could not be resolved");
                    return error.RuntimeFailure;
                };
                const dst_ptr: [*]runtime_abi.Value = @ptrFromInt(locals[index].raw_ptr);
                const src_ptr: [*]runtime_abi.Value = @ptrFromInt(arg.raw_ptr);
                try self.copyStruct(module, type_decl, dst_ptr, src_ptr);
            } else {
                locals[index] = arg;
            }
        }

        var pc: usize = 0;
        while (pc < function_decl.instructions.len) {
            const inst = function_decl.instructions[pc];
            switch (inst) {
                .const_int => |value| registers[value.dst] = .{ .integer = value.value },
                .const_float => |value| registers[value.dst] = .{ .float = value.value },
                .const_string => |value| registers[value.dst] = .{ .string = value.value },
                .const_bool => |value| registers[value.dst] = .{ .boolean = value.value },
                .const_null_ptr => |value| registers[value.dst] = .{ .raw_ptr = 0 },
                .const_function => |value| registers[value.dst] = .{ .raw_ptr = switch (value.representation) {
                    .callable_value => value.function_id,
                    .native_callback => if (hooks.resolve_function) |resolve_function|
                        try resolveFunctionPointer(hooks, resolve_function, value.function_id)
                    else
                        value.function_id,
                } },
                .alloc_struct => |value| registers[value.dst] = .{ .raw_ptr = try self.allocateStruct(module, value.type_name) },
                .alloc_native_state => |value| {
                    const src_value = registers[value.src];
                    if (src_value != .raw_ptr or src_value.raw_ptr == 0) {
                        self.rememberError("nativeState requires a valid Kira struct value");
                        return error.RuntimeFailure;
                    }
                    registers[value.dst] = .{ .raw_ptr = try self.allocateNativeState(module, value.type_name, value.type_id, src_value.raw_ptr) };
                },
                .alloc_array => |value| {
                    const len_value = registers[value.len];
                    if (len_value != .integer or len_value.integer < 0) {
                        self.rememberError("array allocation requires a non-negative integer length");
                        return error.RuntimeFailure;
                    }
                    registers[value.dst] = .{ .raw_ptr = try self.allocateArray(@intCast(len_value.integer)) };
                },
                .add => |value| {
                    const lhs = registers[value.lhs];
                    const rhs = registers[value.rhs];
                    registers[value.dst] = try self.addValues(lhs, rhs);
                },
                .subtract => |value| {
                    const lhs = registers[value.lhs];
                    const rhs = registers[value.rhs];
                    registers[value.dst] = try self.subtractValues(lhs, rhs);
                },
                .multiply => |value| {
                    const lhs = registers[value.lhs];
                    const rhs = registers[value.rhs];
                    registers[value.dst] = try self.multiplyValues(lhs, rhs);
                },
                .divide => |value| {
                    const lhs = registers[value.lhs];
                    const rhs = registers[value.rhs];
                    registers[value.dst] = try self.divideValues(lhs, rhs);
                },
                .modulo => |value| {
                    const lhs = registers[value.lhs];
                    const rhs = registers[value.rhs];
                    registers[value.dst] = try self.moduloValues(lhs, rhs);
                },
                .compare => |value| {
                    registers[value.dst] = .{ .boolean = try self.compareValues(registers[value.lhs], registers[value.rhs], value.op) };
                },
                .unary => |value| {
                    registers[value.dst] = try self.unaryValue(registers[value.src], value.op);
                },
                .store_local => |value| locals[value.local] = registers[value.src],
                .load_local => |value| registers[value.dst] = locals[value.local],
                .subobject_ptr => |value| {
                    const base = registers[value.base];
                    if (base != .raw_ptr or base.raw_ptr == 0) {
                        self.rememberError("subobject access requires a valid struct pointer");
                        return error.RuntimeFailure;
                    }
                    const base_ptr: [*]runtime_abi.Value = @ptrFromInt(base.raw_ptr);
                    registers[value.dst] = .{ .raw_ptr = @intFromPtr(base_ptr + value.offset) };
                },
                .field_ptr => |value| {
                    const base = registers[value.base];
                    if (base != .raw_ptr or base.raw_ptr == 0) {
                        self.rememberError("field access requires a valid struct pointer");
                        return error.RuntimeFailure;
                    }
                    const base_ptr: [*]runtime_abi.Value = @ptrFromInt(base.raw_ptr);
                    const field_index: usize = @intCast(value.field_index);
                    const slot_ptr = base_ptr + field_index;
                    if (value.field_ty.kind == .ffi_struct) {
                        if (slot_ptr[0] != .raw_ptr or slot_ptr[0].raw_ptr == 0) {
                            self.rememberError("nested struct field storage is invalid");
                            return error.RuntimeFailure;
                        }
                        registers[value.dst] = .{ .raw_ptr = slot_ptr[0].raw_ptr };
                    } else {
                        registers[value.dst] = .{ .raw_ptr = @intFromPtr(slot_ptr) };
                    }
                },
                .recover_native_state => |value| {
                    const state_value = registers[value.state];
                    if (state_value != .raw_ptr or state_value.raw_ptr == 0) {
                        self.rememberError("nativeRecover requires a valid native state token");
                        return error.RuntimeFailure;
                    }
                    registers[value.dst] = .{ .raw_ptr = try self.recoverNativeState(state_value.raw_ptr, value.type_id) };
                    _ = value.type_name;
                },
                .native_state_field_get => |value| {
                    const state_value = registers[value.state];
                    if (state_value != .raw_ptr or state_value.raw_ptr == 0) {
                        self.rememberError("native state field read requires a valid recovered state");
                        return error.RuntimeFailure;
                    }
                    const payload: [*]const runtime_abi.BridgeValue = @ptrFromInt(state_value.raw_ptr);
                    registers[value.dst] = runtime_abi.bridgeValueToValue(payload[@intCast(value.field_index)]);
                    _ = value.field_ty;
                },
                .native_state_field_set => |value| {
                    const state_value = registers[value.state];
                    if (state_value != .raw_ptr or state_value.raw_ptr == 0) {
                        self.rememberError("native state field write requires a valid recovered state");
                        return error.RuntimeFailure;
                    }
                    const payload: [*]runtime_abi.BridgeValue = @ptrFromInt(state_value.raw_ptr);
                    payload[@intCast(value.field_index)] = runtime_abi.bridgeValueFromValue(registers[value.src]);
                    _ = value.field_ty;
                },
                .array_len => |value| {
                    const array_value = registers[value.array];
                    if (array_value != .raw_ptr or array_value.raw_ptr == 0) {
                        self.rememberError("array length requires a valid array handle");
                        return error.RuntimeFailure;
                    }
                    const array_ptr: *const ArrayObject = @ptrFromInt(array_value.raw_ptr);
                    registers[value.dst] = .{ .integer = @intCast(array_ptr.len) };
                },
                .array_get => |value| {
                    const array_value = registers[value.array];
                    const index_value = registers[value.index];
                    if (array_value != .raw_ptr or array_value.raw_ptr == 0 or index_value != .integer or index_value.integer < 0) {
                        self.rememberError("array load requires a valid array handle and index");
                        return error.RuntimeFailure;
                    }
                    const array_ptr: *const ArrayObject = @ptrFromInt(array_value.raw_ptr);
                    const index: usize = @intCast(index_value.integer);
                    if (index >= array_ptr.len) {
                        self.rememberError("array index is out of bounds");
                        return error.RuntimeFailure;
                    }
                    registers[value.dst] = runtime_abi.bridgeValueToValue(array_ptr.items[index]);
                    _ = value.ty;
                },
                .array_set => |value| {
                    const array_value = registers[value.array];
                    const index_value = registers[value.index];
                    if (array_value != .raw_ptr or array_value.raw_ptr == 0 or index_value != .integer or index_value.integer < 0) {
                        self.rememberError("array store requires a valid array handle and index");
                        return error.RuntimeFailure;
                    }
                    const array_ptr: *ArrayObject = @ptrFromInt(array_value.raw_ptr);
                    const index: usize = @intCast(index_value.integer);
                    if (index >= array_ptr.len) {
                        self.rememberError("array index is out of bounds");
                        return error.RuntimeFailure;
                    }
                    array_ptr.items[index] = runtime_abi.bridgeValueFromValue(registers[value.src]);
                },
                .load_indirect => |value| {
                    const ptr = registers[value.ptr];
                    if (ptr != .raw_ptr or ptr.raw_ptr == 0) {
                        self.rememberError("indirect load requires a valid pointer");
                        return error.RuntimeFailure;
                    }
                    if (value.ty.kind == .ffi_struct) {
                        registers[value.dst] = .{ .raw_ptr = ptr.raw_ptr };
                    } else {
                        const slot_ptr: *runtime_abi.Value = @ptrFromInt(ptr.raw_ptr);
                        registers[value.dst] = slot_ptr.*;
                    }
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
                    const type_decl = findType(module, value.type_name) orelse {
                        self.rememberError("struct type could not be resolved");
                        return error.RuntimeFailure;
                    };
                    const dst_ptr: [*]runtime_abi.Value = @ptrFromInt(dst_ptr_value.raw_ptr);
                    const src_ptr: [*]runtime_abi.Value = @ptrFromInt(src_ptr_value.raw_ptr);
                    try self.copyStruct(module, type_decl, dst_ptr, src_ptr);
                },
                .branch => |value| {
                    const condition = registers[value.condition];
                    if (condition != .boolean) {
                        self.rememberError("vm branch expects a boolean condition");
                        return error.RuntimeFailure;
                    }
                    pc = try resolveLabelOffset(label_offsets, if (condition.boolean) value.true_label else value.false_label);
                    continue;
                },
                .jump => |value| {
                    pc = try resolveLabelOffset(label_offsets, value.label);
                    continue;
                },
                .label => {},
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
                .call_value => |value| {
                    const callee_value = registers[value.callee];
                    if (callee_value != .raw_ptr) {
                        self.rememberError("indirect call requires a callable function value");
                        return error.RuntimeFailure;
                    }
                    const function_id: u32 = @intCast(callee_value.raw_ptr);
                    const call_args = try collectArgs(self.allocator, registers, value.args);
                    defer self.allocator.free(call_args);
                    const result = if (module.findFunctionById(function_id) != null)
                        try self.runFunctionById(module, function_id, call_args, writer, hooks)
                    else blk: {
                        const callback = hooks.call_native orelse {
                            self.rememberError("vm native bridge was not installed");
                            return error.RuntimeFailure;
                        };
                        break :blk try callback(hooks.context, function_id, call_args);
                    };
                    if (value.dst) |dst| registers[dst] = result;
                },
                .ret => |value| return if (value.src) |src| registers[src] else .{ .void = {} },
            }
            pc += 1;
        }
        return .{ .void = {} };
    }

    fn rememberError(self: *Vm, message: []const u8) void {
        const length = @min(message.len, self.last_error_buffer.len);
        @memcpy(self.last_error_buffer[0..length], message[0..length]);
        self.last_error_len = length;
    }

    fn allocateStruct(self: *Vm, module: *const bytecode.Module, type_name: []const u8) !usize {
        const type_decl = findType(module, type_name) orelse {
            self.rememberError("struct type could not be resolved");
            return error.RuntimeFailure;
        };
        const fields = try self.allocator.alloc(runtime_abi.Value, type_decl.fields.len);
        for (type_decl.fields, 0..) |field_decl, index| {
            fields[index] = try self.zeroValueForType(module, field_decl.ty);
        }
        return @intFromPtr(fields.ptr);
    }

    fn allocateNativeState(self: *Vm, module: *const bytecode.Module, type_name: []const u8, type_id: u64, src_payload: usize) !usize {
        const type_decl = findType(module, type_name) orelse {
            self.rememberError("native state type could not be resolved");
            return error.RuntimeFailure;
        };
        const src_ptr: [*]runtime_abi.Value = @ptrFromInt(src_payload);
        const payload = try self.allocator.alloc(runtime_abi.BridgeValue, type_decl.fields.len);
        for (type_decl.fields, 0..) |_, index| {
            payload[index] = runtime_abi.bridgeValueFromValue(src_ptr[index]);
        }

        const box = try self.allocator.create(NativeStateBox);
        box.* = .{
            .type_id = type_id,
            .payload = @intFromPtr(payload.ptr),
        };
        return @intFromPtr(box);
    }

    fn recoverNativeState(self: *Vm, state_token: usize, expected_type_id: u64) !usize {
        const box: *NativeStateBox = @ptrFromInt(state_token);
        if (box.type_id != expected_type_id or box.payload == 0) {
            self.rememberError("nativeRecover used a userdata token for the wrong state type");
            return error.RuntimeFailure;
        }
        return box.payload;
    }

    fn zeroValueForType(self: *Vm, module: *const bytecode.Module, value_type: bytecode.TypeRef) anyerror!runtime_abi.Value {
        return switch (value_type.kind) {
            .void => .{ .void = {} },
            .integer => .{ .integer = 0 },
            .float => .{ .float = 0.0 },
            .string => .{ .string = "" },
            .boolean => .{ .boolean = false },
            .array, .raw_ptr => .{ .raw_ptr = 0 },
            .ffi_struct => blk: {
                const nested_name = value_type.name orelse {
                    self.rememberError("struct field type is missing a name");
                    return error.RuntimeFailure;
                };
                break :blk .{ .raw_ptr = try self.allocateStruct(module, nested_name) };
            },
        };
    }

    fn allocateArray(self: *Vm, len: usize) !usize {
        const object = try self.allocator.create(ArrayObject);
        const items = try self.allocator.alloc(runtime_abi.BridgeValue, if (len == 0) 1 else len);
        for (items) |*item| item.* = runtime_abi.bridgeValueFromValue(.{ .void = {} });
        object.* = .{
            .len = len,
            .items = items.ptr,
        };
        return @intFromPtr(object);
    }

    fn typeFieldCount(self: *Vm, module: *const bytecode.Module, type_name: []const u8) ?usize {
        _ = self;
        const type_decl = findType(module, type_name) orelse return null;
        return type_decl.fields.len;
    }

    fn copyStruct(
        self: *Vm,
        module: *const bytecode.Module,
        type_decl: bytecode.TypeDecl,
        dst_ptr: [*]runtime_abi.Value,
        src_ptr: [*]runtime_abi.Value,
    ) !void {
        for (type_decl.fields, 0..) |field_decl, index| {
            if (field_decl.ty.kind == .ffi_struct) {
                const nested_name = field_decl.ty.name orelse {
                    self.rememberError("struct field type is missing a name");
                    return error.RuntimeFailure;
                };
                const nested_type = findType(module, nested_name) orelse {
                    self.rememberError("struct type could not be resolved");
                    return error.RuntimeFailure;
                };
                if (dst_ptr[index] != .raw_ptr or src_ptr[index] != .raw_ptr or dst_ptr[index].raw_ptr == 0 or src_ptr[index].raw_ptr == 0) {
                    self.rememberError("nested struct copy requires valid pointers");
                    return error.RuntimeFailure;
                }
                const nested_dst: [*]runtime_abi.Value = @ptrFromInt(dst_ptr[index].raw_ptr);
                const nested_src: [*]runtime_abi.Value = @ptrFromInt(src_ptr[index].raw_ptr);
                try self.copyStruct(module, nested_type, nested_dst, nested_src);
            } else {
                dst_ptr[index] = src_ptr[index];
            }
        }
    }

    fn compareValues(
        self: *Vm,
        lhs: runtime_abi.Value,
        rhs: runtime_abi.Value,
        op: bytecode.CompareOp,
    ) !bool {
        switch (lhs) {
            .integer => |lhs_value| {
                if (rhs != .integer) {
                    self.rememberError("vm compare expects matching operand types");
                    return error.RuntimeFailure;
                }
                return switch (op) {
                    .equal => lhs_value == rhs.integer,
                    .not_equal => lhs_value != rhs.integer,
                    .less => lhs_value < rhs.integer,
                    .less_equal => lhs_value <= rhs.integer,
                    .greater => lhs_value > rhs.integer,
                    .greater_equal => lhs_value >= rhs.integer,
                };
            },
            .float => |lhs_value| {
                if (rhs != .float) {
                    self.rememberError("vm compare expects matching operand types");
                    return error.RuntimeFailure;
                }
                return switch (op) {
                    .equal => lhs_value == rhs.float,
                    .not_equal => lhs_value != rhs.float,
                    .less => lhs_value < rhs.float,
                    .less_equal => lhs_value <= rhs.float,
                    .greater => lhs_value > rhs.float,
                    .greater_equal => lhs_value >= rhs.float,
                };
            },
            .boolean => |lhs_value| {
                if (rhs != .boolean) {
                    self.rememberError("vm compare expects matching operand types");
                    return error.RuntimeFailure;
                }
                return switch (op) {
                    .equal => lhs_value == rhs.boolean,
                    .not_equal => lhs_value != rhs.boolean,
                    else => {
                        self.rememberError("vm compare does not support ordered boolean comparisons");
                        return error.RuntimeFailure;
                    },
                };
            },
            .raw_ptr => |lhs_value| {
                if (rhs != .raw_ptr) {
                    self.rememberError("vm compare expects matching operand types");
                    return error.RuntimeFailure;
                }
                return switch (op) {
                    .equal => lhs_value == rhs.raw_ptr,
                    .not_equal => lhs_value != rhs.raw_ptr,
                    else => {
                        self.rememberError("vm compare does not support ordered pointer comparisons");
                        return error.RuntimeFailure;
                    },
                };
            },
            else => {
                self.rememberError("vm compare does not support this value type");
                return error.RuntimeFailure;
            },
        }
    }

    fn unaryValue(self: *Vm, value: runtime_abi.Value, op: bytecode.UnaryOp) !runtime_abi.Value {
        return switch (op) {
            .negate => switch (value) {
                .integer => |inner| .{ .integer = -inner },
                .float => |inner| .{ .float = -inner },
                else => {
                    self.rememberError("vm negate expects a numeric operand");
                    return error.RuntimeFailure;
                },
            },
            .not => switch (value) {
                .boolean => |inner| .{ .boolean = !inner },
                else => {
                    self.rememberError("vm logical not expects a boolean operand");
                    return error.RuntimeFailure;
                },
            },
        };
    }

    fn addValues(self: *Vm, lhs: runtime_abi.Value, rhs: runtime_abi.Value) !runtime_abi.Value {
        return switch (lhs) {
            .integer => |lhs_value| blk: {
                if (rhs != .integer) {
                    self.rememberError("vm add expects matching numeric operands");
                    return error.RuntimeFailure;
                }
                break :blk .{ .integer = lhs_value + rhs.integer };
            },
            .float => |lhs_value| blk: {
                if (rhs != .float) {
                    self.rememberError("vm add expects matching numeric operands");
                    return error.RuntimeFailure;
                }
                break :blk .{ .float = lhs_value + rhs.float };
            },
            else => {
                self.rememberError("vm add expects numeric operands");
                return error.RuntimeFailure;
            },
        };
    }

    fn subtractValues(self: *Vm, lhs: runtime_abi.Value, rhs: runtime_abi.Value) !runtime_abi.Value {
        return switch (lhs) {
            .integer => |lhs_value| blk: {
                if (rhs != .integer) {
                    self.rememberError("vm subtract expects matching numeric operands");
                    return error.RuntimeFailure;
                }
                break :blk .{ .integer = lhs_value - rhs.integer };
            },
            .float => |lhs_value| blk: {
                if (rhs != .float) {
                    self.rememberError("vm subtract expects matching numeric operands");
                    return error.RuntimeFailure;
                }
                break :blk .{ .float = lhs_value - rhs.float };
            },
            else => {
                self.rememberError("vm subtract expects numeric operands");
                return error.RuntimeFailure;
            },
        };
    }

    fn multiplyValues(self: *Vm, lhs: runtime_abi.Value, rhs: runtime_abi.Value) !runtime_abi.Value {
        return switch (lhs) {
            .integer => |lhs_value| blk: {
                if (rhs != .integer) {
                    self.rememberError("vm multiply expects matching numeric operands");
                    return error.RuntimeFailure;
                }
                break :blk .{ .integer = lhs_value * rhs.integer };
            },
            .float => |lhs_value| blk: {
                if (rhs != .float) {
                    self.rememberError("vm multiply expects matching numeric operands");
                    return error.RuntimeFailure;
                }
                break :blk .{ .float = lhs_value * rhs.float };
            },
            else => {
                self.rememberError("vm multiply expects numeric operands");
                return error.RuntimeFailure;
            },
        };
    }

    fn divideValues(self: *Vm, lhs: runtime_abi.Value, rhs: runtime_abi.Value) !runtime_abi.Value {
        return switch (lhs) {
            .integer => |lhs_value| blk: {
                if (rhs != .integer) {
                    self.rememberError("vm divide expects matching numeric operands");
                    return error.RuntimeFailure;
                }
                if (rhs.integer == 0) {
                    self.rememberError("vm divide does not allow division by zero");
                    return error.RuntimeFailure;
                }
                break :blk .{ .integer = @divTrunc(lhs_value, rhs.integer) };
            },
            .float => |lhs_value| blk: {
                if (rhs != .float) {
                    self.rememberError("vm divide expects matching numeric operands");
                    return error.RuntimeFailure;
                }
                if (rhs.float == 0.0) {
                    self.rememberError("vm divide does not allow division by zero");
                    return error.RuntimeFailure;
                }
                break :blk .{ .float = lhs_value / rhs.float };
            },
            else => {
                self.rememberError("vm divide expects numeric operands");
                return error.RuntimeFailure;
            },
        };
    }

    fn moduloValues(self: *Vm, lhs: runtime_abi.Value, rhs: runtime_abi.Value) !runtime_abi.Value {
        return switch (lhs) {
            .integer => |lhs_value| blk: {
                if (rhs != .integer) {
                    self.rememberError("vm modulo expects matching numeric operands");
                    return error.RuntimeFailure;
                }
                if (rhs.integer == 0) {
                    self.rememberError("vm modulo does not allow division by zero");
                    return error.RuntimeFailure;
                }
                break :blk .{ .integer = @mod(lhs_value, rhs.integer) };
            },
            .float => |lhs_value| blk: {
                if (rhs != .float) {
                    self.rememberError("vm modulo expects matching numeric operands");
                    return error.RuntimeFailure;
                }
                if (rhs.float == 0.0) {
                    self.rememberError("vm modulo does not allow division by zero");
                    return error.RuntimeFailure;
                }
                break :blk .{ .float = @mod(lhs_value, rhs.float) };
            },
            else => {
                self.rememberError("vm modulo expects numeric operands");
                return error.RuntimeFailure;
            },
        };
    }
};

fn collectArgs(allocator: std.mem.Allocator, registers: []const runtime_abi.Value, argument_registers: []const u32) ![]runtime_abi.Value {
    const values = try allocator.alloc(runtime_abi.Value, argument_registers.len);
    for (argument_registers, 0..) |register_index, index| {
        values[index] = registers[register_index];
    }
    return values;
}

fn resolveFunctionPointer(hooks: Hooks, resolve_function: ResolveFunctionHook, function_id: u32) !usize {
    return resolve_function(hooks.context, function_id);
}

fn buildLabelOffsets(allocator: std.mem.Allocator, instructions: []const bytecode.Instruction) ![]usize {
    var max_label: usize = 0;
    var has_label = false;
    for (instructions) |inst| {
        if (inst != .label) continue;
        has_label = true;
        max_label = @max(max_label, @as(usize, @intCast(inst.label.id)));
    }

    if (!has_label) return allocator.alloc(usize, 0);

    const offsets = try allocator.alloc(usize, max_label + 1);
    @memset(offsets, std.math.maxInt(usize));

    for (instructions, 0..) |inst, index| {
        if (inst != .label) continue;
        offsets[@as(usize, @intCast(inst.label.id))] = index;
    }

    return offsets;
}

fn resolveLabelOffset(label_offsets: []const usize, label: u32) !usize {
    const label_index = @as(usize, @intCast(label));
    if (label_index >= label_offsets.len) return error.RuntimeFailure;
    const offset = label_offsets[label_index];
    if (offset == std.math.maxInt(usize)) return error.RuntimeFailure;
    return offset;
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
    var stream = std.Io.Writer.fixed(&buffer);
    try vm.runMain(&module, &stream);
    try std.testing.expectEqualStrings("42\n", stream.buffered());
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
                },
            },
        },
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
        .functions = &.{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{
                    .{ .const_function = .{ .dst = 0, .function_id = 7 } },
                    .{ .ret = .{ .src = 0 } },
                },
            },
        },
        .entry_function_id = 0,
    };

    const result = try vm.runFunctionById(&module, 0, &.{}, std.io.null_writer, .{
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
        .types = &.{
            .{
                .name = "Pair",
                .fields = &.{
                    .{ .name = "left", .ty = .{ .kind = .integer, .name = "I64" } },
                    .{ .name = "right", .ty = .{ .kind = .integer, .name = "I64" } },
                },
            },
        },
        .functions = &.{
            .{
                .id = 0,
                .name = "main",
                .param_count = 0,
                .register_count = 6,
                .local_count = 1,
                .local_types = &.{.{ .kind = .ffi_struct, .name = "Pair" }},
                .instructions = &.{
                    .{ .alloc_struct = .{ .dst = 0, .type_name = "Pair" } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Pair", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 2, .value = 1 } },
                    .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .store_local = .{ .local = 0, .src = 0 } },
                    .{ .call_runtime = .{ .function_id = 1, .args = &.{0} } },
                    .{ .field_ptr = .{ .dst = 3, .base = 0, .base_type_name = "Pair", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .load_indirect = .{ .dst = 4, .ptr = 3, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .ret = .{ .src = 4 } },
                },
            },
            .{
                .id = 1,
                .name = "mutate",
                .param_count = 1,
                .register_count = 3,
                .local_count = 1,
                .local_types = &.{.{ .kind = .ffi_struct, .name = "Pair" }},
                .instructions = &.{
                    .{ .load_local = .{ .dst = 0, .local = 0 } },
                    .{ .field_ptr = .{ .dst = 1, .base = 0, .base_type_name = "Pair", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .const_int = .{ .dst = 2, .value = 99 } },
                    .{ .store_indirect = .{ .ptr = 1, .src = 2, .ty = .{ .kind = .integer, .name = "I64" } } },
                    .{ .ret = .{ .src = null } },
                },
            },
        },
        .entry_function_id = 0,
    };

    const result = try vm.runFunctionById(&module, 0, &.{}, std.io.null_writer, .{});
    try std.testing.expectEqual(@as(i64, 1), result.integer);
}

test "native state recovery mutates persistent payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = &.{.{
            .name = "CounterState",
            .fields = &.{.{ .name = "count", .ty = .{ .kind = .integer, .name = "I64" } }},
        }},
        .functions = &.{.{
            .id = 0,
            .name = "main",
            .param_count = 0,
            .register_count = 9,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &.{
                .{ .alloc_struct = .{ .dst = 0, .type_name = "CounterState" } },
                .{ .alloc_native_state = .{ .dst = 1, .src = 0, .type_name = "CounterState", .type_id = 77 } },
                .{ .recover_native_state = .{ .dst = 2, .state = 1, .type_name = "CounterState", .type_id = 77 } },
                .{ .field_ptr = .{ .dst = 3, .base = 2, .base_type_name = "CounterState", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                .{ .const_int = .{ .dst = 4, .value = 9 } },
                .{ .store_indirect = .{ .ptr = 3, .src = 4, .ty = .{ .kind = .integer, .name = "I64" } } },
                .{ .recover_native_state = .{ .dst = 5, .state = 1, .type_name = "CounterState", .type_id = 77 } },
                .{ .field_ptr = .{ .dst = 6, .base = 5, .base_type_name = "CounterState", .field_index = 0, .field_ty = .{ .kind = .integer, .name = "I64" } } },
                .{ .load_indirect = .{ .dst = 7, .ptr = 6, .ty = .{ .kind = .integer, .name = "I64" } } },
                .{ .ret = .{ .src = 7 } },
            },
        }},
        .entry_function_id = 0,
    };

    const result = try vm.runFunctionById(&module, 0, &.{}, std.io.null_writer, .{});
    try std.testing.expectEqual(@as(i64, 9), result.integer);
}

test "native state recovery validates the expected type id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vm = Vm.init(arena.allocator());
    const module = bytecode.Module{
        .types = &.{.{
            .name = "CounterState",
            .fields = &.{.{ .name = "count", .ty = .{ .kind = .integer, .name = "I64" } }},
        }},
        .functions = &.{.{
            .id = 0,
            .name = "main",
            .param_count = 0,
            .register_count = 3,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &.{
                .{ .alloc_struct = .{ .dst = 0, .type_name = "CounterState" } },
                .{ .alloc_native_state = .{ .dst = 1, .src = 0, .type_name = "CounterState", .type_id = 77 } },
                .{ .recover_native_state = .{ .dst = 2, .state = 1, .type_name = "CounterState", .type_id = 88 } },
                .{ .ret = .{ .src = null } },
            },
        }},
        .entry_function_id = 0,
    };

    try std.testing.expectError(error.RuntimeFailure, vm.runFunctionById(&module, 0, &.{}, std.io.null_writer, .{}));
    try std.testing.expect(std.mem.indexOf(u8, vm.lastError().?, "wrong state type") != null);
}
