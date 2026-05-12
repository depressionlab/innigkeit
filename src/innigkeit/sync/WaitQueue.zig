const WaitQueue = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");

waiting_tasks: core.containers.FIFO = .{},

/// Access the first task in the wait queue.
///
/// Does not remove the task from the wait queue.
///
/// Not thread-safe.
pub fn firstTask(self: *WaitQueue) ?*innigkeit.Task {
    const node = self.waiting_tasks.first_node orelse return null;
    return .fromNode(node);
}

/// Removes the first task from the wait queue.
///
/// Not thread-safe.
pub fn popFirst(self: *WaitQueue) ?*innigkeit.Task {
    const node = self.waiting_tasks.pop() orelse return null;
    return .fromNode(node);
}

/// Wake one task from the wait queue.
///
/// Asserts that the spinlock is locked by the current executor and interrupts are disabled.
pub fn wakeOne(self: *WaitQueue, spinlock: *const innigkeit.sync.TicketSpinLock) void {
    if (core.is_debug) {
        std.debug.assert(innigkeit.Task.Current.get().task.interrupt_disable_count.load(.acquire) != 0);
        std.debug.assert(spinlock.isLockedByCurrent());
    }

    const task_to_wake_node = self.waiting_tasks.pop() orelse return;
    const task_to_wake: *innigkeit.Task = .fromNode(task_to_wake_node);

    task_to_wake.wakeFromBlocked();
}

/// Add the current task to the wait queue.
///
/// The spinlock will be unlocked upon return.
///
/// Asserts that the spinlock is locked by the current executor and interrupts are disabled.
pub fn wait(self: *WaitQueue, spinlock: *innigkeit.sync.TicketSpinLock) void {
    const current_task: innigkeit.Task.Current = .get();

    if (core.is_debug) {
        std.debug.assert(current_task.task.interrupt_disable_count.load(.acquire) != 0);
        std.debug.assert(spinlock.isLockedByCurrent());
    }

    self.waiting_tasks.append(&current_task.task.next_task_node);

    var scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();

    scheduler_handle = scheduler_handle.block(
        .{
            .action = struct {
                fn action(old_task: *innigkeit.Task, arg: usize) void {
                    const inner_spinlock: *innigkeit.sync.TicketSpinLock = @ptrFromInt(arg);

                    old_task.state = .blocked;
                    old_task.spinlocks_held -= 1;
                    _ = old_task.interrupt_disable_count.fetchSub(1, .acq_rel);

                    inner_spinlock.unsafeUnlock();
                }
            }.action,
            .arg = @intFromPtr(spinlock),
        },
    );
}
