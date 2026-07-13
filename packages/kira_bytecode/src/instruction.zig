const std = @import("std");
const ownership_mode = @import("ownership_mode.zig");

// Selects the byte format for a scalar -> String conversion (`String(x)`).
pub const StringFromScalarSource = enum(u8) { integer, float, boolean };

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
    string_from_scalar,
    string_char_at,
    string_substring,
    string_index_of,
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
    // Bitwise/shift ops. Appended after `convert` (before the fused group) so it
    // does not shift any earlier serialized tag. Carried by KBC8.
    bitwise,
    // Releases a native-state box created by `alloc_native_state`
    // (`nativeStateFree`). Appended after `bitwise` so no earlier serialized
    // tag shifts. Carried by KBC9.
    free_native_state,
    // Async task spine (deferred execution). Appended after `free_native_state`
    // so no earlier serialized tag shifts (the fused block below is never
    // serialized, so shifting ITS tags is safe). `task_spawn` captures callee +
    // eagerly-evaluated args without calling; `task_await` first-drives the
    // task (runs the deferred call) and yields its result — joining a
    // cancelled task or joining twice traps; `task_cancel` sets the
    // cooperative flag; `task_detach` drives and discards. `task_spawn_ready`
    // wraps a pure value as a completed task. Carried by KBCB.
    task_spawn,
    task_spawn_ready,
    task_await,
    task_cancel,
    task_detach,
    // Cooperative progress point: run the next queued task (if any) before the
    // current body continues. Carried by KBCC with the other task opcodes.
    task_yield,
    // Task-frame slot access for state-machine (suspendable) task bodies
    // (see the async transform in kira_ir). Carried by KBCC.
    frame_get,
    frame_set,
    // True when a task is no longer pending (park-until-complete join checks).
    // Carried by KBCC.
    task_is_complete,
    // Park the current task for at least N milliseconds (blocking sleep
    // outside a suspendable body). Carried by KBCC.
    task_sleep,
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
    divide: struct { dst: u32, lhs: u32, rhs: u32, unsigned: bool = false },
    modulo: struct { dst: u32, lhs: u32, rhs: u32, unsigned: bool = false },
    compare: struct { dst: u32, lhs: u32, rhs: u32, op: CompareOp, unsigned: bool = false },
    unary: struct { dst: u32, src: u32, op: UnaryOp },
    store_local: struct { local: u32, src: u32, borrow: bool = false },
    load_local: struct { dst: u32, local: u32, ownership: ownership_mode.OwnershipMode = .borrow_read },
    local_ptr: struct { dst: u32, local: u32 },
    subobject_ptr: struct { dst: u32, base: u32, offset: u32 },
    field_ptr: struct { dst: u32, base: u32, base_type_name: []const u8, field_index: u32, field_ty: TypeRef },
    recover_native_state: struct { dst: u32, state: u32, type_name: []const u8, type_id: u64 },
    // `moved` marks a checker-verified move-out of an array/enum/Any field from
    // a recovered native state (`let n = view.nodes; view.nodes = []`): the VM
    // takes ownership into dst and VOIDS the payload slot, so a later set/free
    // does not destroy the same payload again. Mirrors the LLVM backend's
    // native-state moved-read slot nulling. Carried by KBCA.
    native_state_field_get: struct { dst: u32, state: u32, field_index: u32, field_ty: TypeRef, moved: bool = false },
    native_state_field_set: struct { state: u32, field_index: u32, src: u32, field_ty: TypeRef },
    c_string_to_string: struct { dst: u32, src: u32 },
    array_len: struct { dst: u32, array: u32 },
    string_len: struct { dst: u32, string: u32 },
    // Scalar -> String conversion (`String(x)`); `source` picks the byte format.
    string_from_scalar: struct { dst: u32, src: u32, source: StringFromScalarSource },
    string_char_at: struct { dst: u32, string: u32, index: u32 },
    string_substring: struct { dst: u32, string: u32, start: u32, end: u32 },
    string_index_of: struct { dst: u32, string: u32, needle: u32 },
    // `borrow=true` marks an element read whose result is consumed only as a
    // non-escaping `borrow` argument to an immediately-following call (set by the
    // IR lowering, guarded so the array cannot be mutated/freed during that call).
    // The interpreter then aliases a managed element instead of deep-cloning it,
    // matching the native backend, which never copies a borrowed element.
    array_get: struct { dst: u32, array: u32, index: u32, ty: TypeRef, borrow: bool = false, moved: bool = false },
    array_set: struct { array: u32, index: u32, src: u32 },
    array_append: struct { array: u32, src: u32 },
    enum_tag: struct { dst: u32, src: u32 },
    enum_payload: struct { dst: u32, src: u32, payload_ty: TypeRef },
    // `moved` marks a checker-verified field move-out (`let x = obj.field`):
    // the VM takes ownership of the field's value and VOIDS the field slot, so
    // the base drops with only its remaining fields (Rust partial move) while
    // the moved value lives on in the destination register. Mirrors the LLVM
    // backend's moved-read storage nulling.
    load_indirect: struct { dst: u32, ptr: u32, ty: TypeRef, moved: bool = false },
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
    convert: struct { dst: u32, src: u32, to_float: bool, reinterpret: bool = false },
    bitwise: struct { dst: u32, lhs: u32, rhs: u32, op: BitOp, unsigned: bool = false },
    free_native_state: struct { state: u32 },
    // `native=true` when the callee is LLVM-compiled (hybrid): the deferred
    // call dispatches through the VM's native-call hook at first drive.
    // `suspendable=true` when the callee is a state-machine body: allocate a
    // `frame_slots` frame, seed the resume state, copy args into slots 2..,
    // and drive by status until complete.
    task_spawn: struct { dst: u32, callee: u32, args: []const u32, result_ty: TypeRef = .{ .kind = .void }, native: bool = false, suspendable: bool = false, frame_slots: u32 = 0 },
    task_spawn_ready: struct { dst: u32, value: u32, ty: TypeRef = .{ .kind = .void } },
    task_await: struct { dst: u32, task: u32, ty: TypeRef = .{ .kind = .void } },
    task_cancel: struct { task: u32 },
    task_detach: struct { task: u32 },
    task_yield: struct {},
    frame_get: struct { dst: u32, frame: u32, slot: u32, ty: TypeRef = .{ .kind = .void } },
    frame_set: struct { frame: u32, slot: u32, src: u32, ty: TypeRef = .{ .kind = .void } },
    task_is_complete: struct { dst: u32, task: u32 },
    task_sleep: struct { milliseconds: u32 },
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
    bit_not,
};

pub const BitOp = enum(u8) {
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
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
