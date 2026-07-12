//! Blocking-thread synchronization primitives for the debugger's driver/worker
//! handshake. Zig 0.16 moved `std.Thread.Semaphore`/`Mutex`/`Condition` to the
//! `Io` model (they now require an `Io` instance), but the VM debug target runs
//! a plain OS worker thread with no `Io` in scope. This module provides a small
//! counting semaphore built on atomics + `Thread.yield`, exposing the classic
//! `post()`/`wait()` surface the handshake needs.
//!
//! The handshake is strictly ping-pong (one side waits while the other runs), so
//! contention is near-zero and a yield-spin acquire is both correct and cheap;
//! it never busy-burns a core because each side blocks on the other's `post`.
const std = @import("std");

/// A counting semaphore with a spin-yield `wait`. Default-initializes to zero
/// permits, so `.{}` is a valid empty semaphore.
pub const Semaphore = struct {
    permits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Release one permit, waking a waiter (via its next acquire attempt).
    pub fn post(self: *Semaphore) void {
        _ = self.permits.fetchAdd(1, .release);
    }

    /// Acquire one permit, yielding to the scheduler until one is available.
    pub fn wait(self: *Semaphore) void {
        while (true) {
            var current = self.permits.load(.acquire);
            while (current != 0) {
                if (self.permits.cmpxchgWeak(current, current - 1, .acquire, .acquire)) |updated| {
                    current = updated;
                } else {
                    return;
                }
            }
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }
};

test "semaphore post then wait does not block" {
    var sem = Semaphore{};
    sem.post();
    sem.wait();
}

test "semaphore counts multiple permits" {
    var sem = Semaphore{};
    sem.post();
    sem.post();
    sem.wait();
    sem.wait();
    try std.testing.expectEqual(@as(u32, 0), sem.permits.load(.acquire));
}

test "semaphore ping-pong across a worker thread" {
    const Shared = struct {
        to_worker: Semaphore = .{},
        to_main: Semaphore = .{},
        value: u32 = 0,

        fn worker(s: *@This()) void {
            s.to_worker.wait();
            s.value += 1;
            s.to_main.post();
        }
    };
    var shared = Shared{};
    var thread = try std.Thread.spawn(.{}, Shared.worker, .{&shared});
    shared.to_worker.post();
    shared.to_main.wait();
    thread.join();
    try std.testing.expectEqual(@as(u32, 1), shared.value);
}
