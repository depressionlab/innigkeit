//! A fair in order mutex.
//!
//! Recursive locks are not supported.
//!
//! Preemption is disabled while locked.
const Mutex = @This();

const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

// Lead with a cache-line-aligned zero-size marker so the lock's atomics never
// share a cache line with a preceding field when this struct is embedded in a
// larger one (avoids false sharing).
_: void align(std.atomic.cache_line) = {},

locked_by: std.atomic.Value(?*innigkeit.Task) = .init(null),
unlock_type: UnlockType = .unlocked,
spinlock: innigkeit.sync.TicketSpinLock = .{},
wait_queue: innigkeit.sync.WaitQueue = .{},

pub fn lock(self: *Mutex) void {
    const current_task: innigkeit.Task.Current = .get();

    while (true) {
        var locked_by = self.locked_by.cmpxchgWeak(
            null,
            current_task.task,
            .acquire,
            .monotonic,
        ) orelse {
            // we have the mutex
            return;
        };

        if (locked_by == current_task.task) {
            switch (self.unlock_type) {
                .passed_to_waiter => {
                    @branchHint(.likely);
                    // the mutex was passed directly to us
                    return;
                },
                .unlocked => {
                    @branchHint(.cold);
                    @panic("recursive lock!");
                },
            }
        }

        self.spinlock.lock();

        locked_by = self.locked_by.cmpxchgStrong(
            null,
            current_task.task,
            .acquire,
            .monotonic,
        ) orelse {
            // we have the mutex
            self.spinlock.unlock();
            return;
        };

        if (locked_by == current_task.task) {
            switch (self.unlock_type) {
                .passed_to_waiter => {
                    @branchHint(.likely);
                    // the mutex was passed directly to us
                    self.spinlock.unlock();
                    return;
                },
                .unlocked => {
                    @branchHint(.cold);
                    @panic("recursive lock!");
                },
            }
        }

        self.wait_queue.wait(&self.spinlock);
    }
}

/// Try to lock the mutex.
pub fn tryLock(self: *Mutex) bool {
    const current_task: innigkeit.Task.Current = .get();

    const locked_by = self.locked_by.cmpxchgStrong(
        null,
        current_task.task,
        .acquire,
        .monotonic,
    ) orelse return true;

    if (locked_by == current_task.task) {
        @branchHint(.cold);
        if (core.is_debug) {
            // TODO: this could only happen if we were queued for the mutex but then how would we call tryLock?
            std.debug.assert(self.unlock_type != .passed_to_waiter);
        }
        @panic("recursive lock!");
    }

    return false;
}

pub fn unlock(self: *Mutex) void {
    self.spinlock.lock();
    defer self.spinlock.unlock();

    const current_task: innigkeit.Task.Current = .get();

    const waiting_task = self.wait_queue.firstTask() orelse {
        self.unlock_type = .unlocked;

        if (self.locked_by.cmpxchgStrong(
            current_task.task,
            null,
            .release,
            .monotonic,
        )) |_| {
            @branchHint(.cold);
            @panic("not locked by current task!");
        }

        return;
    };

    // pass the mutex directly to the waiting task
    self.unlock_type = .passed_to_waiter;

    if (self.locked_by.cmpxchgStrong(
        current_task.task,
        waiting_task,
        .release,
        .monotonic,
    )) |_| {
        @branchHint(.cold);
        @panic("not locked by current task!");
    }

    self.wait_queue.wakeOne(&self.spinlock);
}

/// Returns `true` if the mutex is locked.
pub fn isLocked(self: *Mutex) bool {
    return self.locked_by.load(.monotonic) != null;
}

const UnlockType = enum {
    /// The mutex was passed directly to the first waiting task.
    passed_to_waiter,
    /// The mutex was unlocked normally.
    unlocked,
};
