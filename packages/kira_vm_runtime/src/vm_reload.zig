//! VM-side hot-reload support: remapping live function references when the
//! executing bytecode module is swapped in place (live hot reload).
//!
//! The VM itself is module-agnostic — the module is a per-call parameter and
//! all module-derived caches are keyed by module POINTER (vm.zig preparedFor /
//! ensureTypeCaches), so loading the replacement module at a FRESH address
//! makes those caches rebuild automatically. What does NOT fix itself is every
//! live value that captured a module-relative function id or a pointer into
//! module memory:
//!
//!   - heap `ClosureObject.function_id` (ownership.zig) — module-global u32 ids
//!     that a recompile may reassign,
//!   - exported native closure blocks (`[u64 function_id, u64 capture_count,
//!     captures...]`, vm_native_bridge.zig exportRuntimeClosureToNative) whose
//!     header word native code reads on every callback,
//!   - `NativeStateBox.module` / `type_name` (vm_types.zig) — the app-state
//!     roots native code holds across frames.
//!
//! The old module MUST stay allocated after a swap (the hybrid runtime retires
//! it instead of freeing): heap struct/enum records and constant-string values
//! borrow name/byte slices from module memory for as long as the value lives.
const std = @import("std");
const bytecode = @import("kira_bytecode");
const vm_mod = @import("vm.zig");
const vm_types = @import("vm_types.zig");

const Vm = vm_mod.Vm;

/// Map from old-module function id to the same-named function's id in the new
/// module. Identity entries are stored too so lookups never miss for mapped
/// functions.
pub const FunctionIdMap = std.AutoHashMapUnmanaged(u32, u32);

pub const RemapError = error{
    /// A live closure references a function id with no equivalent in the map.
    UnmappedLiveFunction,
};

/// True when the VM is at a safe swap point with respect to async tasks: no
/// queued-but-unrun task and no live suspended task. Queued VmTasks capture
/// prepared-function INDICES at spawn (vm_prepare.zig), which are meaningless
/// against a rebuilt PreparedModule, so a swap must wait until the queue is
/// drained.
pub fn tasksIdle(vm: *const Vm) bool {
    if (vm.current_task != null) return false;
    if (vm.task_queue_head < vm.task_queue.items.len) return false;
    for (vm.live_tasks.items) |task| {
        if (task.state == .pending) return false;
    }
    return true;
}

/// Collect every function id referenced by a live closure — heap closure
/// objects plus exported native closure blocks. These are the ids that must
/// have a compatible equivalent in the replacement module.
pub fn collectLiveFunctionIds(vm: *const Vm, allocator: std.mem.Allocator) !std.AutoHashMapUnmanaged(u32, void) {
    var ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    errdefer ids.deinit(allocator);
    var iterator = vm.heap.objects.iterator();
    while (iterator.next()) |entry| {
        switch (entry.record.kind) {
            .closure => |closure| try ids.put(allocator, closure.function_id, {}),
            else => {},
        }
    }
    for (vm.exported_native_closures.items) |exported| {
        const words: [*]const u64 = @ptrFromInt(exported.native_ptr);
        const id_word = words[0];
        if (id_word <= std.math.maxInt(u32)) {
            try ids.put(allocator, @intCast(id_word), {});
        }
    }
    return ids;
}

/// Rewrite every live closure's function id through `map`. Called at the swap
/// point (VM idle, single thread) AFTER the caller verified every live id is
/// mapped; an unmapped id here means the compatibility check was skipped and
/// the swap must be aborted before any header was rewritten — so this walks
/// read-only first, then commits.
pub fn remapLiveFunctionIds(vm: *Vm, map: *const FunctionIdMap) RemapError!void {
    // Verify pass: nothing is mutated until every live reference resolves.
    var verify_iterator = vm.heap.objects.iterator();
    while (verify_iterator.next()) |entry| {
        switch (entry.record.kind) {
            .closure => |closure| {
                if (map.get(closure.function_id) == null) return RemapError.UnmappedLiveFunction;
            },
            else => {},
        }
    }
    for (vm.exported_native_closures.items) |exported| {
        const words: [*]const u64 = @ptrFromInt(exported.native_ptr);
        if (words[0] > std.math.maxInt(u32)) return RemapError.UnmappedLiveFunction;
        if (map.get(@intCast(words[0])) == null) return RemapError.UnmappedLiveFunction;
    }

    // Commit pass.
    var iterator = vm.heap.objects.iterator();
    while (iterator.next()) |entry| {
        switch (entry.record.kind) {
            .closure => |closure| closure.function_id = map.get(closure.function_id).?,
            else => {},
        }
    }
    for (vm.exported_native_closures.items) |exported| {
        const words: [*]u64 = @ptrFromInt(exported.native_ptr);
        words[0] = map.get(@intCast(words[0])).?;
    }
}

pub const RepointError = error{
    /// A live native-state box references a type the new module no longer declares.
    MissingStateBoxType,
};

/// Re-point every live NativeStateBox at the replacement module's TypeDecl.
/// The caller must have verified the type layouts are identical (the hybrid
/// swap evaluator does); this only swaps the module pointer and the type-name
/// slice so later recover/materialize calls read the new module, not the
/// retired one.
pub fn repointNativeStateBoxes(vm: *Vm, new_module: *const bytecode.Module) RepointError!void {
    // Verify pass first — a box whose type vanished must abort before any
    // sibling box was rewritten.
    var verify_iterator = vm.native_state_boxes.keyIterator();
    while (verify_iterator.next()) |key| {
        const box: *vm_types.NativeStateBox = @ptrFromInt(key.*);
        if (findTypeByName(new_module, box.typeName()) == null) return RepointError.MissingStateBoxType;
    }
    var iterator = vm.native_state_boxes.keyIterator();
    while (iterator.next()) |key| {
        const box: *vm_types.NativeStateBox = @ptrFromInt(key.*);
        const type_decl = findTypeByName(new_module, box.typeName()).?;
        box.module = new_module;
        box.type_name_ptr = type_decl.name.ptr;
        box.type_name_len = type_decl.name.len;
    }
}

fn findTypeByName(module: *const bytecode.Module, name: []const u8) ?*const bytecode.TypeDecl {
    for (module.types) |*type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
    }
    return null;
}

const runtime_abi = @import("kira_runtime_abi");
const ownership = @import("ownership.zig");

test "tasksIdle is true on a fresh vm" {
    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expect(tasksIdle(&vm));
}

test "remapLiveFunctionIds rewrites heap closures and exported blocks" {
    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();

    // Heap closure with old id 7.
    const closure = try vm.heap.allocClosureObject();
    closure.* = .{ .function_id = 7, .captures = &.{} };
    _ = try vm.heap.registerClosure(closure);

    // Exported native closure block with old id 9.
    const block = try std.testing.allocator.alignedAlloc(u8, .of(u64), 16);
    defer std.testing.allocator.free(block);
    const words: [*]u64 = @ptrCast(@alignCast(block.ptr));
    words[0] = 9;
    words[1] = 0;
    try vm.exported_native_closures.append(vm.allocator, .{
        .native_ptr = @intFromPtr(block.ptr),
        .captures = try vm.allocator.alloc(runtime_abi.Value, 0),
    });

    var map: FunctionIdMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, 7, 70);
    try map.put(std.testing.allocator, 9, 90);

    try remapLiveFunctionIds(&vm, &map);
    try std.testing.expectEqual(@as(u32, 70), closure.function_id);
    try std.testing.expectEqual(@as(u64, 90), words[0]);

    // Drop the exported registry entry manually: the block is test-owned.
    const exported = vm.exported_native_closures.pop().?;
    vm.allocator.free(exported.captures);
}

test "remapLiveFunctionIds rejects unmapped live ids without mutating" {
    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();
    const closure = try vm.heap.allocClosureObject();
    closure.* = .{ .function_id = 7, .captures = &.{} };
    _ = try vm.heap.registerClosure(closure);

    var map: FunctionIdMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, 8, 80);

    try std.testing.expectError(RemapError.UnmappedLiveFunction, remapLiveFunctionIds(&vm, &map));
    try std.testing.expectEqual(@as(u32, 7), closure.function_id);
}

test "collectLiveFunctionIds sees heap closures" {
    var vm = Vm.init(std.testing.allocator);
    defer vm.deinit();
    const closure = try vm.heap.allocClosureObject();
    closure.* = .{ .function_id = 41, .captures = &.{} };
    _ = try vm.heap.registerClosure(closure);

    var ids = try collectLiveFunctionIds(&vm, std.testing.allocator);
    defer ids.deinit(std.testing.allocator);
    try std.testing.expect(ids.get(41) != null);
}
