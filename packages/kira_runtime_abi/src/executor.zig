//! Cooperative single-threaded async executor (shared runtime core).
//!
//! This is the first real executor phase: a FIFO ready-queue of poll-driven
//! `Task`s and a `blockOn` drive loop. A task that returns `.pending` yields
//! control and is re-enqueued at the tail, so independent tasks interleave —
//! the genuine non-eager async behavior the suspend-free spine could not show.
//!
//! Scope of THIS increment (kept deliberately small so it lands green):
//!   * single worker, cooperative yields, no reactor/IO parking yet
//!   * cooperative cancellation (flag observed by the task's poll_fn)
//!   * `blockOn` root drive
//!
//! Next increments layer on top without changing this ABI: a completion
//! `Reactor` supplies park/wake so `.pending` can mean "blocked on IO" instead
//! of "yield", and a work-stealing multi-worker front-end replaces the single
//! FIFO with per-worker deques plus a global injector.
const std = @import("std");
const task_mod = @import("task.zig");
const Task = task_mod.Task;
const Poll = task_mod.Poll;
const Value = @import("value.zig").Value;

pub const Executor = struct {
    allocator: std.mem.Allocator,
    /// Intrusive FIFO ready-queue head/tail.
    head: ?*Task = null,
    tail: ?*Task = null,
    /// Tasks the executor allocated and must free at deinit.
    owned: std.ArrayListUnmanaged(*Task) = .empty,

    pub fn init(allocator: std.mem.Allocator) Executor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Executor) void {
        for (self.owned.items) |task| self.allocator.destroy(task);
        self.owned.deinit(self.allocator);
        self.* = undefined;
    }

    /// Allocate a task for `poll_fn`/`context`, enqueue it, and return it. The
    /// executor owns the allocation; the returned pointer is the task handle.
    pub fn spawn(self: *Executor, poll_fn: task_mod.PollFn, context: ?*anyopaque) !*Task {
        const task = try self.allocator.create(Task);
        task.* = Task.init(poll_fn, context);
        try self.owned.append(self.allocator, task);
        self.enqueue(task);
        return task;
    }

    /// Enqueue an already-owned task (e.g. re-arming a suspended task).
    pub fn enqueue(self: *Executor, task: *Task) void {
        task.state = .ready;
        task.next = null;
        if (self.tail) |tail| {
            tail.next = task;
            self.tail = task;
        } else {
            self.head = task;
            self.tail = task;
        }
    }

    fn dequeue(self: *Executor) ?*Task {
        const task = self.head orelse return null;
        self.head = task.next;
        if (self.head == null) self.tail = null;
        task.next = null;
        return task;
    }

    /// Poll one ready task. Returns true if a task was polled. A `.pending`
    /// task is re-enqueued (cooperative yield); a `.ready` task is completed.
    pub fn tick(self: *Executor) bool {
        const task = self.dequeue() orelse return false;
        if (task.state == .complete) return true;
        task.state = .running;
        switch (task.poll_fn(task)) {
            .ready => |value| {
                task.result = value;
                task.state = .complete;
            },
            .pending => {
                task.state = .suspended;
                self.enqueue(task);
            },
        }
        return true;
    }

    /// Run until the ready-queue drains. Cooperative: assumes every suspended
    /// task eventually makes progress (true once the reactor phase supplies
    /// wakeups; for now callers use finite-yield tasks).
    pub fn runToIdle(self: *Executor) void {
        while (self.tick()) {}
    }

    /// Drive the executor until `root` completes, then return its value. This is
    /// the root async entrypoint (`blockOn`).
    pub fn blockOn(self: *Executor, root: *Task) Value {
        while (!root.isComplete()) {
            if (!self.tick()) break;
        }
        return root.result;
    }
};

// ---- tests ------------------------------------------------------------------

/// A yielding counter task: suspends `remaining` times, then completes with
/// `final`. Proves real suspend/resume and interleaving.
const Counter = struct {
    remaining: u32,
    final: i64,
    ticks: u32 = 0,

    fn poll(task: *Task) Poll {
        const self: *Counter = @ptrCast(@alignCast(task.context.?));
        self.ticks += 1;
        if (task.cancel_requested) {
            task.cancelled = true;
            return .{ .ready = .{ .integer = -1 } };
        }
        if (self.remaining == 0) return .{ .ready = .{ .integer = self.final } };
        self.remaining -= 1;
        return .pending;
    }
};

test "blockOn runs a ready task to completion" {
    var exec = Executor.init(std.testing.allocator);
    defer exec.deinit();
    var ctx = Counter{ .remaining = 0, .final = 42 };
    const task = try exec.spawn(Counter.poll, &ctx);
    const result = exec.blockOn(task);
    try std.testing.expectEqual(@as(i64, 42), result.integer);
    try std.testing.expect(task.isComplete());
}

test "a pending task suspends and resumes across ticks" {
    var exec = Executor.init(std.testing.allocator);
    defer exec.deinit();
    var ctx = Counter{ .remaining = 3, .final = 100 };
    const task = try exec.spawn(Counter.poll, &ctx);
    const result = exec.blockOn(task);
    try std.testing.expectEqual(@as(i64, 100), result.integer);
    // 3 suspends + 1 completing poll = 4 ticks.
    try std.testing.expectEqual(@as(u32, 4), ctx.ticks);
}

test "independent tasks interleave via cooperative yield" {
    var exec = Executor.init(std.testing.allocator);
    defer exec.deinit();
    var a = Counter{ .remaining = 2, .final = 10 };
    var b = Counter{ .remaining = 2, .final = 20 };
    const ta = try exec.spawn(Counter.poll, &a);
    const tb = try exec.spawn(Counter.poll, &b);
    exec.runToIdle();
    try std.testing.expect(ta.isComplete());
    try std.testing.expect(tb.isComplete());
    try std.testing.expectEqual(@as(i64, 10), ta.result.integer);
    try std.testing.expectEqual(@as(i64, 20), tb.result.integer);
    // Interleaved: both advanced before either finished (FIFO round-robin).
    try std.testing.expectEqual(@as(u32, 3), a.ticks);
    try std.testing.expectEqual(@as(u32, 3), b.ticks);
}

test "cooperative cancel is observed at a yield point" {
    var exec = Executor.init(std.testing.allocator);
    defer exec.deinit();
    var ctx = Counter{ .remaining = 100, .final = 7 };
    const task = try exec.spawn(Counter.poll, &ctx);
    // Let it run a couple of ticks, then request cancel.
    _ = exec.tick();
    task.requestCancel();
    const result = exec.blockOn(task);
    try std.testing.expect(task.cancelled);
    try std.testing.expectEqual(@as(i64, -1), result.integer);
    // It stopped early rather than running all 100 yields.
    try std.testing.expect(ctx.ticks < 100);
}
