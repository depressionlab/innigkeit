//! Scheduler class dispatch table.
//!
//! Each scheduling class (RT, fair/EEVDF, idle) provides a vtable of this shape.
//! Tasks carry a pointer to their class, allowing the scheduler to dispatch
//! operations without knowing which class is active.
//!
//! Class priority order (lower prio value = higher scheduling priority):
//!   rt (0) > fair (1) > idle (2)
const SchedClass = @This();

const innigkeit = @import("innigkeit");
const Runqueue = @import("Runqueue.zig");
const wallclock = innigkeit.time.wallclock;

pub const EnqueueFlags = packed struct(u8) {
    /// Task is waking from sleep (vruntime placement differs from a running task).
    wakeup: bool = false,
    /// Task was stolen or migrated from another executor.
    migrated: bool = false,
    /// Task is being placed for the very first time (fork/spawn).
    initial: bool = false,
    _pad: u5 = 0,
};

pub const DequeueFlags = packed struct(u8) {
    /// Task is going to sleep; preserve vruntime lag for next wakeup.
    sleep: bool = false,
    /// Task will migrate to another executor.
    migrated: bool = false,
    _pad: u6 = 0,
};

/// Place the task onto the run queue.
enqueue: *const fn (rq: *Runqueue, task: *innigkeit.Task, flags: EnqueueFlags) void,
/// Remove the task from the run queue.
dequeue: *const fn (rq: *Runqueue, task: *innigkeit.Task, flags: DequeueFlags) void,
/// Select the next task to run. May return `prev` to mean "keep running".
pick_next: *const fn (rq: *Runqueue, prev: ?*innigkeit.Task) ?*innigkeit.Task,
/// Called before switching away from `prev` (update accounting).
put_prev: *const fn (rq: *Runqueue, prev: *innigkeit.Task) void,
/// Timer tick. Returns true if the current task should be preempted.
tick: *const fn (rq: *Runqueue, curr: *innigkeit.Task, now: wallclock.Tick) bool,
/// Called once right after a task is forked/spawned, before first enqueue.
task_new: *const fn (rq: *Runqueue, task: *innigkeit.Task) void,
/// Called when a sleeping task becomes runnable (before enqueue).
task_waking: *const fn (task: *innigkeit.Task) void,
/// Called when a task is about to be destroyed.
task_dead: *const fn (task: *innigkeit.Task) void,

/// Scheduling priority of this class. Lower = more urgent.
prio: u8,

pub fn make(comptime Impl: type, comptime priority: u8) SchedClass {
    return .{
        .enqueue = Impl.enqueue,
        .dequeue = Impl.dequeue,
        .pick_next = Impl.pickNext,
        .put_prev = Impl.putPrev,
        .tick = Impl.tick,
        .task_new = Impl.taskNew,
        .task_waking = Impl.taskWaking,
        .task_dead = Impl.taskDead,
        .prio = priority,
    };
}

const eevdf_impl = @import("sched/Eevdf.zig");
const rt_impl = @import("sched/Rt.zig");
const idle_impl = @import("sched/Idle.zig");

pub const rt_class: SchedClass = SchedClass.make(rt_impl, 0);
pub const fair_class: SchedClass = SchedClass.make(eevdf_impl, 1);
pub const idle_class: SchedClass = SchedClass.make(idle_impl, 2);

/// Default class for new tasks (fair/EEVDF).
pub const default_class: *const SchedClass = &fair_class;
