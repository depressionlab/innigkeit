//! Real-time scheduling class.
//!
//! Implements fixed-priority preemptive scheduling with FIFO ordering within
//! each priority level. RT tasks always preempt fair (EEVDF) tasks.
//!
//! Priority range: 0 (highest) ... 99 (lowest).
//! Within a priority level tasks are scheduled FIFO.
//!
//! The active priority levels are tracked in a 128-bit bitmap for O(1)
//! highest-priority selection.
const core = @import("core");
const innigkeit = @import("innigkeit");
const Runqueue = @import("../Runqueue.zig");
const SchedClass = @import("../SchedClass.zig");
const std = @import("std");

const wallclock = innigkeit.time.wallclock;
const FIFO = core.containers.FIFO;
const log = innigkeit.debug.log.scoped(.rt_sched);

pub const rt_priority_max: u7 = 99;

/// Per-task RT scheduling data
pub const RtSchedEntity = struct {
    /// RT priority: 0 = highest, 99 = lowest.
    priority: u7 = 50,

    /// Linked-list node used when in an RT run queue.
    /// Reuses next_task_node conventions.
    ///
    /// This is safe because RT-ready tasks cannot simultaneously be in a wait queue.
    rt_node: std.SinglyLinkedList.Node = .{},
};

// Per-executor RT run queue
pub const RtRunqueue = struct {
    /// One FIFO per priority level.
    queues: [100]FIFO = @splat(.{}),

    /// Bitmask of non-empty priority levels.
    /// Bit `i` set <-> queues[i] non-empty.
    bitmap: u128 = 0,

    /// Total RT tasks queued.
    nr_queued: u32 = 0,

    pub fn pickNext(self: *RtRunqueue) ?*innigkeit.Task {
        if (self.bitmap == 0) return null;
        const highest: u7 = @intCast(@ctz(self.bitmap));
        const node = self.queues[highest].pop() orelse return null;
        const task = innigkeit.Task.fromNode(node);
        if (self.queues[highest].isEmpty()) {
            self.bitmap &= ~(@as(u128, 1) << highest);
        }
        self.nr_queued -= 1;
        return task;
    }

    fn push(self: *RtRunqueue, task: *innigkeit.Task) void {
        const prio = task.rt_sched.priority;
        self.queues[prio].append(&task.next_task_node);
        self.bitmap |= @as(u128, 1) << prio;
        self.nr_queued += 1;
    }

    fn remove(self: *RtRunqueue, task: *innigkeit.Task) void {
        // Linear scan within the priority level, acceptable for small queues.
        // A doubly-linked list would give O(1) but adds complexity.
        const prio = task.rt_sched.priority;
        var fifo = &self.queues[prio];

        // Walk and rebuild without the target node.
        var rebuilt: FIFO = .{};
        var node_opt = fifo.pop();
        var found = false;
        while (node_opt) |n| {
            if (n == &task.next_task_node) {
                found = true;
            } else {
                rebuilt.append(n);
            }
            node_opt = fifo.pop();
        }
        self.queues[prio] = rebuilt;

        if (self.queues[prio].isEmpty()) {
            self.bitmap &= ~(@as(u128, 1) << prio);
        }
        if (found) self.nr_queued -= 1;
    }
};

pub fn enqueue(rq: *Runqueue, task: *innigkeit.Task, flags: SchedClass.EnqueueFlags) void {
    _ = flags;
    rq.rt.push(task);
    if (core.is_debug)
        log.verbose("rt enqueue {f} prio={}", .{ task, task.rt_sched.priority });
}

pub fn dequeue(rq: *Runqueue, task: *innigkeit.Task, flags: SchedClass.DequeueFlags) void {
    _ = flags;
    rq.rt.remove(task);
    if (core.is_debug)
        log.verbose("rt dequeue {f}", .{task});
}

pub fn pickNext(rq: *Runqueue, prev: ?*innigkeit.Task) ?*innigkeit.Task {
    _ = prev;
    return rq.rt.pickNext();
}

pub fn putPrev(rq: *Runqueue, prev: *innigkeit.Task) void {
    // RT FIFO: re-enqueue at the back of the priority level if still runnable.
    // Caller must have set prev.state = .ready before calling for yields.
    if (prev.state == .ready) {
        rq.rt.push(prev);
        rq.nr_running += 1; // balance the setNextRunning decrement that will follow
        rq.syncQueuedHint();
    }
}

pub fn tick(rq: *Runqueue, curr: *innigkeit.Task, now: wallclock.Tick) bool {
    // RT FIFO: never preempt a running RT task for another RT task at the
    // same priority. Preempt if a higher-priority RT task becomes ready
    // (handled at enqueue via IPI in a future SMP implementation).
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
