//! Binary serialization of bytecode modules (the KBC container format):
//! `serialize`/`deserialize` plus their field-level helpers. The data model
//! itself lives in bytecode.zig; round-trip tests live in serialization_tests.zig.

const std = @import("std");
const instruction = @import("instruction.zig");
const bytecode = @import("bytecode.zig");
const runtime_abi = @import("kira_runtime_abi");

const Module = bytecode.Module;
const Construct = bytecode.Construct;
const ConstructImplementation = bytecode.ConstructImplementation;
const LifecycleHook = bytecode.LifecycleHook;
const TypeDecl = bytecode.TypeDecl;
const EnumTypeDecl = bytecode.EnumTypeDecl;
const EnumVariantDecl = bytecode.EnumVariantDecl;
const Field = bytecode.Field;
const TypeKind = bytecode.TypeKind;
const MethodMember = bytecode.MethodMember;
const Function = bytecode.Function;
const OwnershipMode = bytecode.OwnershipMode;

// Field-level codec primitives (Core Law #5 split).
const primitives = @import("serialization_primitives.zig");
const writeString = primitives.writeString;
const writeOwnershipModes = primitives.writeOwnershipModes;
const readOwnershipModes = primitives.readOwnershipModes;
const readOwnershipMode = primitives.readOwnershipMode;
const defaultOwnershipModes = primitives.defaultOwnershipModes;
const readString = primitives.readString;
const readStringList = primitives.readStringList;
const writeCall = primitives.writeCall;
const writeIndirectCall = primitives.writeIndirectCall;
const writeCallPayload = primitives.writeCallPayload;
const writeTypeRef = primitives.writeTypeRef;
const readTypeRef = primitives.readTypeRef;
const readRuntimeCall = primitives.readRuntimeCall;
const readNativeCall = primitives.readNativeCall;
const readIndirectCall = primitives.readIndirectCall;
const readVirtualCall = primitives.readVirtualCall;
const readCallParts = primitives.readCallParts;

pub fn serialize(writer: anytype, module: Module) !void {
    try writer.writeAll("KBCC");
    try writer.writeInt(u32, @as(u32, @intCast(module.constructs.len)), .little);
    try writer.writeInt(u32, @as(u32, @intCast(module.construct_implementations.len)), .little);
    try writer.writeInt(u32, @as(u32, @intCast(module.types.len)), .little);
    try writer.writeInt(u32, @as(u32, @intCast(module.enums.len)), .little);
    try writer.writeInt(u32, @as(u32, @intCast(module.functions.len)), .little);
    try writer.writeInt(i32, if (module.entry_function_id) |value| @as(i32, @intCast(value)) else -1, .little);

    for (module.constructs) |construct_decl| {
        try writeString(writer, construct_decl.name);
    }

    for (module.construct_implementations) |implementation| {
        try writeString(writer, implementation.type_name);
        try writeString(writer, implementation.construct_constraint.construct_name);
        try writer.writeInt(u32, @as(u32, @intCast(implementation.families.len)), .little);
        for (implementation.families) |family| try writeString(writer, family);
        try writer.writeInt(u32, @as(u32, @intCast(implementation.fields.len)), .little);
        for (implementation.fields) |field_decl| {
            try writeString(writer, field_decl.name);
            try writeTypeRef(writer, field_decl.ty);
        }
        try writer.writeByte(if (implementation.has_content) 1 else 0);
        try writer.writeInt(u32, @as(u32, @intCast(implementation.lifecycle_hooks.len)), .little);
        for (implementation.lifecycle_hooks) |hook| try writeString(writer, hook.name);
    }

    for (module.types) |type_decl| {
        try writeString(writer, type_decl.name);
        try writer.writeByte(@intFromEnum(type_decl.kind));
        try writer.writeInt(u32, @as(u32, @intCast(type_decl.fields.len)), .little);
        for (type_decl.fields) |field_decl| {
            try writeString(writer, field_decl.name);
            try writeTypeRef(writer, field_decl.ty);
        }
        try writer.writeInt(u32, @as(u32, @intCast(type_decl.methods.len)), .little);
        for (type_decl.methods) |method_decl| {
            try writeString(writer, method_decl.name);
            try writer.writeInt(u32, method_decl.function_id, .little);
            try writer.writeInt(u32, method_decl.receiver_offset, .little);
        }
    }

    for (module.enums) |enum_decl| {
        try writeString(writer, enum_decl.name);
        try writer.writeInt(u32, @as(u32, @intCast(enum_decl.variants.len)), .little);
        for (enum_decl.variants) |variant_decl| {
            try writeString(writer, variant_decl.name);
            try writer.writeInt(u32, variant_decl.discriminant, .little);
            try writer.writeByte(if (variant_decl.payload_ty != null) 1 else 0);
            if (variant_decl.payload_ty) |payload_ty| try writeTypeRef(writer, payload_ty);
        }
    }

    for (module.functions) |function_decl| {
        try writer.writeInt(u32, function_decl.id, .little);
        try writeString(writer, function_decl.name);
        try writer.writeInt(u32, function_decl.param_count, .little);
        try writeOwnershipModes(writer, function_decl.param_ownership);
        try writeTypeRef(writer, function_decl.return_type);
        try writer.writeByte(@intFromEnum(function_decl.return_ownership));
        // KBC5 FFI metadata: declared parameter types plus the optional foreign
        // binding, so the VM can dispatch direct FFI through LibFFI.
        try writer.writeInt(u32, @as(u32, @intCast(function_decl.param_types.len)), .little);
        for (function_decl.param_types) |param_ty| try writeTypeRef(writer, param_ty);
        try writer.writeByte(if (function_decl.is_extern) 1 else 0);
        if (function_decl.foreign) |foreign| {
            try writer.writeByte(1);
            try writeString(writer, foreign.library_name);
            try writeString(writer, foreign.symbol_name);
            try writer.writeByte(@intFromEnum(foreign.calling_convention));
        } else {
            try writer.writeByte(0);
        }
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
                    try writeOwnershipModes(writer, value.capture_ownership);
                },
                .alloc_struct => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writeString(writer, value.type_name);
                },
                .alloc_enum => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writeString(writer, value.enum_type_name);
                    try writer.writeInt(u32, value.discriminant, .little);
                    try writer.writeInt(i32, if (value.payload_src) |payload_src| @as(i32, @intCast(payload_src)) else -1, .little);
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
                    try writer.writeByte(@intFromBool(value.unsigned));
                },
                .modulo => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.lhs, .little);
                    try writer.writeInt(u32, value.rhs, .little);
                    try writer.writeByte(@intFromBool(value.unsigned));
                },
                .convert => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.src, .little);
                    try writer.writeByte(if (value.to_float) 1 else 0);
                    try writer.writeByte(if (value.reinterpret) 1 else 0);
                },
                .bitwise => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.lhs, .little);
                    try writer.writeInt(u32, value.rhs, .little);
                    try writer.writeByte(@intFromEnum(value.op));
                    try writer.writeByte(@intFromBool(value.unsigned));
                },
                .compare => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.lhs, .little);
                    try writer.writeInt(u32, value.rhs, .little);
                    try writer.writeByte(@intFromEnum(value.op));
                    try writer.writeByte(@intFromBool(value.unsigned));
                },
                .unary => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.src, .little);
                    try writer.writeByte(@intFromEnum(value.op));
                },
                .store_local => |value| {
                    try writer.writeInt(u32, value.local, .little);
                    try writer.writeInt(u32, value.src, .little);
                    try writer.writeByte(@intFromBool(value.borrow));
                },
                .load_local => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.local, .little);
                    try writer.writeByte(@intFromEnum(value.ownership));
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
                .free_native_state => |value| {
                    try writer.writeInt(u32, value.state, .little);
                },
                .native_state_field_get => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.state, .little);
                    try writer.writeInt(u32, value.field_index, .little);
                    try writeTypeRef(writer, value.field_ty);
                    try writer.writeByte(@intFromBool(value.moved));
                },
                .native_state_field_set => |value| {
                    try writer.writeInt(u32, value.state, .little);
                    try writer.writeInt(u32, value.field_index, .little);
                    try writer.writeInt(u32, value.src, .little);
                    try writeTypeRef(writer, value.field_ty);
                },
                .c_string_to_string => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.src, .little);
                },
                .array_len => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.array, .little);
                },
                .string_len => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.string, .little);
                },
                .array_get => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.array, .little);
                    try writer.writeInt(u32, value.index, .little);
                    try writeTypeRef(writer, value.ty);
                    try writer.writeByte(if (value.borrow) 1 else 0);
                    try writer.writeByte(@intFromBool(value.moved));
                },
                .array_set => |value| {
                    try writer.writeInt(u32, value.array, .little);
                    try writer.writeInt(u32, value.index, .little);
                    try writer.writeInt(u32, value.src, .little);
                },
                .array_append => |value| {
                    try writer.writeInt(u32, value.array, .little);
                    try writer.writeInt(u32, value.src, .little);
                },
                .enum_tag => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.src, .little);
                },
                .enum_payload => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.src, .little);
                    try writeTypeRef(writer, value.payload_ty);
                },
                .load_indirect => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.ptr, .little);
                    try writeTypeRef(writer, value.ty);
                    try writer.writeByte(@intFromBool(value.moved));
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
                .call_virtual => |value| {
                    try writer.writeInt(u32, value.receiver, .little);
                    try writeString(writer, value.static_type_name);
                    try writeString(writer, value.method_name);
                    try writeCallPayload(writer, value.args, value.dst);
                    try writeTypeRef(writer, value.return_ty);
                },
                .call_value => |value| {
                    try writeIndirectCall(writer, value.callee, value.args, value.dst);
                    try writeOwnershipModes(writer, value.param_ownership);
                },
                .ret => |value| try writer.writeInt(i32, if (value.src) |src| @as(i32, @intCast(src)) else -1, .little),
                .task_spawn => |value| {
                    try writeCall(writer, value.callee, value.args, value.dst);
                    try writeTypeRef(writer, value.result_ty);
                    try writer.writeByte(if (value.native) 1 else 0);
                    try writer.writeByte(if (value.suspendable) 1 else 0);
                    try writer.writeInt(u32, value.frame_slots, .little);
                },
                .task_spawn_ready => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.value, .little);
                    try writeTypeRef(writer, value.ty);
                },
                .task_await => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.task, .little);
                    try writeTypeRef(writer, value.ty);
                },
                .task_cancel => |value| try writer.writeInt(u32, value.task, .little),
                .task_detach => |value| try writer.writeInt(u32, value.task, .little),
                .task_yield => {},
                .frame_get => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.frame, .little);
                    try writer.writeInt(u32, value.slot, .little);
                    try writeTypeRef(writer, value.ty);
                },
                .frame_set => |value| {
                    try writer.writeInt(u32, value.frame, .little);
                    try writer.writeInt(u32, value.slot, .little);
                    try writer.writeInt(u32, value.src, .little);
                    try writeTypeRef(writer, value.ty);
                },
                .task_is_complete => |value| {
                    try writer.writeInt(u32, value.dst, .little);
                    try writer.writeInt(u32, value.task, .little);
                },
                .task_sleep => |value| try writer.writeInt(u32, value.milliseconds, .little),
                // VM-internal fused instructions only exist inside the VM's
                // private decoded code copies (vm_prepare.zig); a module that
                // contains one is malformed and must not be serialized. Every
                // serializable opcode is handled explicitly above, so the only
                // tags reaching here are the fused superinstructions.
                else => {
                    std.debug.assert(instruction.isFused(std.meta.activeTag(inst)));
                    return error.InternalInstruction;
                },
            }
        }
    }
}
pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !Module {
    var reader_state = std.Io.Reader.fixed(bytes);
    const reader = &reader_state;

    var magic: [4]u8 = undefined;
    try reader.readSliceAll(&magic);
    const is_kbc5 = std.mem.eql(u8, &magic, "KBC5");
    const is_kbc6 = std.mem.eql(u8, &magic, "KBC6");
    // KBC7 is KBC6 plus the appended `convert` opcode; the container layout and
    // every feature flag are otherwise identical to KBC6.
    const is_kbc7 = std.mem.eql(u8, &magic, "KBC7");
    // KBC8 is KBC7 plus a trailing `unsigned` flag byte on divide/modulo/compare
    // (unsigned integer division/remainder/ordering). Older containers omit it and
    // default to signed, matching their original behavior.
    const is_kbc8 = std.mem.eql(u8, &magic, "KBC8");
    // KBC9 is KBC8 plus the appended `free_native_state` opcode (`nativeStateFree`);
    // container layout and every feature flag are otherwise identical to KBC8.
    const is_kbc9 = std.mem.eql(u8, &magic, "KBC9");
    // KBCA is KBC9 plus a trailing `moved` flag byte on load_indirect (checker-
    // verified field move-out: the VM takes the field's value and voids the
    // slot — Rust partial move). Older containers omit it (plain borrow read).
    const is_kbca = std.mem.eql(u8, &magic, "KBCA");
    // KBCB is KBCA plus a trailing `reinterpret` flag byte on `convert` (Float<->
    // bits bitcast: floatToBits / bitsToFloat). Older containers omit it and
    // default to a value-preserving numeric convert.
    const is_kbcb = std.mem.eql(u8, &magic, "KBCB");
    // KBCC is KBCB plus the appended async task opcodes (task_spawn,
    // task_spawn_ready, task_await, task_cancel, task_detach); container layout
    // and every feature flag are otherwise identical to KBCB.
    const is_kbcc = std.mem.eql(u8, &magic, "KBCC");
    const has_unsigned_arith = is_kbc8 or is_kbc9 or is_kbca or is_kbcb or is_kbcc;
    const has_load_indirect_moved = is_kbca or is_kbcb or is_kbcc;
    const has_convert_reinterpret = is_kbcb or is_kbcc;
    const is_kbc6_or_later = is_kbc6 or is_kbc7 or is_kbc8 or is_kbc9 or is_kbca or is_kbcb or is_kbcc;
    const has_function_ownership = std.mem.eql(u8, &magic, "KBC1") or std.mem.eql(u8, &magic, "KBC3") or std.mem.eql(u8, &magic, "KBC4") or is_kbc5 or is_kbc6_or_later;
    const has_closure_ownership = std.mem.eql(u8, &magic, "KBC3") or std.mem.eql(u8, &magic, "KBC4") or is_kbc5 or is_kbc6_or_later;
    const has_load_ownership = std.mem.eql(u8, &magic, "KBC3") or std.mem.eql(u8, &magic, "KBC4") or is_kbc5 or is_kbc6_or_later;
    const has_indirect_call_ownership = std.mem.eql(u8, &magic, "KBC4") or is_kbc5 or is_kbc6_or_later;
    const has_ffi_metadata = is_kbc5 or is_kbc6_or_later;
    const has_construct_families = is_kbc6_or_later;
    if (!has_function_ownership and
        !std.mem.eql(u8, &magic, "KBC0") and
        !std.mem.eql(u8, &magic, "KBC2"))
        return error.InvalidBytecode;

    const construct_count = try reader.takeInt(u32, .little);
    const construct_implementation_count = try reader.takeInt(u32, .little);
    const type_count = try reader.takeInt(u32, .little);
    const enum_count = try reader.takeInt(u32, .little);
    const function_count = try reader.takeInt(u32, .little);
    const raw_entry = try reader.takeInt(i32, .little);
    var constructs = std.array_list.Managed(Construct).init(allocator);
    var construct_implementations = std.array_list.Managed(ConstructImplementation).init(allocator);
    var types = std.array_list.Managed(TypeDecl).init(allocator);
    var enums = std.array_list.Managed(EnumTypeDecl).init(allocator);
    var functions = std.array_list.Managed(Function).init(allocator);

    for (0..construct_count) |_| {
        try constructs.append(.{ .name = try readString(allocator, reader) });
    }

    for (0..construct_implementation_count) |_| {
        const type_name = try readString(allocator, reader);
        const construct_name = try readString(allocator, reader);
        const families = if (has_construct_families)
            try readStringList(allocator, reader)
        else blk: {
            const fallback = try allocator.alloc([]const u8, 1);
            fallback[0] = construct_name;
            break :blk fallback;
        };
        const field_count = try reader.takeInt(u32, .little);
        var fields = std.array_list.Managed(Field).init(allocator);
        for (0..field_count) |_| {
            try fields.append(.{
                .name = try readString(allocator, reader),
                .ty = try readTypeRef(allocator, reader),
            });
        }
        const has_content = (try reader.takeByte()) != 0;
        const lifecycle_hook_count = try reader.takeInt(u32, .little);
        var lifecycle_hooks = std.array_list.Managed(LifecycleHook).init(allocator);
        for (0..lifecycle_hook_count) |_| {
            try lifecycle_hooks.append(.{ .name = try readString(allocator, reader) });
        }
        try construct_implementations.append(.{
            .type_name = type_name,
            .construct_constraint = .{ .construct_name = construct_name },
            .families = families,
            .fields = try fields.toOwnedSlice(),
            .has_content = has_content,
            .lifecycle_hooks = try lifecycle_hooks.toOwnedSlice(),
        });
    }

    for (0..type_count) |_| {
        const name = try readString(allocator, reader);
        const kind: TypeKind = @enumFromInt(try reader.takeByte());
        const field_count = try reader.takeInt(u32, .little);
        var fields = std.array_list.Managed(Field).init(allocator);
        for (0..field_count) |_| {
            try fields.append(.{
                .name = try readString(allocator, reader),
                .ty = try readTypeRef(allocator, reader),
            });
        }
        const method_count = try reader.takeInt(u32, .little);
        var methods = std.array_list.Managed(MethodMember).init(allocator);
        for (0..method_count) |_| {
            try methods.append(.{
                .name = try readString(allocator, reader),
                .function_id = try reader.takeInt(u32, .little),
                .receiver_offset = try reader.takeInt(u32, .little),
            });
        }
        try types.append(.{
            .name = name,
            .kind = kind,
            .fields = try fields.toOwnedSlice(),
            .methods = try methods.toOwnedSlice(),
        });
    }

    for (0..enum_count) |_| {
        const name = try readString(allocator, reader);
        const variant_count = try reader.takeInt(u32, .little);
        var variants = std.array_list.Managed(EnumVariantDecl).init(allocator);
        for (0..variant_count) |_| {
            const variant_name = try readString(allocator, reader);
            const discriminant = try reader.takeInt(u32, .little);
            const has_payload = (try reader.takeByte()) != 0;
            try variants.append(.{
                .name = variant_name,
                .discriminant = discriminant,
                .payload_ty = if (has_payload) try readTypeRef(allocator, reader) else null,
            });
        }
        try enums.append(.{
            .name = name,
            .variants = try variants.toOwnedSlice(),
        });
    }

    for (0..function_count) |_| {
        const function_id = try reader.takeInt(u32, .little);
        const name = try readString(allocator, reader);
        const param_count = try reader.takeInt(u32, .little);
        const param_ownership = if (has_function_ownership)
            try readOwnershipModes(allocator, reader)
        else
            try defaultOwnershipModes(allocator, param_count, .owned);
        const return_type = try readTypeRef(allocator, reader);
        const return_ownership: OwnershipMode = if (has_function_ownership) try readOwnershipMode(reader) else .owned;
        var param_types: []const instruction.TypeRef = &.{};
        var is_extern = false;
        var foreign: ?bytecode.ForeignFunction = null;
        if (has_ffi_metadata) {
            const param_type_count = try reader.takeInt(u32, .little);
            var param_type_list = std.array_list.Managed(instruction.TypeRef).init(allocator);
            for (0..param_type_count) |_| try param_type_list.append(try readTypeRef(allocator, reader));
            param_types = try param_type_list.toOwnedSlice();
            is_extern = (try reader.takeByte()) != 0;
            if ((try reader.takeByte()) != 0) {
                const library_name = try readString(allocator, reader);
                const symbol_name = try readString(allocator, reader);
                const calling_convention: runtime_abi.CallingConvention = @enumFromInt(try reader.takeByte());
                foreign = .{
                    .library_name = library_name,
                    .symbol_name = symbol_name,
                    .calling_convention = calling_convention,
                };
            }
        }
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
                    const capture_ownership = if (has_closure_ownership)
                        try readOwnershipModes(allocator, reader)
                    else
                        try defaultOwnershipModes(allocator, capture_count, .borrow_read);
                    try instructions.append(.{ .const_closure = .{
                        .dst = dst,
                        .function_id = closure_function_id,
                        .captures = captures,
                        .capture_ownership = capture_ownership,
                    } });
                },
                .alloc_struct => try instructions.append(.{ .alloc_struct = .{
                    .dst = try reader.takeInt(u32, .little),
                    .type_name = try readString(allocator, reader),
                } }),
                .alloc_enum => try instructions.append(.{ .alloc_enum = .{
                    .dst = try reader.takeInt(u32, .little),
                    .enum_type_name = try readString(allocator, reader),
                    .discriminant = try reader.takeInt(u32, .little),
                    .payload_src = blk: {
                        const raw = try reader.takeInt(i32, .little);
                        break :blk if (raw >= 0) @as(?u32, @intCast(raw)) else null;
                    },
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
                    .unsigned = if (has_unsigned_arith) (try reader.takeByte()) != 0 else false,
                } }),
                .modulo => try instructions.append(.{ .modulo = .{
                    .dst = try reader.takeInt(u32, .little),
                    .lhs = try reader.takeInt(u32, .little),
                    .rhs = try reader.takeInt(u32, .little),
                    .unsigned = if (has_unsigned_arith) (try reader.takeByte()) != 0 else false,
                } }),
                .convert => try instructions.append(.{ .convert = .{
                    .dst = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                    .to_float = (try reader.takeByte()) != 0,
                    .reinterpret = if (has_convert_reinterpret) (try reader.takeByte()) != 0 else false,
                } }),
                .bitwise => try instructions.append(.{ .bitwise = .{
                    .dst = try reader.takeInt(u32, .little),
                    .lhs = try reader.takeInt(u32, .little),
                    .rhs = try reader.takeInt(u32, .little),
                    .op = @enumFromInt(try reader.takeByte()),
                    .unsigned = (try reader.takeByte()) != 0,
                } }),
                .compare => try instructions.append(.{ .compare = .{
                    .dst = try reader.takeInt(u32, .little),
                    .lhs = try reader.takeInt(u32, .little),
                    .rhs = try reader.takeInt(u32, .little),
                    .op = @enumFromInt(try reader.takeByte()),
                    .unsigned = if (has_unsigned_arith) (try reader.takeByte()) != 0 else false,
                } }),
                .unary => try instructions.append(.{ .unary = .{
                    .dst = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                    .op = @enumFromInt(try reader.takeByte()),
                } }),
                .store_local => try instructions.append(.{ .store_local = .{
                    .local = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                    .borrow = (try reader.takeByte()) != 0,
                } }),
                .load_local => try instructions.append(.{ .load_local = .{
                    .dst = try reader.takeInt(u32, .little),
                    .local = try reader.takeInt(u32, .little),
                    .ownership = if (has_load_ownership) try readOwnershipMode(reader) else .borrow_read,
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
                .free_native_state => try instructions.append(.{ .free_native_state = .{
                    .state = try reader.takeInt(u32, .little),
                } }),
                .native_state_field_get => try instructions.append(.{ .native_state_field_get = .{
                    .dst = try reader.takeInt(u32, .little),
                    .state = try reader.takeInt(u32, .little),
                    .field_index = try reader.takeInt(u32, .little),
                    .field_ty = try readTypeRef(allocator, reader),
                    // KBCA carries the native-state move flag (same version as
                    // the load_indirect / array_get moved bytes).
                    .moved = if (has_load_indirect_moved) (try reader.takeByte()) != 0 else false,
                } }),
                .native_state_field_set => try instructions.append(.{ .native_state_field_set = .{
                    .state = try reader.takeInt(u32, .little),
                    .field_index = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                    .field_ty = try readTypeRef(allocator, reader),
                } }),
                .c_string_to_string => try instructions.append(.{ .c_string_to_string = .{
                    .dst = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                } }),
                .array_len => try instructions.append(.{ .array_len = .{
                    .dst = try reader.takeInt(u32, .little),
                    .array = try reader.takeInt(u32, .little),
                } }),
                .string_len => try instructions.append(.{ .string_len = .{
                    .dst = try reader.takeInt(u32, .little),
                    .string = try reader.takeInt(u32, .little),
                } }),
                .array_get => try instructions.append(.{ .array_get = .{
                    .dst = try reader.takeInt(u32, .little),
                    .array = try reader.takeInt(u32, .little),
                    .index = try reader.takeInt(u32, .little),
                    .ty = try readTypeRef(allocator, reader),
                    .borrow = (try reader.takeByte()) != 0,
                    // KBCA also carries the element-drain flag (same version as
                    // load_indirect's moved byte — both landed together).
                    .moved = if (has_load_indirect_moved) (try reader.takeByte()) != 0 else false,
                } }),
                .array_set => try instructions.append(.{ .array_set = .{
                    .array = try reader.takeInt(u32, .little),
                    .index = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                } }),
                .array_append => try instructions.append(.{ .array_append = .{
                    .array = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                } }),
                .enum_tag => try instructions.append(.{ .enum_tag = .{
                    .dst = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                } }),
                .enum_payload => try instructions.append(.{ .enum_payload = .{
                    .dst = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                    .payload_ty = try readTypeRef(allocator, reader),
                } }),
                .load_indirect => try instructions.append(.{ .load_indirect = .{
                    .dst = try reader.takeInt(u32, .little),
                    .ptr = try reader.takeInt(u32, .little),
                    .ty = try readTypeRef(allocator, reader),
                    .moved = if (has_load_indirect_moved) (try reader.takeByte()) != 0 else false,
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
                .call_virtual => try instructions.append(.{ .call_virtual = try readVirtualCall(allocator, reader) }),
                .call_value => {
                    var value = try readIndirectCall(allocator, reader);
                    value.param_ownership = if (has_indirect_call_ownership)
                        try readOwnershipModes(allocator, reader)
                    else
                        try defaultOwnershipModes(allocator, @as(u32, @intCast(value.args.len)), .owned);
                    try instructions.append(.{ .call_value = value });
                },
                .ret => try instructions.append(.{ .ret = .{
                    .src = blk: {
                        const raw = try reader.takeInt(i32, .little);
                        break :blk if (raw >= 0) @as(?u32, @intCast(raw)) else null;
                    },
                } }),
                .task_spawn => {
                    const call = try readCallParts(allocator, reader);
                    const result_ty = try readTypeRef(allocator, reader);
                    const native = (try reader.takeByte()) != 0;
                    const suspendable = (try reader.takeByte()) != 0;
                    const frame_slots = try reader.takeInt(u32, .little);
                    try instructions.append(.{ .task_spawn = .{
                        .dst = call.dst orelse return error.InvalidBytecode,
                        .callee = call.function_id,
                        .args = call.args,
                        .result_ty = result_ty,
                        .native = native,
                        .suspendable = suspendable,
                        .frame_slots = frame_slots,
                    } });
                },
                .task_spawn_ready => try instructions.append(.{ .task_spawn_ready = .{
                    .dst = try reader.takeInt(u32, .little),
                    .value = try reader.takeInt(u32, .little),
                    .ty = try readTypeRef(allocator, reader),
                } }),
                .task_await => try instructions.append(.{ .task_await = .{
                    .dst = try reader.takeInt(u32, .little),
                    .task = try reader.takeInt(u32, .little),
                    .ty = try readTypeRef(allocator, reader),
                } }),
                .task_cancel => try instructions.append(.{ .task_cancel = .{ .task = try reader.takeInt(u32, .little) } }),
                .task_detach => try instructions.append(.{ .task_detach = .{ .task = try reader.takeInt(u32, .little) } }),
                .task_yield => try instructions.append(.{ .task_yield = .{} }),
                .frame_get => try instructions.append(.{ .frame_get = .{
                    .dst = try reader.takeInt(u32, .little),
                    .frame = try reader.takeInt(u32, .little),
                    .slot = try reader.takeInt(u32, .little),
                    .ty = try readTypeRef(allocator, reader),
                } }),
                .frame_set => try instructions.append(.{ .frame_set = .{
                    .frame = try reader.takeInt(u32, .little),
                    .slot = try reader.takeInt(u32, .little),
                    .src = try reader.takeInt(u32, .little),
                    .ty = try readTypeRef(allocator, reader),
                } }),
                .task_is_complete => try instructions.append(.{ .task_is_complete = .{
                    .dst = try reader.takeInt(u32, .little),
                    .task = try reader.takeInt(u32, .little),
                } }),
                .task_sleep => try instructions.append(.{ .task_sleep = .{ .milliseconds = try reader.takeInt(u32, .little) } }),
                // VM-internal fused instructions are never serialized; a file
                // claiming to contain one is corrupt. Every real opcode is
                // decoded explicitly above, so the only tags reaching here are
                // the fused superinstructions.
                else => {
                    std.debug.assert(instruction.isFused(op));
                    return error.InvalidBytecode;
                },
            }
        }
        try functions.append(.{
            .id = function_id,
            .name = name,
            .param_count = param_count,
            .param_ownership = param_ownership,
            .param_types = param_types,
            .return_type = return_type,
            .return_ownership = return_ownership,
            .is_extern = is_extern,
            .foreign = foreign,
            .register_count = register_count,
            .local_count = local_count,
            .local_types = try local_types.toOwnedSlice(),
            .instructions = try instructions.toOwnedSlice(),
        });
    }

    return .{
        .constructs = try constructs.toOwnedSlice(),
        .construct_implementations = try construct_implementations.toOwnedSlice(),
        .types = try types.toOwnedSlice(),
        .enums = try enums.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
        .entry_function_id = if (raw_entry >= 0) @as(u32, @intCast(raw_entry)) else null,
    };
}
