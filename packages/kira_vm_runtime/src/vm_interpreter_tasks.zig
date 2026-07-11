//! Async-task execution satellite for the VM interpreter: handle validation
//! and first-drive of deferred tasks (see vm_tasks.zig for the task object and
//! the dispatch cases in vm_interpreter.zig for the opcode surface).
const std = @import("std");
const bytecode = @import("kira_bytecode");
const runtime_abi = @import("kira_runtime_abi");
const vm_mod = @import("vm.zig");
const vm_tasks = @import("vm_tasks.zig");
const interpreter = @import("vm_interpreter.zig");

const Vm = vm_mod.Vm;
const Hooks = vm_mod.Hooks;
const VmTask = vm_tasks.VmTask;
const PreparedModule = @import("vm_prepare.zig").PreparedModule;

/// Resolve a task handle register to its VmTask, trapping on garbage.
pub fn taskFromRegister(vm: *Vm, value: runtime_abi.Value) ?*VmTask {
    if (value != .raw_ptr or value.raw_ptr == 0) {
        vm.rememberError("expected a task handle");
        return null;
    }
    const task: *VmTask = @ptrFromInt(value.raw_ptr);
    // Handle validity: the pointer must be one the VM allocated this run.
    for (vm.live_tasks.items) |live| {
        if (live == task) return task;
    }
    vm.rememberError("expected a task handle");
    return null;
}

/// Run a task's deferred call now and return its value. `ready` tasks yield
/// their stored value.
fn driveTask(
    vm: *Vm,
    prepared: *const PreparedModule,
    module: *const bytecode.Module,
    task: *VmTask,
    writer: anytype,
    hooks: Hooks,
) anyerror!runtime_abi.Value {
    switch (task.kind) {
        // Suspendable bodies are driven by status in runOne, never here.
        .suspendable_call => {
            vm.rememberError("suspendable task reached the run-to-completion drive");
            return error.RuntimeFailure;
        },
        .ready => return task.ready_value,
        .runtime_call => {
            if (task.callee >= prepared.functions.len) {
                vm.rememberError("task callee function id is out of range");
                return error.RuntimeFailure;
            }
            const callee = &prepared.functions[task.callee];
            const result = try interpreter.runPrepared(vm, prepared, callee, task.args, writer, hooks);
            // A void completion joins as Int 0 (matches the native runtime's
            // zero payload for a void bridge tag and the handle's Int typing).
            return if (result == .void) .{ .integer = 0 } else result;
        },
        .native_call => {
            const callback = hooks.call_native orelse {
                vm.rememberError("vm native bridge was not installed");
                return error.RuntimeFailure;
            };
            const result = try callback(hooks.context, task.callee, task.args);
            return vm.materializeNativeResultFromC(module, task.return_ty, result);
        },
    }
}

/// Pop the next DUE pending task (FIFO among due tasks); parked tasks whose
/// wake deadline has not passed stay queued. Null when nothing is due.
fn popNext(vm: *Vm) ?*VmTask {
    const now: u64 = vm_tasks.nowNs();
    var index = vm.task_queue_head;
    while (index < vm.task_queue.items.len) {
        const task = vm.task_queue.items[index];
        if (task.state != .pending) {
            if (index == vm.task_queue_head) {
                vm.task_queue_head += 1;
                index += 1;
                continue;
            }
            index += 1;
            continue;
        }
        if (task.wake_at_ns <= now) {
            _ = vm.task_queue.orderedRemove(index);
            return task;
        }
        index += 1;
    }
    return null;
}

/// Like popNext, but when every pending task is parked on a wake deadline,
/// sleep until the earliest deadline and retry. Null only when no pending
/// tasks remain at all.
fn popNextOrWait(vm: *Vm) ?*VmTask {
    while (true) {
        if (popNext(vm)) |task| return task;
        var earliest: ?u64 = null;
        var index = vm.task_queue_head;
        while (index < vm.task_queue.items.len) : (index += 1) {
            const task = vm.task_queue.items[index];
            if (task.state != .pending) continue;
            if (earliest == null or task.wake_at_ns < earliest.?) earliest = task.wake_at_ns;
        }
        const wake = earliest orelse return null;
        const now: u64 = vm_tasks.nowNs();
        if (wake > now) vm_tasks.sleepNs(wake - now);
    }
}

/// Run one popped task. A cancel observed before the run wins: the call never
/// executes (for a suspendable body, a cancel observed at a suspend point
/// abandons the remainder — the spec's flag-check cancellation). A suspended
/// drive re-enqueues the task (round-robin); a detached task's result is
/// discarded.
fn runOne(
    vm: *Vm,
    prepared: *const PreparedModule,
    module: *const bytecode.Module,
    task: *VmTask,
    writer: anytype,
    hooks: Hooks,
) anyerror!void {
    if (task.cancel_requested) {
        task.state = .consumed;
        return;
    }
    if (task.kind == .suspendable_call) {
        if (task.callee >= prepared.functions.len) {
            vm.rememberError("task callee function id is out of range");
            return error.RuntimeFailure;
        }
        const callee = &prepared.functions[task.callee];
        // This drive consumes any prior wake deadline; `task_sleep` inside the
        // body sets a fresh one on the current task before suspending.
        task.wake_at_ns = 0;
        const previous_current = vm.current_task;
        vm.current_task = task;
        defer vm.current_task = previous_current;
        var frame_arg = [_]runtime_abi.Value{.{ .raw_ptr = @intFromPtr(task.frame.ptr) }};
        const status = try interpreter.runPrepared(vm, prepared, callee, &frame_arg, writer, hooks);
        if (status != .integer) {
            vm.rememberError("suspendable task body returned a non-status value");
            return error.RuntimeFailure;
        }
        if (status.integer == 1) {
            // Suspended at a yield point: back of the queue (round-robin).
            try vm.task_queue.append(vm.allocator, task);
            return;
        }
        const result = task.frame[1];
        if (task.detached) {
            task.state = .consumed;
        } else {
            task.result = if (result == .void) .{ .integer = 0 } else result;
            task.state = .complete;
        }
        return;
    }
    const result = try driveTask(vm, prepared, module, task, writer, hooks);
    if (task.detached) {
        vm.heap.dropValue(result);
        task.state = .consumed;
    } else {
        task.result = result;
        task.state = .complete;
    }
}

/// Join `target`: drive the executor FIFO until the target's call has run,
/// then yield its result exactly once. Joining a cancelled or already-consumed
/// (joined/detached) task traps.
pub fn awaitTask(
    vm: *Vm,
    prepared: *const PreparedModule,
    module: *const bytecode.Module,
    target: *VmTask,
    writer: anytype,
    hooks: Hooks,
) anyerror!runtime_abi.Value {
    if (target.state == .consumed or target.detached) {
        if (target.cancel_requested and !target.detached and target.state == .consumed) {
            vm.rememberError("awaited a cancelled task");
        } else {
            vm.rememberError("task was already joined or detached");
        }
        return error.RuntimeFailure;
    }
    if (target.cancel_requested) {
        // The deferred call never runs on a cancelled task; joining it is a
        // trap (there is no value to yield).
        target.state = .consumed;
        vm.rememberError("awaited a cancelled task");
        return error.RuntimeFailure;
    }
    while (target.state == .pending) {
        const task = popNextOrWait(vm) orelse {
            vm.rememberError("task executor queue drained before the awaited task completed");
            return error.RuntimeFailure;
        };
        try runOne(vm, prepared, module, task, writer, hooks);
        if (task == target and task.state == .consumed) {
            // A cancel raced the pop (cannot happen today — cancellation is
            // checked above — but keep the join truthful if it ever does).
            vm.rememberError("awaited a cancelled task");
            return error.RuntimeFailure;
        }
    }
    const result = target.result;
    target.result = .{ .void = {} };
    target.state = .consumed;
    return result;
}

/// Spawn a task for a `task_spawn` instruction: capture the callee + scalar
/// args (or seed a state-machine frame) WITHOUT calling, and enqueue on the
/// executor FIFO. Returns the handle task.
pub fn spawnTask(
    vm: *Vm,
    value: anytype,
    registers: []const runtime_abi.Value,
) anyerror!*VmTask {
    var task: *VmTask = undefined;
    if (value.suspendable and value.native) {
        // A hybrid VM-side spawn of a natively-compiled state-machine body
        // would need a bridge-slot frame; not wired yet.
        vm.rememberError("suspendable @Native task bodies are not supported from runtime code yet");
        return error.RuntimeFailure;
    }
    if (value.suspendable) {
        // State-machine body: allocate its frame (slot 0 = resume state,
        // slot 1 = result, slots 2.. = params/locals) and seed the args; the
        // body is driven by status until complete.
        const task_frame = try vm.allocator.alloc(runtime_abi.Value, value.frame_slots);
        errdefer vm.allocator.free(task_frame);
        @memset(task_frame, .{ .integer = 0 });
        for (value.args, 0..) |register_index, index| task_frame[2 + index] = registers[register_index];
        task = try vm_tasks.createTask(vm.allocator, &vm.live_tasks, .{
            .kind = .suspendable_call,
            .callee = value.callee,
            .frame = task_frame,
            .return_ty = value.result_ty,
        });
    } else {
        const task_args = try vm.allocator.alloc(runtime_abi.Value, value.args.len);
        errdefer vm.allocator.free(task_args);
        for (value.args, 0..) |register_index, index| task_args[index] = registers[register_index];
        task = try vm_tasks.createTask(vm.allocator, &vm.live_tasks, .{
            .kind = if (value.native) .native_call else .runtime_call,
            .callee = value.callee,
            .args = task_args,
            .return_ty = value.result_ty,
        });
    }
    try vm.task_queue.append(vm.allocator, task);
    return task;
}

/// `taskYield()`: run the next queued task (if any) to completion before the
/// yielding body continues. A no-op when the queue is drained.
pub fn yieldOnce(
    vm: *Vm,
    prepared: *const PreparedModule,
    module: *const bytecode.Module,
    writer: anytype,
    hooks: Hooks,
) anyerror!void {
    const task = popNext(vm) orelse return;
    try runOne(vm, prepared, module, task, writer, hooks);
}

/// End-of-run drain: run every remaining non-cancelled task (detached tasks
/// outliving their handles). Called after the entrypoint returns.
pub fn drainAll(
    vm: *Vm,
    module: *const bytecode.Module,
    writer: anytype,
    hooks: Hooks,
) anyerror!void {
    if (vm.task_queue_head >= vm.task_queue.items.len) return;
    const prepared = try vm.preparedFor(module);
    while (popNextOrWait(vm)) |task| {
        try runOne(vm, prepared, module, task, writer, hooks);
        // An undetached, never-awaited task's result is dropped with the task
        // registry at deinit; scalars own no heap, so dropping here is a no-op
        // either way. Keep completed results out of the queue's way.
        if (task.state == .complete) {
            vm.heap.dropValue(task.result);
            task.result = .{ .void = {} };
            task.state = .consumed;
        }
    }
}
