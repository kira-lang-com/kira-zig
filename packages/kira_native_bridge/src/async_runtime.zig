//! C-ABI async runtime surface — the stable symbols generated code calls on
//! BOTH backends (VM and LLVM/native) to drive the shared cooperative
//! `Executor`. Keeping the surface here (next to the other `kira_*` runtime
//! exports) means one implementation, reached identically through the existing
//! FFI/trampoline path, so async stays backend-parity by construction
//! (Core Law #1).
//!
//! Surface: `kira_async_spawn(work, context)` enqueues DEFERRED work — it runs
//! when the executor first polls the task, not at spawn, so a cancel observed
//! before the first poll genuinely prevents execution. `kira_async_block_on_value`
//! joins (drives the executor, returns the `BridgeValue` result, frees the task);
//! `kira_async_request_cancel` sets the cooperative flag; `kira_async_detach`
//! stops waiting but still lets the work run. When the async-fn state-machine
//! lowering lands, generated poll fns can return `.pending` and interleave —
//! these entry points do not change shape.
//!
//! Threading: one process-global executor. The current executor is
//! single-threaded/cooperative, so these entry points take no lock. The
//! multi-worker front-end (later increment) adds the synchronization; callers
//! do not change shape.
const std = @import("std");
const runtime_abi = @import("kira_runtime_abi");
const Executor = runtime_abi.Executor;
const Task = runtime_abi.Task;
const Poll = runtime_abi.Poll;

var global_executor: ?Executor = null;

fn executor() *Executor {
    if (global_executor == null) global_executor = Executor.init(std.heap.c_allocator);
    return &global_executor.?;
}

// ---- live-task registry ------------------------------------------------------
//
// `kira_async_spawn` hands out raw task pointers; join/detach free them. A
// handle the generated code drops without ever joining/detaching would leak
// its Task + CallableContext permanently, so every spawn is tracked here and
// an atexit teardown destroys the survivors (plus the executor itself). The
// executor is single-threaded/cooperative — no lock.
extern "c" fn atexit(callback: *const fn () callconv(.c) void) c_int;

var live_tasks: std.ArrayListUnmanaged(*Task) = .empty;
var teardown_registered = false;

fn trackTask(task: *Task) void {
    if (!teardown_registered) {
        teardown_registered = true;
        _ = atexit(teardownAsyncRuntime);
    }
    // Untracked on OOM: the task survives to exit unreclaimed, never unsafe.
    live_tasks.append(std.heap.c_allocator, task) catch {};
}

fn untrackTask(task: *Task) void {
    for (live_tasks.items, 0..) |candidate, index| {
        if (candidate == task) {
            _ = live_tasks.swapRemove(index);
            return;
        }
    }
}

fn teardownAsyncRuntime() callconv(.c) void {
    // Runs at process exit only: survivors may still sit in the executor's
    // ready-queue, which is never ticked again, so destroying them here
    // cannot dangle a live poll. destroyCallableTask unlinks as we drain.
    while (live_tasks.items.len > 0) {
        destroyCallableTask(live_tasks.items[live_tasks.items.len - 1]);
    }
    live_tasks.deinit(std.heap.c_allocator);
    live_tasks = .empty;
    if (global_executor) |*exec| {
        exec.deinit();
        global_executor = null;
    }
}

/// Cooperative cancel: set the task's cancel flag. No-op on an already-complete
/// task. Safe to call before the task is ever polled — the work then never runs.
pub export fn kira_async_request_cancel(handle: usize) callconv(.c) void {
    if (handle == 0) return;
    const task: *Task = @ptrFromInt(handle);
    task.requestCancel();
}

// ---- deferred (callable) tasks ----------------------------------------------

/// Generated task body: runs the spawned work and writes its result. `context`
/// is the opaque state the emitting backend captured at the spawn site (a
/// closure frame on either backend); `out` receives the completed value.
pub const AsyncWorkFn = *const fn (context: ?*anyopaque, out: *runtime_abi.BridgeValue) callconv(.c) void;

const CallableContext = struct {
    work: AsyncWorkFn,
    work_context: ?*anyopaque,
};

/// Poll for a deferred task: the work runs HERE, at poll time — not at spawn.
/// A cancel observed before the first poll therefore genuinely prevents the
/// work from ever running (real cooperative-cancel semantics the eager spine
/// cannot express).
fn callablePoll(task: *Task) Poll {
    const ctx: *CallableContext = @ptrCast(@alignCast(task.context.?));
    if (task.cancel_requested) {
        task.cancelled = true;
        return .{ .ready = .{ .void = {} } };
    }
    var out = runtime_abi.BridgeValue{ .tag = .void };
    ctx.work(ctx.work_context, &out);
    return .{ .ready = runtime_abi.bridgeValueToValue(out) };
}

fn destroyCallableTask(task: *Task) void {
    const alloc = std.heap.c_allocator;
    untrackTask(task);
    if (task.context) |ctx| {
        const callable: *CallableContext = @ptrCast(@alignCast(ctx));
        alloc.destroy(callable);
    }
    alloc.destroy(task);
}

/// Spawn deferred work onto the executor. The work does NOT run yet; it runs
/// when the executor first polls the task (via `kira_async_block_on_value`,
/// `kira_async_detach`, or a drive loop). Returns an opaque handle or
/// 0 on allocation failure.
pub export fn kira_async_spawn(work: AsyncWorkFn, context: ?*anyopaque) callconv(.c) usize {
    const alloc = std.heap.c_allocator;
    const callable = alloc.create(CallableContext) catch return 0;
    callable.* = .{ .work = work, .work_context = context };
    const task = alloc.create(Task) catch {
        alloc.destroy(callable);
        return 0;
    };
    task.* = Task.init(callablePoll, callable);
    trackTask(task);
    executor().enqueue(task);
    return @intFromPtr(task);
}

/// Join a deferred task: drive the executor until it completes, write its
/// result to `out`, free the task. `out.tag == .void` with `cancelled` tasks.
pub export fn kira_async_block_on_value(handle: usize, out: *runtime_abi.BridgeValue) callconv(.c) void {
    out.* = .{ .tag = .void };
    if (handle == 0) return;
    const task: *Task = @ptrFromInt(handle);
    const result = executor().blockOn(task);
    out.* = runtime_abi.bridgeValueFromValue(result);
    destroyCallableTask(task);
}

/// Detach a deferred task: stop waiting, discard the eventual result. The work
/// still runs (detach is not cancel) — the executor drives it to completion.
pub export fn kira_async_detach(handle: usize) callconv(.c) void {
    if (handle == 0) return;
    const task: *Task = @ptrFromInt(handle);
    _ = executor().blockOn(task);
    destroyCallableTask(task);
}

// ---- tests ------------------------------------------------------------------

/// Test work fn with an observable side effect: increments the counter behind
/// `context` and yields its new value.
fn countingWork(context: ?*anyopaque, out: *runtime_abi.BridgeValue) callconv(.c) void {
    const counter: *i64 = @ptrCast(@alignCast(context.?));
    counter.* += 1;
    out.* = .{ .tag = .integer, .payload = .{ .integer = counter.* } };
}

test "deferred work does not run at spawn, runs at join" {
    var counter: i64 = 0;
    const h = kira_async_spawn(countingWork, &counter);
    try std.testing.expect(h != 0);
    // Spawn is lazy: nothing has executed yet.
    try std.testing.expectEqual(@as(i64, 0), counter);
    var out = runtime_abi.BridgeValue{ .tag = .void };
    kira_async_block_on_value(h, &out);
    try std.testing.expectEqual(@as(i64, 1), counter);
    try std.testing.expectEqual(runtime_abi.BridgeValueTag.integer, out.tag);
    try std.testing.expectEqual(@as(i64, 1), out.payload.integer);
}

test "cancel before first poll prevents the work from ever running" {
    var counter: i64 = 0;
    const h = kira_async_spawn(countingWork, &counter);
    kira_async_request_cancel(h);
    var out = runtime_abi.BridgeValue{ .tag = .integer, .payload = .{ .integer = -1 } };
    kira_async_block_on_value(h, &out);
    // The work never executed and the join yields void.
    try std.testing.expectEqual(@as(i64, 0), counter);
    try std.testing.expectEqual(runtime_abi.BridgeValueTag.void, out.tag);
}

test "detach is not cancel: the work still runs" {
    var counter: i64 = 0;
    const h = kira_async_spawn(countingWork, &counter);
    kira_async_detach(h);
    try std.testing.expectEqual(@as(i64, 1), counter);
}

test "deferred null-handle entry points are safe no-ops" {
    var out = runtime_abi.BridgeValue{ .tag = .integer, .payload = .{ .integer = 5 } };
    kira_async_block_on_value(0, &out);
    try std.testing.expectEqual(runtime_abi.BridgeValueTag.void, out.tag);
    kira_async_detach(0);
}

test "spawn tracks the task and join untracks it" {
    var counter: i64 = 0;
    const before = live_tasks.items.len;
    const h = kira_async_spawn(countingWork, &counter);
    try std.testing.expect(h != 0);
    try std.testing.expectEqual(before + 1, live_tasks.items.len);
    var out = runtime_abi.BridgeValue{ .tag = .void };
    kira_async_block_on_value(h, &out);
    // Joined: the registry no longer owns it — nothing left for teardown.
    try std.testing.expectEqual(before, live_tasks.items.len);
}

test "many deferred round-trips are leak-clean" {
    var counter: i64 = 0;
    var i: i64 = 0;
    while (i < 64) : (i += 1) {
        const h = kira_async_spawn(countingWork, &counter);
        var out = runtime_abi.BridgeValue{ .tag = .void };
        kira_async_block_on_value(h, &out);
        try std.testing.expectEqual(i + 1, out.payload.integer);
    }
    try std.testing.expectEqual(@as(i64, 64), counter);
}
