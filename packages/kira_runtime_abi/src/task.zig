//! Shared async task ABI — the `Task` layout and poll protocol that both the VM
//! and the LLVM/native backend agree on (Core Law #1 parity: one task model,
//! two backends).
//!
//! A `Task` is a resumable, poll-driven state machine. The executor advances a
//! task by calling `poll_fn`; the task either completes (`.ready`) or suspends
//! (`.pending`) at a cooperative yield/park point. This is the real, non-eager
//! async core: a `.pending` result hands control back to the executor so other
//! tasks run before this one is resumed. The compiler's async-fn state-machine
//! lowering (next phase) emits `poll_fn`/`context` pairs targeting this ABI;
//! the reactor phase supplies park/wake for IO-backed pending.
const std = @import("std");
const Value = @import("value.zig").Value;

/// Result of advancing a task one step.
pub const Poll = union(enum) {
    /// The task finished and produced its value.
    ready: Value,
    /// The task suspended at a cooperative yield/park point and must be polled
    /// again later.
    pending,
};

/// Advances `task` one step. Implementations read/write `task.context` (the
/// state-machine frame) and must observe `task.cancel_requested` at their
/// cooperative cancel points.
pub const PollFn = *const fn (task: *Task) Poll;

pub const TaskState = enum {
    /// Enqueued (or freshly spawned) and waiting to be polled.
    ready,
    /// Currently being polled by the executor.
    running,
    /// Suspended at a yield/park point; waiting to be re-enqueued.
    suspended,
    /// Finished with a result (possibly a cancellation-observed result).
    complete,
};

/// The task control block. Layout is intentionally flat and backend-neutral so
/// generated code on either backend can allocate and initialize it identically.
pub const Task = struct {
    poll_fn: PollFn,
    /// Opaque state-machine frame owned by the task's generated code.
    context: ?*anyopaque = null,
    state: TaskState = .ready,
    /// Cooperative-cancel flag. `requestCancel()` sets it; the task's poll_fn
    /// observes it at its cancel points and completes early. Setting it never
    /// force-terminates a running task.
    cancel_requested: bool = false,
    /// Whether cancellation was actually observed before completion.
    cancelled: bool = false,
    /// Completed value; valid once `state == .complete`.
    result: Value = .{ .void = {} },
    /// Intrusive FIFO link used by the executor ready-queue. Owned by the
    /// executor while the task is enqueued.
    next: ?*Task = null,

    pub fn init(poll_fn: PollFn, context: ?*anyopaque) Task {
        return .{ .poll_fn = poll_fn, .context = context };
    }

    /// Cooperative cancellation: request the task stop at its next cancel point.
    /// A no-op on an already-complete task (matches the surface semantics of
    /// `handle.requestCancel()`).
    pub fn requestCancel(self: *Task) void {
        if (self.state == .complete) return;
        self.cancel_requested = true;
    }

    pub fn isComplete(self: *const Task) bool {
        return self.state == .complete;
    }
};

test "task starts ready and non-cancelled" {
    const P = struct {
        fn poll(_: *Task) Poll {
            return .{ .ready = .{ .integer = 7 } };
        }
    };
    var task = Task.init(P.poll, null);
    try std.testing.expectEqual(TaskState.ready, task.state);
    try std.testing.expect(!task.cancel_requested);
    try std.testing.expect(!task.isComplete());
}

test "requestCancel sets the cooperative flag" {
    const P = struct {
        fn poll(_: *Task) Poll {
            return .pending;
        }
    };
    var task = Task.init(P.poll, null);
    task.requestCancel();
    try std.testing.expect(task.cancel_requested);
}

test "requestCancel is a no-op on a completed task" {
    const P = struct {
        fn poll(_: *Task) Poll {
            return .{ .ready = .{ .void = {} } };
        }
    };
    var task = Task.init(P.poll, null);
    task.state = .complete;
    task.requestCancel();
    try std.testing.expect(!task.cancel_requested);
}
