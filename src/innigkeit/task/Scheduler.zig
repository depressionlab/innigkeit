const Scheduler = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const Handle = @import("Handle.zig");

single_spin_lock: innigkeit.sync.SingleSpinLock = .{},
ready_to_run: core.containers.FIFO = .{},

/// Used as the current task during idle and also during the transition between tasks when executing a deferred action.
task: innigkeit.Task,

pub fn queueTask(self: *Scheduler, task: *innigkeit.Task) void {
    self.ready_to_run.append(&task.next_task_node);
}

pub fn isEmpty(self: *const Scheduler) bool {
    return self.ready_to_run.isEmpty();
}

pub fn getNextTask(self: *Scheduler) ?*innigkeit.Task {
    const task_node = self.ready_to_run.pop() orelse return null; // no tasks to run
    const task: *innigkeit.Task = .fromNode(task_node);

    if (core.is_debug) {
        std.debug.assert(!task.is_scheduler_task);
        std.debug.assert(task.state == .ready);
    }

    return task;
}

pub fn lock(self: *Scheduler) void {
    self.single_spin_lock.lock();
    innigkeit.Task.Current.get().task.scheduler_locked = true;
}

pub fn unlock(self: *Scheduler) void {
    innigkeit.Task.Current.get().task.scheduler_locked = false;
    self.single_spin_lock.unlock();
}

/// Asserts that the scheduler lock is held by the current task.
pub inline fn assertLocked(self: *const Scheduler) void {
    if (core.is_debug) {
        std.debug.assert(innigkeit.Task.Current.get().task.scheduler_locked);
        std.debug.assert(self.single_spin_lock.isLockedByCurrent());
    }
}
