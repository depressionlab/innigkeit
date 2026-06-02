//! Represents a schedulable task.
//!
//! Can be either a kernel or userspace task.
const Task = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const Current = @import("Current.zig");
pub const Scheduler = @import("Scheduler.zig");
pub const Stack = @import("Stack.zig");
pub const internal = @import("core/internal.zig");
pub const init = @import("core/init.zig");
pub const Transition = @import("core/Transition.zig");
const globals = @import("core/globals.zig");

const SchedClass = @import("SchedClass.zig");
const Eevdf = @import("sched/Eevdf.zig");
const Rt = @import("sched/Rt.zig");

const log = innigkeit.debug.log.scoped(.task);

/// Identifies why this task is currently in the .blocked state.
/// Undefined when state != .blocked.
pub const BlockReason = enum(u8) {
    futex = 0, // blocked in a futex bucket (futex_addr is set)
    sleep = 1, // blocked in the nanosleep queue (sleep_deadline_ms is set)
    ipc = 2, // blocked for IPC (endpoint recv or reply)
    notify = 3, // blocked waiting for a Notify signal
    futex_timeout = 4, // blocked in futex bucket with a deadline (futex_timeout_ms is set)
    other = 5,
};

/// The name of the task.
///
/// For kernel tasks this is always explicitly provided.
///
/// For user tasks this starts as a process local incrementing number but can be changed by the user.
name: Name,

type: innigkeit.Context.Type,

is_scheduler_task: bool = false,

state: State,

/// The number of references to this task.
///
/// Each task has a reference to itself which is dropped when the scheduler terminates the task.
reference_count: std.atomic.Value(usize) = .init(1), // tasks start with a reference to themselves

/// The stack used by this task in kernelspace.
stack: Stack,

/// Used for various linked lists including:
/// - wait queue
/// - the kernel task cleanup service
/// - RT scheduler queue (when sched_class == &SchedClass.rt_class)
next_task_node: std.SinglyLinkedList.Node = .{},

/// Set to the executor the current task is running on if the state of the task means that the executor cannot
/// change underneath us (for example when interrupts are disabled).
///
/// Set to null otherwise.
///
/// The value is undefined when the task is not running.
known_executor: ?*innigkeit.Executor,

/// Tracks the depth of nested interrupt disables.
interrupt_disable_count: std.atomic.Value(u32) = .init(1), // tasks always start with interrupts disabled

/// Tracks the depth of nested migration disables.
migration_disable_count: std.atomic.Value(u32),

/// Tracks nested enables of access to user memory.
enable_access_to_user_memory_count: std.atomic.Value(u32) = .init(0),

spinlocks_held: u32,
scheduler_locked: bool,

arch_specific: architecture.scheduling.PerTask,

/// EEVDF fair-class scheduling entity.
///
/// Populated for all tasks regardless of class, since tasks may migrate between classes
/// at runtime (with a SchedCap capability).
sched: Eevdf.SchedEntity = .{},

/// Real-time scheduling entity.
///
/// Active when sched_class == &SchedClass.rt_class.
rt_sched: Rt.RtSchedEntity = .{},

/// The scheduling class this task currently belongs to.
///
/// Default: fair class (EEVDF).
///
/// Requires SchedCap to change.
sched_class: *const SchedClass = SchedClass.default_class,

/// Set by the scheduler class tick() when the task should be preempted at the
/// next safe point (scheduler lock not held, spinlocks_held == 0).
needs_resched: bool = false,

/// Per-task IPC scratch used by Endpoint.call() / Endpoint.reply():
///   - Caller writes message here before blocking; replier writes reply here before waking.
ipc_message: innigkeit.capabilities.Message = .{},

/// Virtual address this task is blocked on via futex_wait.
/// Zero when not blocked in a futex bucket.
futex_addr: usize = 0,

/// Uptime-ms deadline set by nanosleep; zero when not sleeping.
sleep_deadline_ms: u64 = 0,

/// Uptime-ms deadline set by futex_wait_timeout; zero when not in a timed futex wait.
futex_timeout_ms: u64 = 0,

block_reason: BlockReason = .other,

/// Preferred core type for scheduling on hybrid platforms.
/// Scheduler may honour this hint when choosing a run queue.
/// `.unknown` means no preference (scheduler decides).
core_hint: innigkeit.Executor.CoreType = .unknown,

pub const State = union(enum) {
    ready,
    /// Do not access the executor directly, use `known_executor` instead.
    running: *innigkeit.Executor,
    blocked,
    terminated: Terminated,

    pub const Terminated = struct {
        queued_for_cleanup: std.atomic.Value(bool) = .init(false),
    };
};

pub fn incrementReferenceCount(task: *Task) void {
    _ = task.reference_count.fetchAdd(1, .acq_rel);
}

/// Decrements the reference count of the task.
///
/// If it reaches zero the task is submitted to the task cleanup service.
///
/// This must **not** be called when the task is the current task, see `Scheduler.Handle.terminate` instead.
pub fn decrementReferenceCount(task: *Task) void {
    if (task == Task.Current.get().task) @panic("cannot decrement reference count of current task");

    if (task.reference_count.fetchSub(1, .acq_rel) != 1) {
        @branchHint(.likely);
        return;
    }
    globals.task_cleanup.queueTaskForCleanup(task);
}

pub fn wakeFromBlocked(task_to_wake: *innigkeit.Task) void {
    if (core.is_debug) std.debug.assert(task_to_wake.state == .blocked);
    task_to_wake.state = .ready;

    if (task_to_wake.migration_disable_count.load(.acquire) != 0) {
        const current_task: innigkeit.Task.Current = .get();
        current_task.incrementMigrationDisable();
        defer current_task.decrementMigrationDisable();

        if (current_task.task.known_executor == task_to_wake.known_executor) {
            const maybe_locked: innigkeit.Task.Scheduler.Handle.MaybeLocked = .get();
            defer maybe_locked.unlock();

            maybe_locked.scheduler_handle.queueTask(task_to_wake, .{ .wakeup = true });

            return;
        }

        const executor = task_to_wake.known_executor orelse std.debug.panic(
            "{f} has non-zero migration disable but no known executor!",
            .{task_to_wake},
        );

        executor.scheduler.lock();
        defer executor.scheduler.unlock();

        executor.scheduler.queueTask(task_to_wake, .{ .wakeup = true });
        return;
    }

    const maybe_locked: innigkeit.Task.Scheduler.Handle.MaybeLocked = .get();
    defer maybe_locked.unlock();

    maybe_locked.scheduler_handle.queueTask(task_to_wake, .{ .wakeup = true });
}

pub const CreateKernelTaskOptions = struct {
    name: Name,
    entry: core.TypeErasedCall,
};

/// Create a kernel task.
///
/// The task is in the `ready` state and is not scheduled.
/// Callers must use `Scheduler.Handle.queueTask(task, .{ .initial = true })` for the first enqueue.
pub fn createKernelTask(options: CreateKernelTaskOptions) !*Task {
    const task = try globals.kernel_task_cache.allocate();
    errdefer globals.kernel_task_cache.deallocate(task);

    try Task.internal.init(task, .{
        .name = options.name,
        .type = .kernel,
        .entry = options.entry,
    });

    globals.kernel_tasks_lock.writeLock();
    defer globals.kernel_tasks_lock.writeUnlock();

    const gop = try globals.kernel_tasks.getOrPut(innigkeit.mem.heap.allocator, task);
    if (gop.found_existing) std.debug.panic("task already in kernel tasks list!", .{});

    return task;
}

pub fn format(
    task: *const Task,
    writer: *std.Io.Writer,
) !void {
    switch (task.type) {
        .kernel => try writer.print(
            "K<{s}>",
            .{task.name.constSlice()},
        ),
        .user => return innigkeit.user.Thread.fromConst(task).format(writer),
    }
}

pub inline fn fromNode(node: *std.SinglyLinkedList.Node) *Task {
    return @fieldParentPtr("next_task_node", node);
}

pub const Name = core.containers.BoundedArray(u8, innigkeit.config.task.task_name_length);
