//! Value/expectation decoding for the `kira test` Test-construct runner.
//!
//! Pure helpers (no `DeveloperFacade` state): they read a Test's `__expect()`
//! `Result<T, TestFailure>` value, compare a Test's produced value against the
//! expected one (scalars, strings, payload-less and payload-carrying enums), and
//! resolve function/enum metadata out of a bytecode module. Extracted from
//! developer.zig to keep that file within the repo size budget.

const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const vm_runtime = @import("kira_vm_runtime");

pub const TestExpectation = union(enum) {
    ok: runtime_abi.Value,
    expected_error: ExpectedKiraError,
};

pub const ExpectedKiraError = struct {
    kind: []const u8,
    message: []const u8,
};

pub fn decodeTestExpectation(vm: *vm_runtime.Vm, module: *const bytecode.Module, result_ty: bytecode.TypeRef, value: runtime_abi.Value) !TestExpectation {
    const result_name = result_ty.name orelse return error.ExpectedResultTypeMissing;
    const slots = enumSlots(value) orelse return error.ExpectedResultValueMissing;
    const tag = enumTag(slots) orelse return error.ExpectedResultTagMissing;
    const variant = enumVariantName(module, result_name, tag) orelse return error.ExpectedResultVariantMissing;
    if (std.mem.eql(u8, variant, "Ok")) return .{ .ok = slots[1] };
    if (std.mem.eql(u8, variant, "Error")) return .{ .expected_error = try decodeExpectedKiraError(vm, module, slots[1]) };
    return error.ExpectedResultVariantMissing;
}

pub fn decodeExpectedKiraError(vm: *vm_runtime.Vm, module: *const bytecode.Module, value: runtime_abi.Value) !ExpectedKiraError {
    const failure_name = if (value == .raw_ptr and value.raw_ptr != 0) vm.managedStructTypeName(value.raw_ptr) orelse "TestFailure" else "TestFailure";
    const slots = enumSlots(value) orelse return error.ExpectedFailureValueMissing;
    const tag = enumTag(slots) orelse return error.ExpectedFailureTagMissing;
    return .{
        .kind = enumVariantName(module, failure_name, tag) orelse return error.ExpectedFailureVariantMissing,
        .message = if (slots[1] == .string) slots[1].string else "",
    };
}

pub fn enumSlots(value: runtime_abi.Value) ?[*]align(1) const runtime_abi.Value {
    if (value != .raw_ptr or value.raw_ptr == 0) return null;
    return @ptrFromInt(value.raw_ptr);
}

pub fn enumTag(slots: [*]align(1) const runtime_abi.Value) ?u32 {
    if (slots[0] != .integer or slots[0].integer < 0) return null;
    return @intCast(slots[0].integer);
}

pub fn enumVariantName(module: *const bytecode.Module, enum_name: []const u8, discriminant: u32) ?[]const u8 {
    for (module.enums) |enum_decl| {
        if (!std.mem.eql(u8, enum_decl.name, enum_name)) continue;
        for (enum_decl.variants) |variant| if (variant.discriminant == discriminant) return variant.name;
    }
    return null;
}

pub fn valuesEqual(module: *const bytecode.Module, expected: runtime_abi.Value, actual: runtime_abi.Value, ty: bytecode.TypeRef) bool {
    if (ty.kind == .enum_instance) return enumValuesEqual(module, expected, actual, ty.name orelse return false);
    if (std.meta.activeTag(expected) != std.meta.activeTag(actual)) return false;
    return switch (expected) {
        .void => true,
        .integer => |value| value == actual.integer,
        .float => |value| value == actual.float,
        .string => |value| std.mem.eql(u8, value, actual.string),
        .boolean => |value| value == actual.boolean,
        .raw_ptr => |value| value == actual.raw_ptr,
    };
}

pub fn enumValuesEqual(module: *const bytecode.Module, expected: runtime_abi.Value, actual: runtime_abi.Value, enum_name: []const u8) bool {
    const expected_slots = enumSlots(expected) orelse return false;
    const actual_slots = enumSlots(actual) orelse return false;
    const expected_tag = enumTag(expected_slots) orelse return false;
    const actual_tag = enumTag(actual_slots) orelse return false;
    if (expected_tag != actual_tag) return false;
    const payload_ty = enumVariantPayloadType(module, enum_name, expected_tag) orelse return true;
    return valuesEqual(module, expected_slots[1], actual_slots[1], payload_ty);
}

pub fn enumVariantPayloadType(module: *const bytecode.Module, enum_name: []const u8, discriminant: u32) ?bytecode.TypeRef {
    for (module.enums) |enum_decl| {
        if (!std.mem.eql(u8, enum_decl.name, enum_name)) continue;
        for (enum_decl.variants) |variant| if (variant.discriminant == discriminant) return variant.payload_ty;
    }
    return null;
}

pub fn findFunctionByName(module: bytecode.Module, name: []const u8) ?bytecode.Function {
    for (module.functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
    return null;
}
