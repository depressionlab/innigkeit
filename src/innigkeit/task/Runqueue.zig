//! Per-executor multi-class run queue.
//!
//! Holds a sub-queue for each scheduling class and dispatches operations
//! through the task's `sched_class` vtable.
//!
//! The real-time class always takes precedence over the fair (EEVDF) class.
const Runqueue = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");
const SchedClass = @import("SchedClass.zig");
const Eevdf = @import("sched/Eevdf.zig");
const Rt = @import("sched/Rt.zig");
const wallclock = innigkeit.time.wallclock;

rt: Rt.RtRunqueue = .{},
eevdf: Eevdf.EevdfRunqueue = .{},

/// Runnable tasks in the queue (not counting the currently-executing task).
/// Incremented by enqueueTask; decremented by dequeueTask and setNextRunning.
/// putPrevTask with re-enqueue increments;
/// setNextRunning decrements, causing net zero for yields.
nr_running: u32 = 0,

/// Lock-free mirror of `nr_running` giving other executors a cheap
/// queue-depth read for steal-victim selection.
///
/// Updated (monotonic store via `syncQueuedHint`) immediately next to every
/// `nr_running` mutation, all of which happen under the owning scheduler's
/// lock: keep the two adjacent so they cannot drift. Readers must treat the
/// value as a hint only and re-validate under the victim's scheduler lock.
queued_hint: std.atomic.Value(u32) = .init(0),

/// Intel Hybrid core type of the executor that owns this runqueue.
/// Set by initExecutor after CPUID.1AH detection. Used for soft P/E affinity.
executor_core_type: innigkeit.Executor.CoreType = .unknown,

/// Enqueue a task.
///
/// For initial spawns pass `flags.initial=true`; for wakeups pass `flags.wakeup=true`.
pub fn enqueueTask(self: *Runqueue, task: *innigkeit.Task, flags: SchedClass.EnqueueFlags) void {
    // Initial dispatches and block-wakeups resume through a re-derived
    // scheduler handle (taskEntry / Handle.block), so they are safe to
    // migrate to another executor; see Task.stealable.
    task.stealable = flags.initial or flags.wakeup;
    if (flags.initial) task.sched_class.task_new(self, task);
    task.sched_class.enqueue(self, task, flags);
    self.nr_running += 1;
    self.syncQueuedHint();
}

pub fn dequeueTask(self: *Runqueue, task: *innigkeit.Task, flags: SchedClass.DequeueFlags) void {
    task.sched_class.dequeue(self, task, flags);
    std.debug.assert(self.nr_running > 0);
    self.nr_running -= 1;
    self.syncQueuedHint();
}

/// Mirror `nr_running` into the lock-free `queued_hint`.
///
/// Must be called (with the owning scheduler's lock held) right after every
/// `nr_running` mutation, including the ones in the sched-class `putPrev`
/// implementations.
pub inline fn syncQueuedHint(self: *Runqueue) void {
    self.queued_hint.store(self.nr_running, .monotonic);
}

/// Remove and return one stealable task, or null if there is none.
///
/// Caller must hold the owning scheduler's lock.
///
/// Only fair-class (EEVDF) tasks with `migration_disable_count == 0` are
/// stealable; RT tasks (which live in the RT FIFOs, not the EEVDF tree) and
/// migration-pinned tasks are never stolen. The dequeue goes through the
/// regular class vtable, so all EEVDF avg/augmentation bookkeeping (including
/// saving the task's lag for wakeup-style placement on the thief's queue)
/// is reused.
pub fn stealOneFair(self: *Runqueue) ?*innigkeit.Task {
    const task = Eevdf.findStealable(&self.eevdf) orelse return null;
    self.dequeueTask(task, .{ .migrated = true });
    return task;
}

/// Update `prev`'s accounting before switching away from it.
/// Re-enqueues `prev` into the run queue if prev.state == .ready.
/// Also increments nr_running in that case (to stay consistent with setNextRunning).
pub fn putPrevTask(self: *Runqueue, prev: *innigkeit.Task) void {
    // A task re-enqueued mid-yield/preemption resumes into a stack frame
    // holding a Scheduler.Handle captured on THIS executor; stealing it
    // would make it unlock the wrong scheduler. See Task.stealable.
    prev.stealable = false;
    prev.sched_class.put_prev(self, prev);
}

/// Select the next task.
/// Returns null if no task is ready (caller should switch to idle).
/// May return `prev` if the current task should keep running.
///
/// Soft P/E affinity: if this executor has a known core_type and the EEVDF
/// winner has a mismatching core_hint, a second task with the right hint is
/// preferred PROVIDED it exists and has a later-or-equal vruntime vs. the
/// winner by at most 2x (prevents starvation of mismatched tasks).
pub fn pickNext(self: *Runqueue, prev: ?*innigkeit.Task) ?*innigkeit.Task {
    // RT always preempts fair tasks.
    if (self.rt.pickNext()) |t| return t;

    const candidate = self.eevdf.pickNext(prev) orelse return null;

    // Fast path: no affinity filter needed.
    const my_type = self.executor_core_type;
    if (my_type == .unknown) return candidate;
    const hint = candidate.core_hint;
    if (hint == .unknown or hint == my_type) return candidate;

    // The best task has a mismatching hint. If only one task is queued we
    // must run it anyway to prevent starvation.
    if (self.nr_running <= 1) return candidate;

    // Try to find a better-matched task from the EEVDF alternate selection.
    if (self.eevdf.pickPreferring(prev, my_type, candidate)) |better| return better;

    return candidate;
}

/// Finalize the picked task as the running task.
/// Removes it from the queue and performs class-specific bookkeeping
/// (removes from EEVDF tree, sets exec_start).
/// Decrements nr_running because the task is leaving the queue.
pub fn setNextRunning(self: *Runqueue, task: *innigkeit.Task) void {
    std.debug.assert(self.nr_running > 0);
    self.nr_running -= 1;
    self.syncQueuedHint();
    if (task.sched_class == &SchedClass.fair_class) {
        Eevdf.setRunning(&self.eevdf, task);
    }
    // RT: already popped from FIFO in pickNext.
    // Idle: no-op.
}

/// Run the scheduler tick for `curr`.
///
/// Returns `true` if preemption is warranted.
pub fn tick(self: *Runqueue, curr: *innigkeit.Task, now: wallclock.Tick) bool {
    return curr.sched_class.tick(self, curr, now);
}

pub fn isEmpty(self: *const Runqueue) bool {
    return self.nr_running == 0;
}
