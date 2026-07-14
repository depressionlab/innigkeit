//! A synchronization primitive that allows a single task to block (park) and any other task to wake it (unpark).
const Parker = @This();

const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

lock: innigkeit.sync.TicketSpinLock = .{},
parked_task: ?*innigkeit.Task,
unpark_attempts: std.atomic.Value(usize) = .init(0),

pub const empty: Parker = .{ .parked_task = null };

/// Initialize the parker with a already parked task.
///
/// The task will be set to the `blocked` state.
///
/// It is the caller's responsibility to ensure that the task is not currently running, queued for scheduling,
/// or blocked.
pub fn withParkedTask(parked_task: *innigkeit.Task) Parker {
    if (core.is_debug) std.debug.assert(parked_task.state == .ready);
    parked_task.state = .blocked;
    return .{ .parked_task = parked_task };
}

/// Park (block) the current task.
///
/// Spurious wakeups are possible.
pub fn park(self: *Parker) void {
    if (core.is_debug) std.debug.assert(innigkeit.Task.Current.get().task.state == .running);

    if (self.unpark_attempts.swap(0, .acq_rel) != 0) {
        return; // there were some wakeups, they might be spurious
    }

    var scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();

    // recheck for unpark attempts that happened while we were locking the scheduler
    if (self.unpark_attempts.swap(0, .acq_rel) != 0) {
        @branchHint(.unlikely);
        return;
    }

    self.lock.lock();
    if (core.is_debug) std.debug.assert(self.parked_task == null);

    // recheck for unpark attempts that happened while we were locking the parker lock
    if (self.unpark_attempts.swap(0, .acq_rel) != 0) {
        @branchHint(.unlikely);
        self.lock.unlock();
        return;
    }

    scheduler_handle.block(.{
        .action = struct {
            fn action(old_task: *innigkeit.Task, arg: usize) void {
                // `arg` is always `@intFromPtr(self)` from the single call site below.
                const inner_parker: *Parker = @ptrFromInt(arg);

                old_task.state = .blocked;
                old_task.spinlocks_held -= 1;
                _ = old_task.interrupt_disable_count.fetchSub(1, .acq_rel);

                inner_parker.parked_task = old_task;
                inner_parker.lock.unsafeUnlock();
            }
        }.action,
        .arg = @intFromPtr(self),
    });

    // `unpark_attempts` is reset by the unparker that woke us (while it held
    // the parker lock), so any unpark attempts that raced in *after* the wake
    // are preserved and will satisfy the next `park` call.
}

/// Unpark (wake) the parked task if it is currently parked.
pub fn unpark(self: *Parker) void {
    if (self.unpark_attempts.fetchAdd(1, .acq_rel) != 0) {
        // someone else was the first to attempt to unpark the task, so we can leave waking the task to them
        return;
    }

    const parked_task = blk: {
        self.lock.lock();
        defer self.lock.unlock();

        const parked_task = self.parked_task orelse return;
        self.parked_task = null;

        // Consume the attempts that this wake satisfies. Done while holding
        // the lock so attempts arriving after this point are kept for the
        // task's next `park` call rather than being clobbered by the waker.
        self.unpark_attempts.store(0, .release);

        break :blk parked_task;
    };

    parked_task.wakeFromBlocked();
}

test "Parker: unpark with no parked task records an attempt; park consumes it without blocking" {
    var parker: Parker = .empty;

    // No task is parked: the wake is recorded as a pending attempt.
    parker.unpark();
    try std.testing.expect(parker.parked_task == null);
    try std.testing.expectEqual(@as(usize, 1), parker.unpark_attempts.load(.monotonic));

    // The pending attempt satisfies park() on its fast path: it returns
    // immediately (without ever touching the scheduler) and consumes the token.
    parker.park();
    try std.testing.expectEqual(@as(usize, 0), parker.unpark_attempts.load(.monotonic));
    try std.testing.expect(parker.parked_task == null);

    // Multiple unparks coalesce; only the first does the (no-op) wake walk,
    // later ones just bump the counter. A single park consumes them all.
    parker.unpark();
    parker.unpark();
    try std.testing.expectEqual(@as(usize, 2), parker.unpark_attempts.load(.monotonic));
    parker.park();
    try std.testing.expectEqual(@as(usize, 0), parker.unpark_attempts.load(.monotonic));
    try std.testing.expect(parker.parked_task == null);
}
