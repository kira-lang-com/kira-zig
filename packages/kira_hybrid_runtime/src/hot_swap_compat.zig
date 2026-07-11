//! Hot-swap compatibility evaluation: can `new_module` replace `old_module`
//! under the live values the VM currently holds? Extracted from hot_swap.zig
//! (Core Law #5); hot_swap re-exports the public surface.
const std = @import("std");
const bytecode = @import("kira_bytecode");
const vm_runtime = @import("kira_vm_runtime");

const FunctionIdMap = vm_runtime.reload.FunctionIdMap;

pub const Evaluation = union(enum) {
    compatible: FunctionIdMap,
    rejected: Rejection,
};

pub const Rejection = struct {
    reason: Reason,
    /// Name of the offending type/function when applicable (borrows the OLD
    /// module's memory, which outlives the rejection handling).
    detail: []const u8 = "",

    pub const Reason = enum {
        type_layout_changed,
        type_removed,
        enum_layout_changed,
        enum_removed,
        live_function_missing,
        live_function_signature_changed,
        live_function_ambiguous,

        pub fn text(self: Reason) []const u8 {
            return switch (self) {
                .type_layout_changed => "struct layout changed",
                .type_removed => "struct removed",
                .enum_layout_changed => "enum layout changed",
                .enum_removed => "enum removed",
                .live_function_missing => "live callback's function removed",
                .live_function_signature_changed => "live callback's signature changed",
                .live_function_ambiguous => "live callback's name is ambiguous",
            };
        }
    };
};

/// Decide whether `new_module` can replace `old_module` under the live values
/// currently held by `vm`. On success returns the old-id -> new-id function
/// map (caller owns; covers every uniquely-matched same-signature function,
/// verified to include every id a live closure references).
pub fn evaluate(
    allocator: std.mem.Allocator,
    vm: *vm_runtime.Vm,
    old_module: *const bytecode.Module,
    new_module: *const bytecode.Module,
) !Evaluation {
    // 1. Every old struct type must survive with an identical field layout:
    // live heap structs/native-state boxes store fields positionally per the
    // old TypeDecl, and the new code indexes fields per the new TypeDecl.
    for (old_module.types) |old_type| {
        const new_type = findType(new_module, old_type.name) orelse
            return .{ .rejected = .{ .reason = .type_removed, .detail = old_type.name } };
        if (!typeLayoutEqual(old_type, new_type))
            return .{ .rejected = .{ .reason = .type_layout_changed, .detail = old_type.name } };
    }
    // 2. Same for enums (discriminants and payload shapes are baked into live
    // enum values and native-lowered blocks).
    for (old_module.enums) |old_enum| {
        const new_enum = findEnum(new_module, old_enum.name) orelse
            return .{ .rejected = .{ .reason = .enum_removed, .detail = old_enum.name } };
        if (!enumLayoutEqual(old_enum, new_enum))
            return .{ .rejected = .{ .reason = .enum_layout_changed, .detail = old_enum.name } };
    }

    // 3. Function remap: match old functions to new by name (unique names
    // only) with identical signatures. Bodies may change freely — that is the
    // point of the reload.
    var map: FunctionIdMap = .empty;
    errdefer map.deinit(allocator);
    for (old_module.functions) |old_fn| {
        const new_fn = findUniqueFunction(new_module, old_fn.name) orelse continue;
        if (!signatureEqual(old_fn, new_fn)) continue;
        try map.put(allocator, old_fn.id, new_fn.id);
    }

    // 4. Every function id referenced by a LIVE closure (heap closure object
    // or a closure block exported to native) must be in the map, else the
    // remap would leave a callback pointing at the wrong or a missing
    // function.
    var live_ids = try vm_runtime.reload.collectLiveFunctionIds(vm, allocator);
    defer live_ids.deinit(allocator);
    var it = live_ids.keyIterator();
    while (it.next()) |id| {
        if (map.get(id.*) != null) continue;
        const old_fn = old_module.findFunctionById(id.*) orelse {
            map.deinit(allocator);
            return .{ .rejected = .{ .reason = .live_function_missing } };
        };
        const rejection: Rejection = blk: {
            if (!functionNameUnique(old_module, old_fn.name) or !newNameUniqueOrAbsent(new_module, old_fn.name))
                break :blk .{ .reason = .live_function_ambiguous, .detail = old_fn.name };
            if (findUniqueFunction(new_module, old_fn.name) == null)
                break :blk .{ .reason = .live_function_missing, .detail = old_fn.name };
            break :blk .{ .reason = .live_function_signature_changed, .detail = old_fn.name };
        };
        map.deinit(allocator);
        return .{ .rejected = rejection };
    }

    return .{ .compatible = map };
}

fn findType(module: *const bytecode.Module, name: []const u8) ?bytecode.TypeDecl {
    for (module.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
    }
    return null;
}

fn findEnum(module: *const bytecode.Module, name: []const u8) ?bytecode.EnumTypeDecl {
    for (module.enums) |enum_decl| {
        if (std.mem.eql(u8, enum_decl.name, name)) return enum_decl;
    }
    return null;
}

fn findUniqueFunction(module: *const bytecode.Module, name: []const u8) ?bytecode.Function {
    var found: ?bytecode.Function = null;
    for (module.functions) |function_decl| {
        if (!std.mem.eql(u8, function_decl.name, name)) continue;
        if (found != null) return null;
        found = function_decl;
    }
    return found;
}

fn functionNameUnique(module: *const bytecode.Module, name: []const u8) bool {
    var count: usize = 0;
    for (module.functions) |function_decl| {
        if (std.mem.eql(u8, function_decl.name, name)) count += 1;
    }
    return count == 1;
}

fn newNameUniqueOrAbsent(module: *const bytecode.Module, name: []const u8) bool {
    var count: usize = 0;
    for (module.functions) |function_decl| {
        if (std.mem.eql(u8, function_decl.name, name)) count += 1;
    }
    return count <= 1;
}

fn typeLayoutEqual(a: bytecode.TypeDecl, b: bytecode.TypeDecl) bool {
    if (a.kind != b.kind) return false;
    if (a.fields.len != b.fields.len) return false;
    for (a.fields, b.fields) |field_a, field_b| {
        if (!std.mem.eql(u8, field_a.name, field_b.name)) return false;
        if (!typeRefEqual(field_a.ty, field_b.ty)) return false;
    }
    return true;
}

fn enumLayoutEqual(a: bytecode.EnumTypeDecl, b: bytecode.EnumTypeDecl) bool {
    if (a.variants.len != b.variants.len) return false;
    for (a.variants, b.variants) |variant_a, variant_b| {
        if (!std.mem.eql(u8, variant_a.name, variant_b.name)) return false;
        if (variant_a.discriminant != variant_b.discriminant) return false;
        const payload_a = variant_a.payload_ty;
        const payload_b = variant_b.payload_ty;
        if ((payload_a == null) != (payload_b == null)) return false;
        if (payload_a != null and !typeRefEqual(payload_a.?, payload_b.?)) return false;
    }
    return true;
}

fn signatureEqual(a: bytecode.Function, b: bytecode.Function) bool {
    if (a.param_count != b.param_count) return false;
    if (a.param_types.len != b.param_types.len) return false;
    if (!typeRefEqual(a.return_type, b.return_type)) return false;
    for (a.param_types, b.param_types) |param_a, param_b| {
        if (!typeRefEqual(param_a, param_b)) return false;
    }
    if (a.param_ownership.len != b.param_ownership.len) return false;
    for (a.param_ownership, b.param_ownership) |own_a, own_b| {
        if (own_a != own_b) return false;
    }
    return true;
}

fn typeRefEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a.kind != b.kind) return false;
    const name_a = a.name orelse "";
    const name_b = b.name orelse "";
    if (!std.mem.eql(u8, name_a, name_b)) return false;
    const constraint_a = a.construct_constraint;
    const constraint_b = b.construct_constraint;
    if ((constraint_a == null) != (constraint_b == null)) return false;
    if (constraint_a != null and !std.mem.eql(u8, constraint_a.?.construct_name, constraint_b.?.construct_name)) return false;
    return true;
}

// --- test helpers shared with hot_swap.zig's swap-drive tests --------------

pub fn testFunction(id: u32, name: []const u8) bytecode.Function {
    return .{ .id = id, .name = name, .register_count = 0, .local_count = 0, .instructions = &.{} };
}

pub fn testModule(functions: []bytecode.Function, types: []bytecode.TypeDecl) bytecode.Module {
    return .{ .functions = functions, .types = types, .entry_function_id = null };
}

const testing = std.testing;

test "evaluate maps same-named functions and accepts identical layouts" {
    var vm = vm_runtime.Vm.init(testing.allocator);
    defer vm.deinit();

    var old_fns = [_]bytecode.Function{ testFunction(1, "main"), testFunction(2, "onFrame") };
    var new_fns = [_]bytecode.Function{ testFunction(5, "onFrame"), testFunction(6, "main") };
    var old_module = testModule(&old_fns, &.{});
    var new_module = testModule(&new_fns, &.{});

    var evaluation = try evaluate(testing.allocator, &vm, &old_module, &new_module);
    defer if (evaluation == .compatible) evaluation.compatible.deinit(testing.allocator);
    try testing.expect(evaluation == .compatible);
    try testing.expectEqual(@as(u32, 6), evaluation.compatible.get(1).?);
    try testing.expectEqual(@as(u32, 5), evaluation.compatible.get(2).?);
}

test "evaluate rejects changed struct layout" {
    var vm = vm_runtime.Vm.init(testing.allocator);
    defer vm.deinit();

    var old_fields = [_]bytecode.Field{.{ .name = "x", .ty = .{ .kind = .integer } }};
    var new_fields = [_]bytecode.Field{.{ .name = "x", .ty = .{ .kind = .float } }};
    var old_types = [_]bytecode.TypeDecl{.{ .name = "P", .fields = &old_fields }};
    var new_types = [_]bytecode.TypeDecl{.{ .name = "P", .fields = &new_fields }};
    var no_fns = [_]bytecode.Function{};
    var old_module = testModule(&no_fns, &old_types);
    var new_module = testModule(&no_fns, &new_types);

    const evaluation = try evaluate(testing.allocator, &vm, &old_module, &new_module);
    try testing.expect(evaluation == .rejected);
    try testing.expectEqual(Rejection.Reason.type_layout_changed, evaluation.rejected.reason);
}

test "evaluate rejects when a live closure's function vanished" {
    var vm = vm_runtime.Vm.init(testing.allocator);
    defer vm.deinit();

    const closure = try vm.heap.allocClosureObject();
    closure.* = .{ .function_id = 2, .captures = &.{} };
    _ = try vm.heap.registerClosure(closure);

    var old_fns = [_]bytecode.Function{ testFunction(1, "main"), testFunction(2, "onFrame") };
    var new_fns = [_]bytecode.Function{testFunction(1, "main")};
    var old_module = testModule(&old_fns, &.{});
    var new_module = testModule(&new_fns, &.{});

    const evaluation = try evaluate(testing.allocator, &vm, &old_module, &new_module);
    try testing.expect(evaluation == .rejected);
    try testing.expectEqual(Rejection.Reason.live_function_missing, evaluation.rejected.reason);
}

test "evaluate rejects live closure signature change, allows dead one" {
    var vm = vm_runtime.Vm.init(testing.allocator);
    defer vm.deinit();

    var changed_new = testFunction(2, "onFrame");
    changed_new.param_count = 1;
    const params = [_]bytecode.TypeRef{.{ .kind = .integer }};
    changed_new.param_types = &params;

    var old_fns = [_]bytecode.Function{ testFunction(1, "main"), testFunction(2, "onFrame") };
    var new_fns = [_]bytecode.Function{ testFunction(1, "main"), changed_new };
    var old_module = testModule(&old_fns, &.{});
    var new_module = testModule(&new_fns, &.{});

    // No live closure on fn 2: signature change is fine (the map just skips it).
    var ok_eval = try evaluate(testing.allocator, &vm, &old_module, &new_module);
    try testing.expect(ok_eval == .compatible);
    try testing.expect(ok_eval.compatible.get(2) == null);
    ok_eval.compatible.deinit(testing.allocator);

    // With a live closure on fn 2 it must reject.
    const closure = try vm.heap.allocClosureObject();
    closure.* = .{ .function_id = 2, .captures = &.{} };
    _ = try vm.heap.registerClosure(closure);
    const evaluation = try evaluate(testing.allocator, &vm, &old_module, &new_module);
    try testing.expect(evaluation == .rejected);
    try testing.expectEqual(Rejection.Reason.live_function_signature_changed, evaluation.rejected.reason);
}
