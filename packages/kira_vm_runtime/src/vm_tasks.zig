//! VM-side async task objects (deferred execution).
//!
//! A `VmTask` is the VM's representation of a `Task { ... }` handle: the
//! captured callee + eagerly-evaluated scalar args of a deferred call (or a
//! ready value for pure `Task { <literal> }` bodies). The call runs when the
//! task is first driven — `task_await` joins it, `task_detach` drives and
//! discards — never at spawn. A cancel observed before the first drive
//! prevents the call from ever running; a later await traps.
//!
//! Semantics mirror the shared executor ABI (`kira_runtime_abi.Task` +
//! `kira_native_bridge/src/async_runtime.zig`) and the native C runtime's task
//! helpers, so vm/llvm/hybrid observe identical behavior.
//!
//! Lifecycle: tasks are allocated from the VM allocator and registered in
//! `Vm.live_tasks`; they are freed at VM deinit (not at join) so a duplicate
//! join is a clean trap instead of a use-after-free. The restricted slice
//! only allows scalar args/results (enforced in semantics), so task slots
//! never own heap objects and freeing is a plain destroy.
const std = @import("std");
const runtime_abi = @import("kira_runtime_abi");
const bytecode = @import("kira_bytecode");

pub const VmTaskKind = enum {
    /// Deferred call to a runtime (VM-interpreted) function.
    runtime_call,
    /// Deferred call to a native (LLVM-compiled) function through the hybrid
    /// native-call hook.
    native_call,
    /// Already-completed pure value (`Task { 41 }`).
    ready,
    /// State-machine body (async transform): driven by status until complete;
    /// a suspended drive re-enqueues the task (round-robin).
    suspendable_call,
};

pub const VmTaskState = enum {
    /// Spawned and enqueued; the deferred call has not run yet.
    pending,
    /// The executor ran the call; the result is ready to be joined.
    complete,
    /// Joined, detached-and-run, or cancelled: the handle may not be joined
    /// again.
    consumed,
};

pub const VmTask = struct {
    kind: VmTaskKind,
    /// For `runtime_call`: index into prepared.functions (rewritten by the
    /// decode pass). For `native_call`: the global function id passed to the
    /// native-call hook.
    callee: u32 = 0,
    /// Eagerly-captured scalar argument values (owned by the task allocation).
    args: []runtime_abi.Value = &.{},
    /// Result type for native-call materialization (points into stable module
    /// memory via the spawning instruction, which outlives the task).
    return_ty: bytecode.TypeRef = .{ .kind = .void },
    /// Completed value for `ready` tasks.
    ready_value: runtime_abi.Value = .{ .void = {} },
    /// The executed call's result; valid once `state == .complete`.
    result: runtime_abi.Value = .{ .void = {} },
    state: VmTaskState = .pending,
    cancel_requested: bool = false,
    /// `detach()` was called: the caller stopped waiting. The work still runs
    /// when the executor reaches the task (unless cancelled first); the result
    /// is discarded.
    detached: bool = false,
    /// State-machine frame for `suspendable_call` tasks: slot 0 = resume state,
    /// slot 1 = return value, slots 2.. = the body's params/locals. Owned by
    /// the task allocation.
    frame: []runtime_abi.Value = &.{},
    /// Monotonic wake deadline (ns) set by `taskSleep`: the executor skips the
    /// task until the deadline passes. 0 = runnable immediately.
    wake_at_ns: u64 = 0,
};

/// Monotonic now in nanoseconds (the executor's wake-deadline clock).
pub fn nowNs() u64 {
    const raw = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.toNanoseconds();
    return @intCast(@max(raw, 0));
}

/// Block the current thread for `ns` nanoseconds (executor idle wait /
/// blocking `taskSleep` outside a suspendable body).
pub fn sleepNs(ns: u64) void {
    // Portable blocking sleep: `std.c.timespec`/`nanosleep` are POSIX-only
    // (the fields are `void` on windows-msvc), so use the cross-platform Io path.
    std.Options.debug_io.sleep(.fromNanoseconds(@intCast(@min(ns, std.math.maxInt(i64)))), .awake) catch {};
}

/// Allocate + register a task. The caller fills in kind-specific fields.
pub fn createTask(
    allocator: std.mem.Allocator,
    live_tasks: *std.ArrayListUnmanaged(*VmTask),
    task: VmTask,
) !*VmTask {
    const created = try allocator.create(VmTask);
    created.* = task;
    errdefer allocator.destroy(created);
    try live_tasks.append(allocator, created);
    return created;
}

/// Free every task allocated during the run (VM deinit).
pub fn deinitTasks(allocator: std.mem.Allocator, live_tasks: *std.ArrayListUnmanaged(*VmTask)) void {
    for (live_tasks.items) |task| {
        if (task.args.len > 0) allocator.free(task.args);
        if (task.frame.len > 0) allocator.free(task.frame);
        allocator.destroy(task);
    }
    live_tasks.deinit(allocator);
}

test "createTask registers and deinitTasks frees" {
    var live: std.ArrayListUnmanaged(*VmTask) = .empty;
    const args = try std.testing.allocator.alloc(runtime_abi.Value, 2);
    args[0] = .{ .integer = 1 };
    args[1] = .{ .integer = 2 };
    const task = try createTask(std.testing.allocator, &live, .{
        .kind = .runtime_call,
        .callee = 3,
        .args = args,
    });
    try std.testing.expectEqual(VmTaskState.pending, task.state);
    try std.testing.expectEqual(@as(usize, 1), live.items.len);
    deinitTasks(std.testing.allocator, &live);
}
