const Scheduler = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const Handle = @import("Handle.zig");
pub const Runqueue = @import("Runqueue.zig");

const SchedClass = @import("SchedClass.zig");
const wallclock = innigkeit.time.wallclock;

single_spin_lock: innigkeit.sync.SingleSpinLock = .{},
runqueue: Runqueue = .{},

/// Used as the current task during idle and also during the transition between tasks when executing a deferred action.
task: innigkeit.Task,

/// Enqueue a task for the first time (after fork/spawn).
/// Calls the class's task_new hook to place vruntime correctly.
pub fn spawnTask(self: *Scheduler, task: *innigkeit.Task) void {
    self.queueTask(task, .{ .initial = true });
}

/// Enqueue a task with explicit flags.
/// Use .initial for first-ever enqueue; .wakeup for waking from blocked.
pub fn queueTask(self: *Scheduler, task: *innigkeit.Task, flags: SchedClass.EnqueueFlags) void {
    self.runqueue.enqueueTask(task, flags);
}

/// Update the current task's accounting and re-enqueue if still runnable.
/// The caller must set task.state = .ready BEFORE calling if this is a voluntary yield.
/// For block/terminate, leave state as .running: `putPrev` will skip re-enqueue.
pub fn putPrevTask(self: *Scheduler, prev: *innigkeit.Task) void {
    self.runqueue.putPrevTask(prev);
}

/// Finalize a picked task as the next to run.
/// Removes it from the run queue and sets up class-specific running state.
pub fn setNextRunning(self: *Scheduler, task: *innigkeit.Task) void {
    self.runqueue.setNextRunning(task);
}

pub fn isEmpty(self: *const Scheduler) bool {
    return self.runqueue.isEmpty();
}

pub fn getNextTask(self: *Scheduler) ?*innigkeit.Task {
    return self.runqueue.pickNext(null);
}

/// Run the per-tick accounting for `curr`.  Returns true if preemption is warranted.
pub fn tick(self: *Scheduler, curr: *innigkeit.Task, now: wallclock.Tick) bool {
    return self.runqueue.tick(curr, now);
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
