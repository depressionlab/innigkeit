//! A synchronization primitive that allows a single task to block (park) and any other task to wake it (unpark).
const Parker = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");

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

    scheduler_handle = scheduler_handle.block(
        .{
            .action = struct {
                fn action(old_task: *innigkeit.Task, arg: usize) void {
                    const inner_parker: *Parker = @ptrFromInt(arg);

                    old_task.state = .blocked;
                    old_task.spinlocks_held -= 1;
                    _ = old_task.interrupt_disable_count.fetchSub(1, .acq_rel);

                    inner_parker.parked_task = old_task;
                    inner_parker.lock.unsafeUnlock();
                }
            }.action,
            .arg = @intFromPtr(self),
        },
    );

    self.unpark_attempts.store(0, .release);
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
        break :blk parked_task;
    };

    parked_task.wakeFromBlocked();
}
