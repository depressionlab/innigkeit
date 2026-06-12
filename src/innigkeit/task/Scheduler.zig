const Scheduler = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const Handle = @import("Handle.zig");
pub const Runqueue = @import("Runqueue.zig");

const SchedClass = @import("SchedClass.zig");
const wallclock = innigkeit.time.wallclock;

single_spin_lock: innigkeit.sync.SingleSpinLock = .{},
runqueue: Runqueue = .{},

/// Idle handshake flag: true while this executor's idle loop is about to halt
/// (or is halted) with an empty runqueue.
///
/// Lost-wakeup-freedom invariant: the idle loop performs its FINAL
/// runqueue-empty check and sets this flag while holding `single_spin_lock`,
/// then unlocks and halts. Every remote enqueue also happens under that same
/// lock (see `queueTaskOnRemote`). Therefore, after enqueueing and unlocking,
/// a waker that reads `idle == false` knows the idle loop's final check
/// happens-after its enqueue and will see the task; if it reads `idle == true`
/// it sends a reschedule IPI (when the architecture provides one), breaking
/// the target out of `halt`. Either way the wakeup cannot be lost; on
/// architectures without a reschedule IPI the 5 ms tick remains the backstop.
idle: std.atomic.Value(bool) = .init(false),

/// Number of reschedule IPIs received by this executor.
///
/// Diagnostics/tests only; incremented by the (otherwise empty) reschedule
/// IPI handler.
reschedule_ipi_count: std.atomic.Value(u64) = .init(0),

/// Number of tasks this executor's idle loop has stolen from other executors.
///
/// Diagnostics/tests only.
steal_count: std.atomic.Value(u64) = .init(0),

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

/// Run the per-tick accounting for `curr`.
///
/// Returns true if preemption is warranted.
pub fn tick(self: *Scheduler, curr: *innigkeit.Task, now: wallclock.Tick) bool {
    return self.runqueue.tick(curr, now);
}

pub fn lock(self: *Scheduler) void {
    self.single_spin_lock.lock();
    innigkeit.Task.Current.get().task.scheduler_locked = true;
}

/// Attempt to lock the scheduler without spinning.
///
/// Returns true if the lock was acquired (release with `unlock`).
///
/// Used by the idle work-stealing path: a stealer never waits for a victim's
/// lock, it simply retries on its next idle iteration.
pub fn tryLock(self: *Scheduler) bool {
    if (!self.single_spin_lock.tryLock()) return false;
    innigkeit.Task.Current.get().task.scheduler_locked = true;
    return true;
}

pub fn unlock(self: *Scheduler) void {
    innigkeit.Task.Current.get().task.scheduler_locked = false;
    self.single_spin_lock.unlock();
}

/// Enqueue `task` onto `executor`'s runqueue and kick the executor out of its
/// idle halt if necessary.
///
/// This is the ONE way to place a task on another executor's runqueue; it
/// pairs the enqueue with the idle handshake (see the `idle` field) so the
/// wakeup cannot be lost.
///
/// Scheduler lock rule (deadlock-freedom argument): no path in the kernel
/// ever holds two scheduler locks at the same time. The caller must therefore
/// hold NO scheduler lock when calling this; while `executor`'s lock is held
/// here no other scheduler lock is taken.
pub fn queueTaskOnRemote(
    executor: *innigkeit.Executor,
    task: *innigkeit.Task,
    flags: SchedClass.EnqueueFlags,
) void {
    if (core.is_debug) {
        std.debug.assert(!innigkeit.Task.Current.get().task.scheduler_locked);
        std.debug.assert(!task.is_scheduler_task);
        std.debug.assert(task.state == .ready);
    }

    executor.scheduler.lock();
    executor.scheduler.queueTask(task, flags);
    executor.scheduler.unlock();

    kickIfIdle(executor);
}

/// If `executor` is (about to be) halted in its idle loop, send it a
/// reschedule IPI so it picks up newly queued work immediately instead of at
/// its next 5 ms tick.
///
/// Must be called AFTER enqueueing under (and releasing) `executor`'s
/// scheduler lock: the lock orders the enqueue against the idle loop's final
/// empty check + flag set, so either the idle loop saw the task or `idle` is
/// observed true here (see the `idle` field invariant).
///
/// No-op on architectures without a reschedule IPI; the periodic tick remains
/// the pickup mechanism there.
pub fn kickIfIdle(executor: *innigkeit.Executor) void {
    if (comptime !architecture.interrupts.reschedule_ipi_available) return;
    if (executor.scheduler.idle.load(.seq_cst)) {
        architecture.interrupts.sendRescheduleIPI(executor);
    }
}

/// Asserts that the scheduler lock is held by the current task.
pub inline fn assertLocked(self: *const Scheduler) void {
    if (core.is_debug) {
        std.debug.assert(innigkeit.Task.Current.get().task.scheduler_locked);
        std.debug.assert(self.single_spin_lock.isLockedByCurrent());
    }
}
