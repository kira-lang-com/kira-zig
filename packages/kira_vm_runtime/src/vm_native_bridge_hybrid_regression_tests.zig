const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");

const Vm = @import("vm.zig").Vm;
const ArrayObject = @import("ownership.zig").ArrayObject;

fn modeModule() bytecode.Module {
    return .{
        .types = &.{},
        .enums = @constCast(&[_]bytecode.EnumTypeDecl{.{
            .name = "Mode",
            .variants = @constCast(&[_]bytecode.EnumVariantDecl{
                .{ .name = "None", .discriminant = 0 },
                .{ .name = "Surface", .discriminant = 1 },
            }),
        }}),
        .functions = &.{},
        .entry_function_id = null,
    };
}

test "copyEnumToNativeLayout follows wrapper slots to the managed enum" {
    const module = modeModule();

    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();

    const runtime_enum = try vm.allocateEnum("Mode", 1, .{ .void = {} });
    defer vm.dropManagedValue(.{ .raw_ptr = runtime_enum });

    var wrapper = runtime_abi.Value{ .raw_ptr = runtime_enum };
    const native_ptr = try vm.copyEnumToNativeLayout(&module, "Mode", @intFromPtr(&wrapper));
    defer vm.destroyEnumNativeLayout(&module, "Mode", native_ptr);

    const words: [*]const u64 = @ptrFromInt(native_ptr);
    try std.testing.expectEqual(@as(u64, 1), words[0]);
    try std.testing.expectEqual(@as(u64, 0), words[1]);
}

test "materializeNativeResult copies native array returns into managed arrays" {
    const module = bytecode.Module{
        .types = &.{},
        .functions = &.{},
        .entry_function_id = null,
    };

    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();

    const array_ty = bytecode.TypeRef{ .kind = .array, .name = "I64" };
    const runtime_array_ptr = try vm.allocateArray(2);
    const runtime_array: *ArrayObject = @ptrFromInt(runtime_array_ptr);
    runtime_array.items[0] = runtime_abi.bridgeValueFromValue(.{ .integer = 11 });
    runtime_array.items[1] = runtime_abi.bridgeValueFromValue(.{ .integer = 22 });

    const native_ptr = try vm.copyArrayToNativeLayout(&module, array_ty, runtime_array_ptr);
    vm.dropManagedValue(.{ .raw_ptr = runtime_array_ptr });

    const materialized = try vm.materializeNativeResult(&module, array_ty, .{ .raw_ptr = native_ptr });
    defer vm.dropManagedValue(materialized);

    try std.testing.expect(materialized == .raw_ptr);
    const array_after: *const ArrayObject = @ptrFromInt(materialized.raw_ptr);
    try std.testing.expectEqual(@as(usize, 2), array_after.len);
    try std.testing.expectEqual(@as(i64, 11), runtime_abi.bridgeValueToValue(array_after.items[0]).integer);
    try std.testing.expectEqual(@as(i64, 22), runtime_abi.bridgeValueToValue(array_after.items[1]).integer);
}

test "materializeNativeResult copies native enum returns into managed enums" {
    const module = modeModule();

    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();

    const enum_ty = bytecode.TypeRef{ .kind = .enum_instance, .name = "Mode" };
    const runtime_enum = try vm.allocateEnum("Mode", 1, .{ .void = {} });
    const native_ptr = try vm.copyEnumToNativeLayout(&module, "Mode", runtime_enum);
    vm.dropManagedValue(.{ .raw_ptr = runtime_enum });

    const materialized = try vm.materializeNativeResult(&module, enum_ty, .{ .raw_ptr = native_ptr });
    defer vm.dropManagedValue(materialized);

    try std.testing.expect(materialized == .raw_ptr);
    const slots: [*]const runtime_abi.Value = @ptrFromInt(materialized.raw_ptr);
    try std.testing.expectEqual(@as(i64, 1), slots[0].integer);
    try std.testing.expect(slots[1] == .void);
}
