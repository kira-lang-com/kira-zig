//! Live hot swap: replace the executing bytecode module (and its hybrid
//! manifest) inside a RUNNING HybridRuntime without tearing down the process,
//! the window, sokol, the native dylib, the VM heap, or any app state.
//!
//! Model (kira-swift's applyPendingPatchIfSafe, adapted to the hybrid VM):
//!   - a background listener STAGES a swap (new module + manifest loaded from
//!     the rebuilt bundle);
//!   - the sokol main thread APPLIES it at the next native->runtime callback
//!     boundary, when no VM code is on the stack and the task queue is idle;
//!   - the old module/manifest are RETIRED, not freed: live heap values borrow
//!     type-name and string-literal slices from module memory for as long as
//!     they live (see vm_reload.zig).
//!
//! State continuity is free: the VM heap (native-state boxes, closure
//! captures — the only app state Kira has) is never touched; only function ids
//! inside live closures are remapped to the recompiled module's ids.
//!
//! A swap is REJECTED (the caller falls back to a process relaunch) when the
//! edit changed something live values depend on: a struct/enum layout, or the
//! signature of a function a live closure references.
const std = @import("std");
const bytecode = @import("kira_bytecode");
const hybrid = @import("kira_hybrid_definition");
const vm_runtime = @import("kira_vm_runtime");
const runtime_mod = @import("runtime.zig");

const HybridRuntime = runtime_mod.HybridRuntime;
const FunctionIdMap = vm_runtime.reload.FunctionIdMap;

/// A fully-loaded replacement program, staged by the reload listener thread
/// and consumed by the main thread at a safe boundary. The module/manifest
/// values are moved into the runtime on commit (or retired unused on
/// rejection — Module has no deinit, so a rejected/replaced staging is a
/// bounded dev-session leak, same as a retired module).
pub const StagedSwap = struct {
    module: bytecode.Module,
    manifest: hybrid.HybridModuleManifest,
};

pub const ReloadEvent = enum {
    /// The swap was committed; the NEXT dispatch already runs new code.
    applied,
    /// The first callback after the swap finished — real new-code execution.
    completed,
    /// The swap cannot be applied in place; caller should fall back to a
    /// process relaunch.
    rejected,
    /// Async tasks were busy at the boundary; the swap stays staged and is
    /// retried at the next callback.
    deferred,
};

pub const NotifyFn = *const fn (?*anyopaque, ReloadEvent, []const u8) void;

/// Hot-reload state embedded in HybridRuntime. The listener thread only
/// touches `staged` (under `mutex`); everything else is main-thread-only.
pub const ReloadState = struct {
    mutex: std.atomic.Mutex = .unlocked,
    staged: ?StagedSwap = null,
    notify_context: ?*anyopaque = null,
    notify: ?NotifyFn = null,
    completion_pending: bool = false,
    generation: u32 = 0,
    callback_depth: u32 = 0,
    retired_modules: std.ArrayListUnmanaged(bytecode.Module) = .empty,
    retired_manifests: std.ArrayListUnmanaged(hybrid.HybridModuleManifest) = .empty,

    pub fn deinit(self: *ReloadState, allocator: std.mem.Allocator) void {
        // Retired module/manifest CONTENTS are intentionally not freed: live
        // heap values may borrow their memory until the VM heap itself dies,
        // and the runtime is torn down at process exit anyway.
        self.retired_modules.deinit(allocator);
        self.retired_manifests.deinit(allocator);
    }
};

/// Thread-safe staging entry point for the reload listener thread. A newer
/// staging replaces an unconsumed older one (rapid consecutive saves); the
/// replaced program leaks by design (no Module deinit — dev-session bounded).
pub fn stage(runtime: *HybridRuntime, staged: StagedSwap) void {
    const rs = &runtime.reload;
    lockMutex(&rs.mutex);
    defer rs.mutex.unlock();
    rs.staged = staged;
}

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
}

/// Main-thread callback-boundary hook: called at the top of every
/// native->runtime dispatch. When this is the outermost callback and a swap is
/// staged, applies it (or rejects/defers) and translates `function_id` — the
/// native caller read the OLD id from its closure block before the remap ran,
/// so the in-flight id must be mapped by hand exactly once.
pub fn enterCallback(runtime: *HybridRuntime, function_id: u32) u32 {
    if (std.c.getenv("KIRA_HOTSWAP_DISABLE") != null) return function_id;
    const rs = &runtime.reload;
    rs.callback_depth += 1;
    if (rs.callback_depth != 1) return function_id;

    var staged = blk: {
        lockMutex(&rs.mutex);
        defer rs.mutex.unlock();
        const staged = rs.staged orelse break :blk null;
        rs.staged = null;
        break :blk staged;
    } orelse return function_id;

    if (!vm_runtime.reload.tasksIdle(&runtime.vm)) {
        // Put it back; retry at the next boundary once the executor drained.
        lockMutex(&rs.mutex);
        defer rs.mutex.unlock();
        if (rs.staged == null) rs.staged = staged;
        notifyEvent(rs, .deferred, "async tasks busy");
        return function_id;
    }

    var evaluation = evaluate(runtime.allocator, &runtime.vm, &runtime.module, &staged.module) catch |err| {
        notifyEvent(rs, .rejected, @errorName(err));
        return function_id;
    };
    switch (evaluation) {
        .rejected => |rejection| {
            var buffer: [256]u8 = undefined;
            const detail = if (rejection.detail.len != 0)
                std.fmt.bufPrint(&buffer, "{s}: {s}", .{ rejection.reason.text(), rejection.detail }) catch rejection.reason.text()
            else
                rejection.reason.text();
            notifyEvent(rs, .rejected, detail);
            return function_id;
        },
        .compatible => |*map| {
            const translated = map.get(function_id) orelse function_id;
            commit(runtime, &staged, map) catch |err| {
                notifyEvent(rs, .rejected, @errorName(err));
                return function_id;
            };
            rs.generation += 1;
            rs.completion_pending = true;
            var buffer: [64]u8 = undefined;
            const detail = std.fmt.bufPrint(&buffer, "generation={d}", .{rs.generation}) catch "";
            notifyEvent(rs, .applied, detail);
            return translated;
        },
    }
}

/// Main-thread callback-boundary exit hook, paired with enterCallback. Emits
/// the `completed` event once the first post-swap callback finished — the
/// honest "new code really ran" marker.
pub fn exitCallback(runtime: *HybridRuntime) void {
    if (std.c.getenv("KIRA_HOTSWAP_DISABLE") != null) return;
    const rs = &runtime.reload;
    rs.callback_depth -= 1;
    if (rs.callback_depth != 0 or !rs.completion_pending) return;
    rs.completion_pending = false;
    var buffer: [64]u8 = undefined;
    const detail = std.fmt.bufPrint(&buffer, "generation={d}", .{rs.generation}) catch "";
    notifyEvent(rs, .completed, detail);
}

fn notifyEvent(rs: *ReloadState, event: ReloadEvent, detail: []const u8) void {
    const notify = rs.notify orelse return;
    notify(rs.notify_context, event, detail);
}

// Compatibility evaluation lives in hot_swap_compat.zig (Core Law #5
// extraction); re-exported so callers keep one import surface.
const compat = @import("hot_swap_compat.zig");
pub const Evaluation = compat.Evaluation;
pub const Rejection = compat.Rejection;
pub const evaluate = compat.evaluate;

/// Commit a staged swap into the runtime. Caller guarantees: main thread, no
/// VM frame on the stack, tasks idle, `map` from a successful evaluate()
/// against exactly this old/new module pair. On return the runtime executes
/// `staged`'s program; the old module/manifest live on in the retired lists.
/// Frees `map`.
pub fn commit(
    runtime: *HybridRuntime,
    staged: *StagedSwap,
    map: *FunctionIdMap,
) !void {
    defer map.deinit(runtime.allocator);

    // Rebind native trampolines to the new manifest's function ids FIRST: it
    // is the only fallible step, and until the module is swapped nothing
    // observes the new ids (the VM is idle at this boundary).
    const descriptors = try runtime_mod.buildRuntimeDescriptors(runtime.allocator, staged.manifest);
    try runtime.bridge.rebind(descriptors);

    try runtime.reload.retired_modules.ensureUnusedCapacity(runtime.allocator, 1);
    try runtime.reload.retired_manifests.ensureUnusedCapacity(runtime.allocator, 1);

    // Point of no return — the remaining steps are infallible.
    vm_runtime.reload.remapLiveFunctionIds(&runtime.vm, map) catch |err| switch (err) {
        // evaluate() proved every live id is mapped; a miss here means the
        // caller broke the evaluate->commit contract (mutated the heap between
        // the two calls on the VM thread, which cannot happen at an idle
        // boundary). Treat as the program error it is.
        error.UnmappedLiveFunction => unreachable,
    };

    runtime.reload.retired_modules.appendAssumeCapacity(runtime.module);
    runtime.reload.retired_manifests.appendAssumeCapacity(runtime.manifest);
    runtime.module = staged.module;
    runtime.manifest = staged.manifest;
    runtime.vm.invalidateModuleCaches();

    // Native-state boxes recorded `&runtime.module` (unchanged address), but
    // their type-name slices still point into the retired module; re-point
    // them at the new module's identical TypeDecls.
    vm_runtime.reload.repointNativeStateBoxes(&runtime.vm, &runtime.module) catch |err| switch (err) {
        // Type presence was proven by evaluate() step 1.
        error.MissingStateBoxType => unreachable,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const testFunction = compat.testFunction;
const testModule = compat.testModule;

const TestNotifyLog = struct {
    var events: [8]ReloadEvent = undefined;
    var count: usize = 0;

    fn reset() void {
        count = 0;
    }

    fn record(_: ?*anyopaque, event: ReloadEvent, _: []const u8) void {
        if (count < events.len) {
            events[count] = event;
            count += 1;
        }
    }
};

test "enterCallback applies a staged swap at the outermost boundary" {
    var old_fns = [_]bytecode.Function{ testFunction(1, "main"), testFunction(2, "onFrame") };
    var new_fns = [_]bytecode.Function{ testFunction(1, "main"), testFunction(9, "onFrame") };
    const manifest = hybrid.HybridModuleManifest{
        .module_name = "t",
        .bytecode_path = "t.kbc",
        .native_library_path = "__kira_live_self__",
        .entry_function_id = 1,
        .entry_execution = .runtime,
        .functions = &.{},
    };

    var runtime = HybridRuntime{
        .allocator = testing.allocator,
        .manifest = manifest,
        .module = testModule(&old_fns, &.{}),
        .vm = vm_runtime.Vm.init(testing.allocator),
        .bridge = @import("kira_native_bridge").NativeBridge.init(testing.allocator),
    };
    defer runtime.deinit();
    // No dylib in a unit test: rebind against "self" with zero descriptors.
    runtime.bridge.self_bound = true;

    // A live frame-handler closure referencing old fn id 2.
    const closure = try runtime.vm.heap.allocClosureObject();
    closure.* = .{ .function_id = 2, .captures = &.{} };
    _ = try runtime.vm.heap.registerClosure(closure);

    TestNotifyLog.reset();
    runtime.reload.notify = TestNotifyLog.record;

    stage(&runtime, .{ .module = testModule(&new_fns, &.{}), .manifest = manifest });

    // Outermost callback boundary: swap applies and the in-flight id (read by
    // native before the remap) is translated.
    const translated = enterCallback(&runtime, 2);
    try testing.expectEqual(@as(u32, 9), translated);
    try testing.expectEqual(@as(u32, 9), closure.function_id);
    try testing.expectEqual(@as(u32, 9), runtime.module.functions[1].id);
    try testing.expectEqual(@as(usize, 1), runtime.reload.retired_modules.items.len);
    try testing.expectEqual(@as(u32, 1), runtime.reload.generation);

    // Nested callback must not consume anything or emit completion.
    const nested = enterCallback(&runtime, 9);
    try testing.expectEqual(@as(u32, 9), nested);
    exitCallback(&runtime);
    try testing.expectEqual(@as(usize, 1), TestNotifyLog.count); // applied only

    // Outermost exit emits `completed` — proof new code ran to completion.
    exitCallback(&runtime);
    try testing.expectEqual(@as(usize, 2), TestNotifyLog.count);
    try testing.expectEqual(ReloadEvent.applied, TestNotifyLog.events[0]);
    try testing.expectEqual(ReloadEvent.completed, TestNotifyLog.events[1]);
}

test "enterCallback rejects an incompatible staged swap and keeps running old code" {
    var old_fns = [_]bytecode.Function{testFunction(2, "onFrame")};
    // New module removed onFrame — a live closure references it.
    var new_fns = [_]bytecode.Function{testFunction(3, "somethingElse")};
    const manifest = hybrid.HybridModuleManifest{
        .module_name = "t",
        .bytecode_path = "t.kbc",
        .native_library_path = "__kira_live_self__",
        .entry_function_id = 2,
        .entry_execution = .runtime,
        .functions = &.{},
    };
    var runtime = HybridRuntime{
        .allocator = testing.allocator,
        .manifest = manifest,
        .module = testModule(&old_fns, &.{}),
        .vm = vm_runtime.Vm.init(testing.allocator),
        .bridge = @import("kira_native_bridge").NativeBridge.init(testing.allocator),
    };
    defer runtime.deinit();
    runtime.bridge.self_bound = true;

    const closure = try runtime.vm.heap.allocClosureObject();
    closure.* = .{ .function_id = 2, .captures = &.{} };
    _ = try runtime.vm.heap.registerClosure(closure);

    TestNotifyLog.reset();
    runtime.reload.notify = TestNotifyLog.record;
    stage(&runtime, .{ .module = testModule(&new_fns, &.{}), .manifest = manifest });

    const id = enterCallback(&runtime, 2);
    exitCallback(&runtime);
    try testing.expectEqual(@as(u32, 2), id);
    try testing.expectEqual(@as(u32, 2), closure.function_id);
    try testing.expectEqual(@as(u32, 2), runtime.module.functions[0].id);
    try testing.expectEqual(@as(u32, 0), runtime.reload.generation);
    try testing.expectEqual(@as(usize, 1), TestNotifyLog.count);
    try testing.expectEqual(ReloadEvent.rejected, TestNotifyLog.events[0]);
}

test {
    _ = compat;
}
