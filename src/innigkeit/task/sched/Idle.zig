//! Idle scheduling class.
//!
//! The idle "task" is special: it is the per-executor scheduler task that runs
//! the halt loop when no other work is available.  It never competes with real
//! tasks and is handled directly by Handle.zig rather than through the normal
//! dispatch path.
//!
//! This vtable exists so that the idle task has a valid sched_class pointer
//! and scheduler-class assertions never fire unexpectedly.
const innigkeit = @import("innigkeit");
const Runqueue = @import("../Runqueue.zig");
const SchedClass = @import("../SchedClass.zig");
const wallclock = innigkeit.time.wallclock;

pub fn enqueue(rq: *Runqueue, task: *innigkeit.Task, flags: SchedClass.EnqueueFlags) void {
    _ = rq;
    _ = task;
    _ = flags;
    @panic("idle task must not be enqueued");
}

pub fn dequeue(rq: *Runqueue, task: *innigkeit.Task, flags: SchedClass.DequeueFlags) void {
    _ = rq;
    _ = task;
    _ = flags;
    @panic("idle task must not be dequeued");
}

pub fn pickNext(rq: *Runqueue, prev: ?*innigkeit.Task) ?*innigkeit.Task {
    _ = rq;
    _ = prev;
    return null;
}

pub fn putPrev(rq: *Runqueue, prev: *innigkeit.Task) void {
    _ = rq;
    _ = prev;
}

pub fn tick(rq: *Runqueue, curr: *innigkeit.Task, now: wallclock.Tick) bool {
    _ = rq;
    _ = curr;
    _ = now;
    return false;
}

pub fn taskNew(rq: *Runqueue, task: *innigkeit.Task) void {
    _ = rq;
    _ = task;
}

pub fn taskWaking(task: *innigkeit.Task) void {
    _ = task;
}

pub fn taskDead(task: *innigkeit.Task) void {
    _ = task;
}
