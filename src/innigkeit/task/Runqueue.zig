//! Per-executor multi-class run queue.
//!
//! Holds a sub-queue for each scheduling class and dispatches operations
//! through the task's `sched_class` vtable.
//!
//! The real-time class always takes precedence over the fair (EEVDF) class.
const Runqueue = @This();

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

/// Intel Hybrid core type of the executor that owns this runqueue.
/// Set by initExecutor after CPUID.1AH detection. Used for soft P/E affinity.
executor_core_type: innigkeit.Executor.CoreType = .unknown,

/// Enqueue a task.
///
/// For initial spawns pass `flags.initial=true`; for wakeups pass `flags.wakeup=true`.
pub fn enqueueTask(self: *Runqueue, task: *innigkeit.Task, flags: SchedClass.EnqueueFlags) void {
    if (flags.initial) task.sched_class.task_new(self, task);
    task.sched_class.enqueue(self, task, flags);
    self.nr_running += 1;
}

pub fn dequeueTask(self: *Runqueue, task: *innigkeit.Task, flags: SchedClass.DequeueFlags) void {
    task.sched_class.dequeue(self, task, flags);
    if (self.nr_running > 0) self.nr_running -= 1;
}

/// Update `prev`'s accounting before switching away from it.
/// Re-enqueues `prev` into the run queue if prev.state == .ready.
/// Also increments nr_running in that case (to stay consistent with setNextRunning).
pub fn putPrevTask(self: *Runqueue, prev: *innigkeit.Task) void {
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
    if (self.nr_running > 0) self.nr_running -= 1;
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
