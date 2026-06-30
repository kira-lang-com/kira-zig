const std = @import("std");
const ownership_mode = @import("ownership_mode.zig");

pub const OpCode = enum(u8) {
    const_int,
    const_float,
    const_string,
    const_bool,
    const_null_ptr,
    const_function,
    const_closure,
    alloc_struct,
    alloc_enum,
    alloc_native_state,
    alloc_array,
    add,
    subtract,
    multiply,
    divide,
    modulo,
    compare,
    unary,
    store_local,
    load_local,
    local_ptr,
    subobject_ptr,
    field_ptr,
    recover_native_state,
    native_state_field_get,
    native_state_field_set,
    c_string_to_string,
    array_len,
    string_len,
    array_get,
    array_set,
    array_append,
    enum_tag,
    enum_payload,
    load_indirect,
    store_indirect,
    copy_indirect,
    branch,
    jump,
    label,
    print,
    call_runtime,
    call_native,
    call_virtual,
    call_value,
    ret,
    // Numeric Int<->Float cast. Appended after the last pre-existing serialized
    // opcode (rather than inserted mid-enum) so it does not shift the serialized
    // tag of any earlier instruction; old KBC modules still deserialize. New
    // modules carrying it are written as KBC7.
    convert,
    // --- VM-internal fused instructions ------------------------------------
    // Produced exclusively by the VM's decode pass (vm_prepare.zig) inside its
    // private per-function code copies. They never appear in compiler output
    // or serialized modules (serialize/deserialize reject them), and each one
    // collapses a hot multi-instruction pattern whose intermediate registers
    // are provably dead outside the pattern. Branch targets are direct pc
    // offsets (the decode pass resolves labels before fusing).
    fused_compare_branch,
    fused_compare_const_branch,
    fused_cmp_local_const_branch,
    fused_arith_locals_store,
    fused_arith_local_const_store,
    fused_arith_locals_ret,
    fused_array_bind_local,
    fused_array_field_load,
};

pub const Instruction = union(OpCode) {
    const_int: struct { dst: u32, value: i64 },
    const_float: struct { dst: u32, value: f64 },
    const_string: struct { dst: u32, value: []const u8 },
    const_bool: struct { dst: u32, value: bool },
    const_null_ptr: struct { dst: u32 },
    const_function: struct { dst: u32, function_id: u32, representation: FunctionConstRepresentation = .callable_value },
    const_closure: struct { dst: u32, function_id: u32, captures: []const u32, capture_ownership: []const ownership_mode.OwnershipMode = &.{} },
    alloc_struct: struct { dst: u32, type_name: []const u8 },
    alloc_enum: struct { dst: u32, enum_type_name: []const u8, discriminant: u32, payload_src: ?u32 = null },
    alloc_native_state: struct { dst: u32, src: u32, type_name: []const u8, type_id: u64 },
    alloc_array: struct { dst: u32, len: u32 },
    add: struct { dst: u32, lhs: u32, rhs: u32 },
    subtract: struct { dst: u32, lhs: u32, rhs: u32 },
    multiply: struct { dst: u32, lhs: u32, rhs: u32 },
    divide: struct { dst: u32, lhs: u32, rhs: u32 },
    modulo: struct { dst: u32, lhs: u32, rhs: u32 },
    compare: struct { dst: u32, lhs: u32, rhs: u32, op: CompareOp },
    unary: struct { dst: u32, src: u32, op: UnaryOp },
    store_local: struct { local: u32, src: u32, borrow: bool = false },
    load_local: struct { dst: u32, local: u32, ownership: ownership_mode.OwnershipMode = .borrow_read },
    local_ptr: struct { dst: u32, local: u32 },
    subobject_ptr: struct { dst: u32, base: u32, offset: u32 },
    field_ptr: struct { dst: u32, base: u32, base_type_name: []const u8, field_index: u32, field_ty: TypeRef },
    recover_native_state: struct { dst: u32, state: u32, type_name: []const u8, type_id: u64 },
    native_state_field_get: struct { dst: u32, state: u32, field_index: u32, field_ty: TypeRef },
    native_state_field_set: struct { state: u32, field_index: u32, src: u32, field_ty: TypeRef },
    c_string_to_string: struct { dst: u32, src: u32 },
    array_len: struct { dst: u32, array: u32 },
    string_len: struct { dst: u32, string: u32 },
    // `borrow=true` marks an element read whose result is consumed only as a
    // non-escaping `borrow` argument to an immediately-following call (set by the
    // IR lowering, guarded so the array cannot be mutated/freed during that call).
    // The interpreter then aliases a managed element instead of deep-cloning it,
    // matching the native backend, which never copies a borrowed element.
    array_get: struct { dst: u32, array: u32, index: u32, ty: TypeRef, borrow: bool = false },
    array_set: struct { array: u32, index: u32, src: u32 },
    array_append: struct { array: u32, src: u32 },
    enum_tag: struct { dst: u32, src: u32 },
    enum_payload: struct { dst: u32, src: u32, payload_ty: TypeRef },
    load_indirect: struct { dst: u32, ptr: u32, ty: TypeRef },
    store_indirect: struct { ptr: u32, src: u32, ty: TypeRef },
    copy_indirect: struct { dst_ptr: u32, src_ptr: u32, type_name: []const u8 },
    branch: struct { condition: u32, true_label: u32, false_label: u32 },
    jump: struct { label: u32 },
    label: struct { id: u32 },
    print: struct { src: u32, ty: TypeRef },
    call_runtime: struct { function_id: u32, args: []const u32, dst: ?u32 = null },
    call_native: struct { function_id: u32, args: []const u32, dst: ?u32 = null, return_ty: TypeRef = .{ .kind = .void } },
    call_virtual: struct { receiver: u32, static_type_name: []const u8, method_name: []const u8, args: []const u32, return_ty: TypeRef = .{ .kind = .void }, dst: ?u32 = null },
    call_value: struct { callee: u32, args: []const u32, param_ownership: []const ownership_mode.OwnershipMode = &.{}, dst: ?u32 = null },
    ret: struct { src: ?u32 = null },
    // Numeric cast; `to_float` selects the target (true => Int->Float, false =>
    // Float->Int, truncating/saturating). Placed after `ret` to match the
    // OpCode enum's serialization-stable ordering.
    convert: struct { dst: u32, src: u32, to_float: bool },
    // VM-internal fused forms; see the OpCode comment above.
    // compare(dst, lhs, rhs); branch(dst, ...) where dst is pattern-private.
    fused_compare_branch: struct { lhs: u32, rhs: u32, op: CompareOp, true_target: u32, false_target: u32 },
    // const_int(c, imm); compare(dst, lhs, c); branch(dst, ...).
    fused_compare_const_branch: struct { lhs: u32, imm: i64, op: CompareOp, true_target: u32, false_target: u32 },
    // load_local(a, local); const_int(c, imm); compare(dst, a, c); branch(dst, ...).
    fused_cmp_local_const_branch: struct { local: u32, imm: i64, op: CompareOp, true_target: u32, false_target: u32 },
    // load_local(a, lhs); load_local(b, rhs); <arith>(d, a, b); store_local(dst, d).
    fused_arith_locals_store: struct { kind: ArithKind, lhs_local: u32, rhs_local: u32, dst_local: u32 },
    // load_local(a, lhs); const_int(c, imm); <arith>(d, a, c); store_local(dst, d).
    fused_arith_local_const_store: struct { kind: ArithKind, lhs_local: u32, imm: i64, dst_local: u32 },
    // load_local(a, lhs); load_local(b, rhs); <arith>(d, a, b); ret(d) — the
    // entire body of a leaf arithmetic function.
    fused_arith_locals_ret: struct { kind: ArithKind, lhs_local: u32, rhs_local: u32 },
    // array_get(e, array, index, ffi_struct); load_local(p, dst_local, borrow);
    // copy_indirect(dst=p, src=e) — the `for x in array` element binding. The
    // decode pass proves the binding local is read-only and the array outlives
    // it, so the interpreter aliases the element instead of deep-cloning it
    // twice (matching the native backend, which never copies borrowed loop
    // elements). type_name preserves the clone fallback for native-layout
    // elements.
    fused_array_bind_local: struct { array: u32, index: u32, dst_local: u32, type_name: []const u8 },
    // array_get(e, array, index, ffi_struct, borrow); field_ptr(p, e, field_index,
    // scalar); load_indirect(dst, p, scalar) — reading one scalar field of an
    // array element (`arr[i].f`). The two intermediates are pattern-private, so the
    // element is borrowed, the scalar read directly, and a native-layout element's
    // materialization freed in one step. Restricted to scalar fields (int/float/
    // bool) whose loaded value owns no heap, so the immediate free is always safe.
    fused_array_field_load: struct { dst: u32, array: u32, index: u32, elem_ty: TypeRef, field_index: u32 },
};

/// True for the VM-internal fused superinstructions — the ones produced only by
/// the VM's decode pass (vm_prepare.zig), never by the compiler or serializer.
///
/// Single source of truth so passes that treat every fused op identically
/// (serialize/deserialize reject them, countRegisterReads never sees them) can
/// gate on one predicate instead of listing all fused tags. Adding a fused
/// superinstruction needs no edit here: it is a range check over the contiguous
/// trailing block of fused tags, an invariant the comptime guard below proves.
pub fn isFused(op: OpCode) bool {
    return @intFromEnum(op) >= @intFromEnum(OpCode.fused_compare_branch);
}

comptime {
    // Guard the range assumption behind isFused: every OpCode tag at or after
    // the first fused op must be a `fused_*` tag, and none before it may be. A
    // future non-fused opcode appended after the fused block (or a fused op
    // inserted before it) fails the build here and forces a real decision
    // instead of silently mis-classifying instructions.
    const first_fused = @intFromEnum(OpCode.fused_compare_branch);
    for (std.meta.fields(OpCode)) |field| {
        const at_or_after = field.value >= first_fused;
        const named_fused = std.mem.startsWith(u8, field.name, "fused_");
        if (at_or_after != named_fused)
            @compileError("fused opcodes must form a contiguous trailing block; offender: " ++ field.name);
    }
}

test "isFused classifies every opcode by its fused_ naming" {
    // Enumerate the whole OpCode space so a new tag that slips outside the
    // fused block — or a fused tag the range check misses — fails here instead
    // of being silently mis-handled by the serializer / register-read analysis.
    inline for (std.meta.fields(OpCode)) |field| {
        const op = @field(OpCode, field.name);
        try std.testing.expectEqual(
            std.mem.startsWith(u8, field.name, "fused_"),
            isFused(op),
        );
    }
}

pub const ArithKind = enum(u8) {
    add,
    subtract,
    multiply,
};

pub const FunctionConstRepresentation = enum(u8) {
    callable_value,
    native_callback,
};

pub const CompareOp = enum(u8) {
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

pub const UnaryOp = enum(u8) {
    negate,
    not,
};

pub const TypeRef = struct {
    kind: Kind,
    name: ?[]const u8 = null,
    construct_constraint: ?ConstructConstraint = null,

    pub const ConstructConstraint = struct {
        construct_name: []const u8,
    };

    pub const Kind = enum(u8) {
        void,
        integer,
        float,
        string,
        boolean,
        construct_any,
        array,
        raw_ptr,
        ffi_struct,
        enum_instance,
    };
};
