//! A spinlock optimized for non-contended use cases e.g. protecting per-executor data that is rarely accessed by other executors.
//!
//! Recursive locks are not supported.
//!
//! Interrupts are disabled while locked.
const SingleSpinLock = @This();

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

// Cache-line-aligned marker first so embedding this lock can't false-share its
// atomic with a preceding field.
_: void align(std.atomic.cache_line) = {},

holding_executor: std.atomic.Value(?*const innigkeit.Executor) align(std.atomic.cache_line) = .init(null),

pub fn lock(self: *SingleSpinLock) void {
    const current_task: innigkeit.Task.Current = .get();
    current_task.incrementInterruptDisable();

    defer current_task.task.spinlocks_held += 1;

    const current_executor = current_task.knownExecutor();

    const locked_by = self.holding_executor.cmpxchgStrong(
        null,
        current_executor,
        .acquire,
        .monotonic,
    ) orelse {
        @branchHint(.likely);
        return;
    };

    if (locked_by == current_executor) {
        @branchHint(.cold);
        @panic("recursive lock!");
    }

    while (self.holding_executor.cmpxchgWeak(
        null,
        current_executor,
        .acquire,
        .monotonic,
    )) |_| {
        architecture.spinLoopHint();
    }
}

pub fn tryLock(self: *SingleSpinLock) bool {
    const current_task: innigkeit.Task.Current = .get();
    current_task.incrementInterruptDisable();
    const current_executor = current_task.knownExecutor();

    if (self.holding_executor.cmpxchgStrong(
        null,
        current_executor,
        .acquire,
        .monotonic,
    )) |locked_by| {
        @branchHint(.unlikely);

        if (locked_by == current_executor) {
            @branchHint(.cold);
            @panic("recursive lock!");
        }

        current_task.decrementInterruptDisable();
        return false;
    }

    current_task.task.spinlocks_held += 1;
    return true;
}

pub fn unlock(self: *SingleSpinLock) void {
    const current_task: innigkeit.Task.Current = .get();

    if (core.is_debug) {
        std.debug.assert(current_task.task.spinlocks_held != 0);
        std.debug.assert(self.isLockedByCurrent());
    }

    self.unsafeUnlock();

    current_task.task.spinlocks_held -= 1;
    current_task.decrementInterruptDisable();
}

/// Unlocks the spinlock, without decrementing interrupt disable count or spinlock held count.
///
/// Performs no checks, prefer `unlock` instead.
pub inline fn unsafeUnlock(self: *SingleSpinLock) void {
    self.holding_executor.store(null, .release);
}

/// Returns true if the spinlock is locked by the current executor.
pub fn isLockedByCurrent(self: *const SingleSpinLock) bool {
    const executor = innigkeit.Task.Current.get().task.known_executor orelse return false;
    return self.holding_executor.load(.monotonic) == executor;
}
