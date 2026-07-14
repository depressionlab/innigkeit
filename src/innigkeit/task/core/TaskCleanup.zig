const TaskCleanup = @This();

const core = @import("core");
const globals = @import("globals.zig");
const innigkeit = @import("innigkeit");
const std = @import("std");

const log = innigkeit.debug.log.scoped(.task);

task: *innigkeit.Task,
parker: innigkeit.sync.Parker,
incoming: core.containers.AtomicSinglyLinkedList,

pub fn init(self: *TaskCleanup) !void {
    self.* = .{
        .task = try innigkeit.Task.createKernelTask(.{
            .name = try .fromSlice("task cleanup"),
            .entry = .prepare(TaskCleanup.execute, .{self}),
        }),
        .parker = undefined, // set below
        .incoming = .{},
    };

    self.parker = .withParkedTask(self.task);
}

/// Queues a task to be cleaned up by the task cleanup service.
///
/// This must **not** be called when the task is the current task.
pub fn queueTaskForCleanup(self: *TaskCleanup, task: *innigkeit.Task) void {
    if (core.is_debug) {
        std.debug.assert(task != innigkeit.Task.Current.get().task);
        std.debug.assert(task.state == .terminated);
    }

    if (task.state.terminated.queued_for_cleanup.cmpxchgStrong(
        false,
        true,
        .acq_rel,
        .acquire,
    ) != null) {
        @panic("already queued for cleanup!");
    }

    log.verbose("queueing {f} for cleanup", .{task});

    self.incoming.prepend(&task.next_task_node);
    self.parker.unpark();
}

fn execute(self: *TaskCleanup) noreturn {
    while (true) {
        while (self.incoming.popFirst()) |node| {
            cleanupTask(.fromNode(node));
        }

        self.parker.park();
    }
}

fn cleanupTask(task: *innigkeit.Task) void {
    if (core.is_debug) {
        std.debug.assert(task.state == .terminated);
        std.debug.assert(task.state.terminated.queued_for_cleanup.load(.monotonic));
    }

    task.state.terminated.queued_for_cleanup.store(false, .release);
    // Remove from the nanosleep queue before freeing; prevents UAF in tick()
    // if the task was force-terminated while sleeping.
    innigkeit.sync.nanosleep.cancel(task);
    // Remove from any futex bucket before freeing; prevents UAF in tick()
    // if the task was force-terminated while in a timed futex wait.
    innigkeit.sync.futex.cancel(task);

    switch (task.type) {
        .kernel => {
            {
                globals.kernel_tasks_lock.writeLock();
                defer globals.kernel_tasks_lock.writeUnlock();

                if (task.reference_count.load(.acquire) != 0) {
                    @branchHint(.unlikely);
                    // someone has acquired a reference to the task after it was queued for cleanup
                    log.verbose("{f} still has references", .{task});
                    return;
                }

                if (task.state.terminated.queued_for_cleanup.load(.acquire)) {
                    @branchHint(.unlikely);
                    // someone has requeued this task for cleanup
                    log.verbose("{f} has been requeued for cleanup", .{task});
                    return;
                }

                // the task is no longer referenced so we can safely destroy it
                if (!globals.kernel_tasks.swapRemove(task))
                    @panic("task not found in kernel tasks!");
            }

            log.debug("destroying {f}", .{task});

            globals.kernel_task_cache.deallocate(task);
        },
        .user => {
            const thread: *innigkeit.user.Thread = .from(task);

            {
                thread.process.threads_lock.writeLock();
                defer thread.process.threads_lock.writeUnlock();

                if (task.reference_count.load(.acquire) != 0) {
                    @branchHint(.unlikely);
                    // someone has acquired a reference to the task after it was queued for cleanup
                    log.verbose("{f} still has references", .{task});
                    return;
                }

                if (task.state.terminated.queued_for_cleanup.load(.acquire)) {
                    @branchHint(.unlikely);
                    // someone has requeued this task for cleanup
                    log.verbose("{f} has been requeued for cleanup", .{task});
                    return;
                }

                // the task is no longer referenced so we can safely destroy it
                if (!thread.process.threads.swapRemove(thread)) @panic("thread not found in process threads!");
            }

            innigkeit.debug.log.scoped(.user_thread).debug("destroying {f}", .{thread});

            thread.process.decrementReferenceCount();
            innigkeit.user.Thread.internal.destroy(thread);
        },
    }
}
