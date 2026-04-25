const std = @import("std");
const instruction = @import("instruction.zig");

pub const Module = struct {
    types: []TypeDecl = &.{},
    functions: []Function,
    entry_function_id: ?u32,

    pub fn writeToFile(self: Module, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{ .truncate = true });
        defer file.close(std.Options.debug_io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(std.Options.debug_io, &buffer);
        defer writer.interface.flush() catch {};
        try serialize(&writer.interface, self);
    }

    pub fn readFromFile(allocator: std.mem.Allocator, path: []const u8) !Module {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024 * 1024));
        return deserialize(allocator, bytes);
    }

    pub fn findFunctionById(self: Module, function_id: u32) ?Function {
        for (self.functions) |function_decl| {
            if (function_decl.id == function_id) return function_decl;
        }
        return null;
    }
};

pub const Function = struct {
    id: u32,
    name: []const u8,
    param_count: u32 = 0,
    return_type: instruction.TypeRef = .{ .kind = .void },
    register_count: u32,
    local_count: u32,
    local_types: []instruction.TypeRef = &.{},
    instructions: []instruction.Instruction,
};

pub const TypeDecl = struct {
    name: []const u8,
    fields: []Field,
};

pub const Field = struct {
    name: []const u8,
    ty: instruction.TypeRef,
};

pub fn serialize(writer: anytype, module: Module) !void {
    try writer.writeAll("KBC0");
    try writer.writeInt(u32, @as(u32, @intCast(module.types.len)), .little);
    try writer.writeInt(u32, @as(u32, @intCast(module.functions.len)), .little);
    try writer.writeInt(i32, if (module.entry_function_id) |value| @as(i32, @intCast(value)) else -1, .little);

    for (module.types) |type_decl| {
        try writeString(writer, type_decl.name);
        try writer.writeInt(u32, @as(u32, @intCast(type_decl.fields.len)), .little);
        for (type_decl.fields) |field_decl| {
            try writeString(writer, field_decl.name);
            try writeTypeRef(writer, field_decl.ty);
        }
    }

    for (module.functions) |function_decl| {
        try writer.writeInt(u32, function_decl.id, .little);
        try writeString(writer, function_decl.name);
        try writer.writeInt(u32, function_decl.param_count, .little);
        try writeTypeRef(writer, function_decl.return_type);
        try writer.writeInt(u32, function_decl.register_count, .little);
        try writer.writeInt(u32, function_decl.local_count, .little);
        try writer.writeInt(u32, @as(u32, @intCast(function_decl.local_types.len)), .little);
        for (function_decl.local_types) |local_ty| try writeTypeRef(writer, local_ty);
        try writer.writeInt(u32, @as(u32, @intCast(function_decl.instructions.len)), .little);
        for (function_decl.instructions) |inst| {
            try writer.writeByte(@intFromEnum(std.meta.activeTag(inst)));
            switch (inst) {
                .const_int => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(i64, value.value, .little);
                },
                .const_float => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u64, @bitCast(value.value), .little);
                },
                .const_string => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writeString(writer, value.value);
                },
                .const_bool => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeByte(if (value.value) 1 else 0);
                },
                .const_null_ptr => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                },
                .const_function => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.function_id, .little);
                    try writer.writeByte(@intFromEnum(value.representation));
                },
                .const_closure => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.function_id, .little);
                    try writer.writeInt(u32, @as(u32, @intCast(value.captures.len)), .little);
                    for (value.captures) |capture| try writer.writeInt(u32, capture, .little);
                },
                .alloc_struct => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writeString(writer, value.type_name);
                },
                .alloc_native_state => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.src, .little);
                    try writeString(writer, value.type_name);
                    try writer.writeInt(u64, value.type_id, .little);
                },
                .alloc_array => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.len, .little);
                },
                .add => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.lhs, .little);
                    try writer.writeInt(u32, value.rhs, .little);
                },
                .subtract => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.lhs, .little);
                    try writer.writeInt(u32, value.rhs, .little);
                },
                .multiply => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.lhs, .little);
                    try writer.writeInt(u32, value.rhs, .little);
                },
                .divide => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.lhs, .little);
                    try writer.writeInt(u32, value.rhs, .little);
                },
                .modulo => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.lhs, .little);
                    try writer.writeInt(u32, value.rhs, .little);
                },
                .compare => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.lhs, .little);
                    try writer.writeInt(u32, value.rhs, .little);
                    try writer.writeByte(@intFromEnum(value.op));
                },
                .unary => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.src, .little);
                    try writer.writeByte(@intFromEnum(value.op));
                },
                .store_local => |value| {
                    try writer.writeInt(u32, value.local, .little);
                    try writer.writeInt(u32, value.src, .little);
                },
                .load_local => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.local, .little);
                },
                .local_ptr => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.local, .little);
                },
                .subobject_ptr => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.base, .little);
                    try writer.writeInt(u32, value.offset, .little);
                },
                .field_ptr => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.base, .little);
                    try writeString(writer, value.base_type_name);
                    try writer.writeInt(u32, value.field_index, .little);
                    try writeTypeRef(writer, value.field_ty);
                },
                .recover_native_state => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.state, .little);
                    try writeString(writer, value.type_name);
                    try writer.writeInt(u64, value.type_id, .little);
                },
                .native_state_field_get => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.state, .little);
                    try writer.writeInt(u32, value.field_index, .little);
                    try writeTypeRef(writer, value.field_ty);
                },
                .native_state_field_set => |value| {
                    try writer.writeInt(u32, value.state, .little);
                    try writer.writeInt(u32, value.field_index, .little);
                    try writer.writeInt(u32, value.src, .little);
                    try writeTypeRef(writer, value.field_ty);
                },
                .array_len => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.array, .little);
                },
                .array_get => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.array, .little);
                    try writer.writeInt(u32, value.index, .little);
                    try writeTypeRef(writer, value.ty);
                },
                .array_set => |value| {
                    try writer.writeInt(u32, value.array, .little);
                    try writer.writeInt(u32, value.index, .little);
                    try writer.writeInt(u32, value.src, .little);
                },
                .load_indirect => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.ptr, .little);
                    try writeTypeRef(writer, value.ty);
                },
                .store_indirect => |value| {
                    try writer.writeInt(u32, value.ptr, .little);
                    try writer.writeInt(u32, value.src, .little);
                    try writeTypeRef(writer, value.ty);
                },
                .copy_indirect => |value| {
                    try writer.writeInt(u32, value.dst_ptr, .little);
                    try writer.writeInt(u32, value.src_ptr, .little);
                    try writeString(writer, value.type_name);
                },
                .branch => |value| {
                    try writer.writeInt(u32, value.condition, .little);
                    try writer.writeInt(u32, value.true_label, .little);
                    try writer.writeInt(u32, value.false_label, .little);
                },
                .jump => |value| try writer.writeInt(u32, value.label, .little),
                .label => |value| try writer.writeInt(u32, value.id, .little),
                .print => |value| {
                    try writer.writeInt(u32, value.src, .little);
                    try writeTypeRef(writer, value.ty);
                },
                .call_runtime => |value| try writeCall(writer, value.function_id, value.args, value.dst),
                .call_native => |value| {
                    try writeCall(writer, value.function_id, value.args, value.dst);
                    try writeTypeRef(writer, value.return_ty);
                },
                .call_value => |value| try writeIndirectCall(writer, value.callee, value.args, value.dst),
                .ret => |value| try writer.writeInt(i32, if (value.src) |src| @as(i32, @intCast(src)) else -1, .little),
            }
        }
    }
}

pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !Module {
    var reader_state = std.Io.Reader.fixed(bytes);
    const reader = &reader_state;

    var magic: [4]u8 = undefined;
    try reader.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, "KBC0")) return error.InvalidBytecode;

    const type_count = try reader.takeInt(u32, .little);
    const function_count = try reader.takeInt(u32, .little);
    const raw_entry = try reader.takeInt(i32, .little);
    var types = std.array_list.Managed(TypeDecl).init(allocator);
    var functions = std.array_list.Managed(Function).init(allocator);

    for (0..type_count) |_| {
        const name = try readString(allocator, reader);
        const field_count = try reader.takeInt(u32, .little);
        var fields = std.array_list.Managed(Field).init(allocator);
        for (0..field_count) |_| {
            try fields.append(.{
                .name = try readString(allocator, reader),
                .ty = try readTypeRef(allocator, reader),
            });
        }
        try types.append(.{
            .name = name,
            .fields = try fields.toOwnedSlice(),
        });
    }

    for (0..function_count) |_| {
        const function_id = try reader.takeInt(u32, .little);
        const name = try readString(allocator, reader);
        const param_count = try reader.takeInt(u32, .little);
        const return_type = try readTypeRef(allocator, reader);
        const register_count = try reader.takeInt(u32, .little);
        const local_count = try reader.takeInt(u32, .little);
        const local_type_count = try reader.takeInt(u32, .little);
        var local_types = std.array_list.Managed(instruction.TypeRef).init(allocator);
        for (0..local_type_count) |_| try local_types.append(try readTypeRef(allocator, reader));
        const instruction_count = try reader.takeInt(u32, .little);
        var instructions = std.array_list.Managed(instruction.Instruction).init(allocator);
        for (0..instruction_count) |_| {
            const tag = try reader.takeByte();
            const op: instruction.OpCode = @enumFromInt(tag);
            switch (op) {
                .const_int => try instructions.append(.{ .const_int = .{
                    .dst = try reader.takeInt(u32, .little),
                    .value = try reader.takeInt(i64, .little),
                } }),
                .const_float => try instructions.append(.{ .const_float = .{
                    .dst = try reader.takeInt(u32, .little),
                    .value = @bitCast(try reader.takeInt(u64, .little)),
                } }),
                .const_string => try instructions.append(.{ .const_string = .{
                    .dst = try reader.takeInt(u32, .little),
                    .value = try readString(allocator, reader),
                } }),
                .const_bool => try instructions.append(.{ .const_bool = .{
                    .dst = try reader.takeInt(u32, .little),
                    .value = (try reader.takeByte()) != 0,
                } }),
                .const_null_ptr => try instructions.append(.{ .const_null_ptr = .{
                    .dst = try reader.takeInt(u32, .little),
                } }),
                .const_function => try instructions.append(.{ .const_function = .{
                    .dst = try reader.takeInt(u32, .little),
                    .function_id = try reader.takeInt(u32, .little),
                    .representation = @enumFromInt(try reader.takeByte()),
                } }),
                .const_closure => {
                    const dst = try reader.takeInt(u32, .little);
                    const closure_function_id = try reader.takeInt(u32, .little);
                    const capture_count = try reader.takeInt(u32, .little);
                    const captures = try allocator.alloc(u32, capture_count);
                    for (0..capture_count) |index| captures[index] = try reader.takeInt(u32, .little);
                    try instructions.append(.{ .const_closure = .{
                        .dst = dst,
                        .function_id = closure_function_id,
                        .captures = captures,
                    } });
                },
                .alloc_struct => try instructions.append(.{ .alloc_struct = .{
                    .dst = try reader.takeInt(u32, .little),
                    .type_name = try readString(allocator, reader),
                } }),
                .alloc_native_state => try instructions.append(.{ .alloc_native_state = .{
                    .dst = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                    .type_name = try readString(allocator, reader),
                    .type_id = try reader.takeInt(u64, .little),
                } }),
                .alloc_array => try instructions.append(.{ .alloc_array = .{
                    .dst = try reader.takeInt(u32, .little),
                    .len = try reader.takeInt(u32, .little),
                } }),
                .add => try instructions.append(.{ .add = .{
                    .dst = try reader.takeInt(u32, .little),
                    .lhs = try reader.takeInt(u32, .little),
                    .rhs = try reader.takeInt(u32, .little),
                } }),
                .subtract => try instructions.append(.{ .subtract = .{
                    .dst = try reader.takeInt(u32, .little),
                    .lhs = try reader.takeInt(u32, .little),
                    .rhs = try reader.takeInt(u32, .little),
                } }),
                .multiply => try instructions.append(.{ .multiply = .{
                    .dst = try reader.takeInt(u32, .little),
                    .lhs = try reader.takeInt(u32, .little),
                    .rhs = try reader.takeInt(u32, .little),
                } }),
                .divide => try instructions.append(.{ .divide = .{
                    .dst = try reader.takeInt(u32, .little),
                    .lhs = try reader.takeInt(u32, .little),
                    .rhs = try reader.takeInt(u32, .little),
                } }),
                .modulo => try instructions.append(.{ .modulo = .{
                    .dst = try reader.takeInt(u32, .little),
                    .lhs = try reader.takeInt(u32, .little),
                    .rhs = try reader.takeInt(u32, .little),
                } }),
                .compare => try instructions.append(.{ .compare = .{
                    .dst = try reader.takeInt(u32, .little),
                    .lhs = try reader.takeInt(u32, .little),
                    .rhs = try reader.takeInt(u32, .little),
                    .op = @enumFromInt(try reader.takeByte()),
                } }),
                .unary => try instructions.append(.{ .unary = .{
                    .dst = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                    .op = @enumFromInt(try reader.takeByte()),
                } }),
                .store_local => try instructions.append(.{ .store_local = .{
                    .local = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                } }),
                .load_local => try instructions.append(.{ .load_local = .{
                    .dst = try reader.takeInt(u32, .little),
                    .local = try reader.takeInt(u32, .little),
                } }),
                .local_ptr => try instructions.append(.{ .local_ptr = .{
                    .dst = try reader.takeInt(u32, .little),
                    .local = try reader.takeInt(u32, .little),
                } }),
                .subobject_ptr => try instructions.append(.{ .subobject_ptr = .{
                    .dst = try reader.takeInt(u32, .little),
                    .base = try reader.takeInt(u32, .little),
                    .offset = try reader.takeInt(u32, .little),
                } }),
                .field_ptr => try instructions.append(.{ .field_ptr = .{
                    .dst = try reader.takeInt(u32, .little),
                    .base = try reader.takeInt(u32, .little),
                    .base_type_name = try readString(allocator, reader),
                    .field_index = try reader.takeInt(u32, .little),
                    .field_ty = try readTypeRef(allocator, reader),
                } }),
                .recover_native_state => try instructions.append(.{ .recover_native_state = .{
                    .dst = try reader.takeInt(u32, .little),
                    .state = try reader.takeInt(u32, .little),
                    .type_name = try readString(allocator, reader),
                    .type_id = try reader.takeInt(u64, .little),
                } }),
                .native_state_field_get => try instructions.append(.{ .native_state_field_get = .{
                    .dst = try reader.takeInt(u32, .little),
                    .state = try reader.takeInt(u32, .little),
                    .field_index = try reader.takeInt(u32, .little),
                    .field_ty = try readTypeRef(allocator, reader),
                } }),
                .native_state_field_set => try instructions.append(.{ .native_state_field_set = .{
                    .state = try reader.takeInt(u32, .little),
                    .field_index = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                    .field_ty = try readTypeRef(allocator, reader),
                } }),
                .array_len => try instructions.append(.{ .array_len = .{
                    .dst = try reader.takeInt(u32, .little),
                    .array = try reader.takeInt(u32, .little),
                } }),
                .array_get => try instructions.append(.{ .array_get = .{
                    .dst = try reader.takeInt(u32, .little),
                    .array = try reader.takeInt(u32, .little),
                    .index = try reader.takeInt(u32, .little),
                    .ty = try readTypeRef(allocator, reader),
                } }),
                .array_set => try instructions.append(.{ .array_set = .{
                    .array = try reader.takeInt(u32, .little),
                    .index = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                } }),
                .load_indirect => try instructions.append(.{ .load_indirect = .{
                    .dst = try reader.takeInt(u32, .little),
                    .ptr = try reader.takeInt(u32, .little),
                    .ty = try readTypeRef(allocator, reader),
                } }),
                .store_indirect => try instructions.append(.{ .store_indirect = .{
                    .ptr = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                    .ty = try readTypeRef(allocator, reader),
                } }),
                .copy_indirect => try instructions.append(.{ .copy_indirect = .{
                    .dst_ptr = try reader.takeInt(u32, .little),
                    .src_ptr = try reader.takeInt(u32, .little),
                    .type_name = try readString(allocator, reader),
                } }),
                .branch => try instructions.append(.{ .branch = .{
                    .condition = try reader.takeInt(u32, .little),
                    .true_label = try reader.takeInt(u32, .little),
                    .false_label = try reader.takeInt(u32, .little),
                } }),
                .jump => try instructions.append(.{ .jump = .{ .label = try reader.takeInt(u32, .little) } }),
                .label => try instructions.append(.{ .label = .{ .id = try reader.takeInt(u32, .little) } }),
                .print => try instructions.append(.{ .print = .{
                    .src = try reader.takeInt(u32, .little),
                    .ty = try readTypeRef(allocator, reader),
                } }),
                .call_runtime => try instructions.append(.{ .call_runtime = try readRuntimeCall(allocator, reader) }),
                .call_native => try instructions.append(.{ .call_native = try readNativeCall(allocator, reader) }),
                .call_value => try instructions.append(.{ .call_value = try readIndirectCall(allocator, reader) }),
                .ret => try instructions.append(.{ .ret = .{
                    .src = blk: {
                        const raw = try reader.takeInt(i32, .little);
                        break :blk if (raw >= 0) @as(?u32, @intCast(raw)) else null;
                    },
                } }),
            }
        }
        try functions.append(.{
            .id = function_id,
            .name = name,
            .param_count = param_count,
            .return_type = return_type,
            .register_count = register_count,
            .local_count = local_count,
            .local_types = try local_types.toOwnedSlice(),
            .instructions = try instructions.toOwnedSlice(),
        });
    }

    return .{
        .types = try types.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
        .entry_function_id = if (raw_entry >= 0) @as(u32, @intCast(raw_entry)) else null,
    };
}

fn writeString(writer: anytype, value: []const u8) !void {
    try writer.writeInt(u32, @as(u32, @intCast(value.len)), .little);
    try writer.writeAll(value);
}

fn readString(allocator: std.mem.Allocator, reader: anytype) ![]const u8 {
    const length = try reader.takeInt(u32, .little);
    const buffer = try allocator.alloc(u8, length);
    _ = try reader.readSliceAll(buffer);
    return buffer;
}

fn writeCall(writer: anytype, function_id: u32, args: []const u32, dst: ?u32) !void {
    try writer.writeInt(u32, function_id, .little);
    try writer.writeInt(u32, @as(u32, @intCast(args.len)), .little);
    for (args) |arg| try writer.writeInt(u32, arg, .little);
    try writer.writeInt(i32, if (dst) |value| @as(i32, @intCast(value)) else -1, .little);
}

fn writeIndirectCall(writer: anytype, callee: u32, args: []const u32, dst: ?u32) !void {
    try writer.writeInt(u32, callee, .little);
    try writer.writeInt(u32, @as(u32, @intCast(args.len)), .little);
    for (args) |arg| try writer.writeInt(u32, arg, .little);
    try writer.writeInt(i32, if (dst) |value| @as(i32, @intCast(value)) else -1, .little);
}

fn writeTypeRef(writer: anytype, value: instruction.TypeRef) !void {
    try writer.writeByte(@intFromEnum(value.kind));
    try writer.writeByte(if (value.name != null) 1 else 0);
    if (value.name) |name| try writeString(writer, name);
}

fn readTypeRef(allocator: std.mem.Allocator, reader: anytype) !instruction.TypeRef {
    const kind: instruction.TypeRef.Kind = @enumFromInt(try reader.takeByte());
    const has_name = (try reader.takeByte()) != 0;
    return .{
        .kind = kind,
        .name = if (has_name) try readString(allocator, reader) else null,
    };
}

fn readRuntimeCall(allocator: std.mem.Allocator, reader: anytype) !@FieldType(instruction.Instruction, "call_runtime") {
    const call = try readCallParts(allocator, reader);
    return .{ .function_id = call.function_id, .args = call.args, .dst = call.dst };
}

fn readNativeCall(allocator: std.mem.Allocator, reader: anytype) !@FieldType(instruction.Instruction, "call_native") {
    const call = try readCallParts(allocator, reader);
    return .{
        .function_id = call.function_id,
        .args = call.args,
        .dst = call.dst,
        .return_ty = try readTypeRef(allocator, reader),
    };
}

fn readIndirectCall(allocator: std.mem.Allocator, reader: anytype) !@FieldType(instruction.Instruction, "call_value") {
    const call = try readIndirectCallParts(allocator, reader);
    return .{ .callee = call.callee, .args = call.args, .dst = call.dst };
}

fn readCallParts(allocator: std.mem.Allocator, reader: anytype) !struct { function_id: u32, args: []const u32, dst: ?u32 } {
    const function_id = try reader.takeInt(u32, .little);
    const arg_count = try reader.takeInt(u32, .little);
    const args = try allocator.alloc(u32, arg_count);
    for (0..arg_count) |index| {
        args[index] = try reader.takeInt(u32, .little);
    }
    const raw_dst = try reader.takeInt(i32, .little);
    return .{
        .function_id = function_id,
        .args = args,
        .dst = if (raw_dst >= 0) @as(?u32, @intCast(raw_dst)) else null,
    };
}

fn readIndirectCallParts(allocator: std.mem.Allocator, reader: anytype) !struct { callee: u32, args: []const u32, dst: ?u32 } {
    const callee = try reader.takeInt(u32, .little);
    const arg_count = try reader.takeInt(u32, .little);
    const args = try allocator.alloc(u32, arg_count);
    for (0..arg_count) |index| {
        args[index] = try reader.takeInt(u32, .little);
    }
    const raw_dst = try reader.takeInt(i32, .little);
    return .{
        .callee = callee,
        .args = args,
        .dst = if (raw_dst >= 0) @as(?u32, @intCast(raw_dst)) else null,
    };
}

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
