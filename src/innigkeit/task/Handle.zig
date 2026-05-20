const Handle = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const SchedClass = @import("SchedClass.zig");
const log = innigkeit.debug.log.scoped(.scheduler);

scheduler: *innigkeit.Task.Scheduler,

/// Returns a handle to the scheduler.
///
/// The scheduler is locked by this function, it is the caller's responsibility to call `Handle.unlock` when the handle is no longer
/// needed.
pub fn get() Handle {
    const current_task: innigkeit.Task.Current = .get();
    if (core.is_debug) std.debug.assert(!current_task.task.scheduler_locked);

    current_task.incrementMigrationDisable();
    defer current_task.decrementMigrationDisable();

    const scheduler = &current_task.knownExecutor().scheduler;
    scheduler.lock();
    return .{ .scheduler = scheduler };
}

pub const MaybeLocked = struct {
    was_locked: bool,
    scheduler_handle: Handle,

    /// Returns a handle to the scheduler.
    ///
    /// Supports the scheduler already being locked. The scheduler will be locked when this function returns.
    ///
    /// It is the caller's responsibility to call `MaybeLocked.unlock` when
    pub fn get() MaybeLocked {
        const current_task: innigkeit.Task.Current = .get();
        current_task.incrementMigrationDisable();
        defer current_task.decrementMigrationDisable();

        const scheduler = &current_task.knownExecutor().scheduler;
        const scheduler_already_locked = current_task.task.scheduler_locked;

        switch (scheduler_already_locked) {
            true => if (core.is_debug) scheduler.assertLocked(),
            false => scheduler.lock(),
        }

        return .{
            .was_locked = scheduler_already_locked,
            .scheduler_handle = .{ .scheduler = scheduler },
        };
    }

    pub fn unlock(self: MaybeLocked) void {
        if (!self.was_locked) self.scheduler_handle.unlock();
    }
};

pub fn unlock(self: Handle) void {
    self.scheduler.unlock();
}

/// Enqueue a task onto this executor's scheduler.
/// Pass flags.initial=true for first-ever enqueue (fork/spawn).
/// Pass flags.wakeup=true when waking from blocked.
pub fn queueTask(self: Handle, task: *innigkeit.Task, flags: SchedClass.EnqueueFlags) void {
    if (core.is_debug) {
        std.debug.assert(!task.is_scheduler_task); // cannot queue a scheduler task
        self.scheduler.assertLocked();
        std.debug.assert(task.state == .ready);
    }

    self.scheduler.queueTask(task, flags);
}

pub fn isEmpty(self: Handle) bool {
    if (core.is_debug) self.scheduler.assertLocked();
    return self.scheduler.isEmpty();
}

/// Yields the current task.
///
/// For non-idle tasks: calls putPrev (updates vruntime, re-enqueues) then picks next.
/// If no better task exists, keeps running the current task.
pub fn yield(self: Handle) void {
    const current_task: innigkeit.Task.Current = .get();
    const old_task = current_task.task;

    if (core.is_debug) {
        self.scheduler.assertLocked();
        std.debug.assert(old_task.spinlocks_held == 1); // only the scheduler lock is held
    }

    if (!old_task.is_scheduler_task) {
        if (core.is_debug) std.debug.assert(old_task.state == .running);

        // Transition to ready so putPrev knows to re-enqueue.
        old_task.state = .ready;
        self.scheduler.putPrevTask(old_task);
    }

    const new_task = self.scheduler.getNextTask() orelse {
        // Nothing queued. If we're a real task that just put itself in the queue,
        // it will be picked immediately below on a future wakeup. For now just
        // keep running.
        if (!old_task.is_scheduler_task) {
            // putPrev re-enqueued us undo the state change so the task stays
            // consistent (it will be selected by pickNext above on re-entry).
            old_task.state = .{ .running = old_task.known_executor.? };
        }
        return;
    };

    // Finalize the picked task (remove from tree, set exec_start, etc.).
    self.scheduler.setNextRunning(new_task);

    if (old_task.is_scheduler_task) {
        log.verbose("switching from idle to {f}", .{new_task});
        switchToTaskFromIdleYield(old_task, new_task);
        unreachable;
    }

    if (new_task == old_task) {
        // EEVDF decided to keep running the current task.
        old_task.state = .{ .running = old_task.known_executor.? };
        return;
    }

    log.verbose("switching from {f} to {f}", .{ old_task, new_task });
    switchToTaskFromTaskYield(self, old_task, new_task);
}

/// Terminates the current tasks execution, the task is left in an invalid state and must not be scheduled again.
///
/// Decrements the reference count of the task to remove the implicit self reference.
pub fn terminate(self: Handle) noreturn {
    self.dropWithDeferredAction(
        .{
            .action = struct {
                fn action(old_task: *innigkeit.Task, _: usize) void {
                    old_task.state = .{ .terminated = .{} };
                    old_task.decrementReferenceCount();
                }
            }.action,
            .arg = undefined,
        },
        .no,
    );
    @panic("terminated task returned!");
}

pub const DeferredAction = struct {
    /// The action to perform after the current task has been switched away from.
    ///
    /// This action will be called while executing as the scheduler task with the scheduler lock held which must not be
    /// unlocked by the action.
    ///
    /// It is the responsibility of the action to set the state of the old task to the correct value.
    action: Action,

    arg: usize,

    pub const Action = *const fn (
        old_task: *innigkeit.Task,
        arg: usize,
    ) void;
};

/// Blocks the current task.
///
/// The provided `DeferredAction` will be executed after the task has been switched away from.
///
/// It is the callers responsibility to ensure the task can be unblocked when necessary and to set the task's state to `.blocked` in the
/// provided `DeferredAction`.
///
/// A new scheduler handle will be returned, this must be unlocked by the caller instead of the scheduler handle that was passed in.
pub fn block(self: Handle, deferred_action: DeferredAction) Handle {
    self.dropWithDeferredAction(deferred_action, .yes);
    // we return a new scheduler handle here as the task may be on a different executor now
    return .{ .scheduler = &innigkeit.Task.Current.get().knownExecutor().scheduler };
}

const TaskResume = enum { yes, no };

fn dropWithDeferredAction( // used to implement both `block` and `terminate`
    self: Handle,
    deferred_action: DeferredAction,
    task_resume: TaskResume,
) void {
    const old_task = innigkeit.Task.Current.get().task;

    if (core.is_debug) {
        std.debug.assert(!old_task.is_scheduler_task); // scheduler task cannot be dropped
        self.scheduler.assertLocked();
        std.debug.assert(old_task.state == .running);
    }

    // Update vruntime accounting without re-enqueueing (state is .running, not .ready).
    // The deferred action will set the final state (.blocked or .terminated).
    self.scheduler.putPrevTask(old_task);

    const new_task = self.scheduler.getNextTask() orelse {
        log.verbose("switching from {f} to idle with a deferred action", .{old_task});
        switchToIdleDeferredAction(old_task, deferred_action, task_resume);
        return;
    };

    self.scheduler.setNextRunning(new_task);

    if (core.is_debug) {
        std.debug.assert(!new_task.is_scheduler_task);
        std.debug.assert(old_task != new_task);
        std.debug.assert(new_task.scheduler_locked);
        std.debug.assert(new_task.spinlocks_held == 1); // only the scheduler lock is held
        std.debug.assert(new_task.state == .ready);
    }

    log.verbose("switching from {f} to {f} with a deferred action", .{ old_task, new_task });

    switchToTaskFromTaskDeferredAction(old_task, new_task, deferred_action, task_resume);
}

fn switchToIdleDeferredAction(
    old_task: *innigkeit.Task,
    deferred_action: DeferredAction,
    task_resume: TaskResume,
) void {
    const static = struct {
        fn idleEntryDeferredAction(
            inner_old_task: *innigkeit.Task,
            action: DeferredAction.Action,
            action_arg: usize,
        ) noreturn {
            action(inner_old_task, action_arg);
            if (core.is_debug) {
                const scheduler_task = innigkeit.Task.Current.get().task;
                std.debug.assert(scheduler_task.is_scheduler_task);
                std.debug.assert(scheduler_task.interrupt_disable_count.load(.acquire) == 1);
                std.debug.assert(scheduler_task.spinlocks_held == 1);
            }
            idle();
            unreachable;
        }
    };

    const executor = old_task.known_executor.?;
    const scheduler_task = &executor.scheduler.task;
    if (core.is_debug) std.debug.assert(scheduler_task.state == .ready);

    beforeSwitchTask(old_task, scheduler_task);

    scheduler_task.state = .{ .running = executor };
    if (core.is_debug) std.debug.assert(scheduler_task.known_executor == executor);
    executor.setCurrentTask(scheduler_task);

    const type_erased_call: core.TypeErasedCall = .prepare(
        static.idleEntryDeferredAction,
        .{
            old_task,
            deferred_action.action,
            deferred_action.arg,
        },
    );

    switch (task_resume) {
        .no => {
            architecture.scheduling.callNoSave(&scheduler_task.stack, type_erased_call);
            unreachable;
        },
        .yes => {
            architecture.scheduling.call(old_task, &scheduler_task.stack, type_erased_call);
            if (core.is_debug) std.debug.assert(old_task.known_executor == old_task.state.running);
            // returning to the old task
        },
    }
}

fn switchToTaskFromIdleYield(scheduler_task: *innigkeit.Task, new_task: *innigkeit.Task) void {
    const executor = scheduler_task.known_executor.?;
    if (core.is_debug) std.debug.assert(&executor.scheduler.task == scheduler_task);

    beforeSwitchTask(scheduler_task, new_task);

    new_task.state = .{ .running = executor };
    new_task.known_executor = executor;
    executor.setCurrentTask(new_task);

    scheduler_task.state = .ready;

    if (core.is_debug) std.debug.assert(
        switch (scheduler_task.interrupt_disable_count.load(.acquire)) {
            1, 2 => true, // either we are here due to an explicit yield (1) or due to preemption by an interrupt (2)
            else => false,
        },
    );

    // we are abandoning the current scheduler tasks call stack, which means the interrupt increment that would have
    // happened if we are here due to preemption by an interrupt will not be decremented normally, so we set it to 1
    // which is the value it is expected to have upon entry to idle
    scheduler_task.interrupt_disable_count.store(1, .release);

    architecture.scheduling.switchTaskNoSave(new_task);
    unreachable;
}

fn switchToTaskFromTaskYield(
    scheduler_handle: Handle,
    old_task: *innigkeit.Task,
    new_task: *innigkeit.Task,
) void {
    _ = scheduler_handle; // putPrev already re-enqueued old_task; no queueTask needed

    const executor = old_task.known_executor.?;

    beforeSwitchTask(old_task, new_task);

    new_task.state = .{ .running = executor };
    new_task.known_executor = executor;
    executor.setCurrentTask(new_task);

    // old_task.state is already .ready (set in yield() before putPrev).

    architecture.scheduling.switchTask(old_task, new_task);

    // returning to the old task
    if (core.is_debug) std.debug.assert(old_task.known_executor == old_task.state.running);
}

fn switchToTaskFromTaskDeferredAction(
    old_task: *innigkeit.Task,
    new_task: *innigkeit.Task,
    deferred_action: DeferredAction,
    task_resume: TaskResume,
) void {
    const static = struct {
        fn switchToTaskDeferredAction(
            inner_old_task: *innigkeit.Task,
            inner_new_task: *innigkeit.Task,
            action: DeferredAction.Action,
            action_arg: usize,
        ) noreturn {
            const scheduler_task = innigkeit.Task.Current.get().task;
            if (core.is_debug) std.debug.assert(scheduler_task.is_scheduler_task);
            const executor = scheduler_task.known_executor.?;

            action(inner_old_task, action_arg);
            if (core.is_debug) {
                std.debug.assert(innigkeit.Task.Current.get().task == scheduler_task);
                std.debug.assert(scheduler_task.interrupt_disable_count.load(.acquire) == 1);
                std.debug.assert(scheduler_task.spinlocks_held == 1);
            }

            inner_new_task.state = .{ .running = executor };
            inner_new_task.known_executor = executor;
            executor.setCurrentTask(inner_new_task);

            scheduler_task.state = .ready;

            architecture.scheduling.switchTaskNoSave(inner_new_task);
            unreachable;
        }
    };

    const executor = old_task.known_executor.?;

    beforeSwitchTask(old_task, new_task);

    const scheduler_task = &executor.scheduler.task;

    scheduler_task.state = .{ .running = executor };
    if (core.is_debug) std.debug.assert(scheduler_task.known_executor == executor);
    executor.setCurrentTask(scheduler_task);

    const type_erased_call: core.TypeErasedCall = .prepare(
        static.switchToTaskDeferredAction,
        .{
            old_task,
            new_task,
            deferred_action.action,
            deferred_action.arg,
        },
    );

    switch (task_resume) {
        .no => {
            architecture.scheduling.callNoSave(&scheduler_task.stack, type_erased_call);
            unreachable;
        },
        .yes => {
            architecture.scheduling.call(old_task, &scheduler_task.stack, type_erased_call);
            if (core.is_debug) std.debug.assert(old_task.known_executor == old_task.state.running);
            // returning to the old task
        },
    }
}

fn beforeSwitchTask(
    old_task: *innigkeit.Task,
    new_task: *innigkeit.Task,
) void {
    const transition: innigkeit.Task.Transition = .from(old_task, new_task);

    const old_task_enable_access_to_user_memory_count = transition.old_task.enable_access_to_user_memory_count.load(.acquire);
    const new_task_enable_access_to_user_memory_count = transition.new_task.enable_access_to_user_memory_count.load(.acquire);

    switch (transition.type) {
        .kernel_to_kernel => {
            if (core.is_debug) {
                std.debug.assert(old_task_enable_access_to_user_memory_count == 0);
                std.debug.assert(new_task_enable_access_to_user_memory_count == 0);
            }
        },
        .kernel_to_user => {
            if (core.is_debug) std.debug.assert(old_task_enable_access_to_user_memory_count == 0);

            const new_process: *innigkeit.user.Process = .from(transition.new_task);
            new_process.address_space.page_table.load();

            if (new_task_enable_access_to_user_memory_count != 0) {
                @branchHint(.unlikely); // we expect this to be 0 most of the time
                architecture.paging.enableAccessToUserMemory();
            }
        },
        .user_to_kernel => {
            if (core.is_debug) std.debug.assert(new_task_enable_access_to_user_memory_count == 0);

            innigkeit.mem.kernelPageTable().load();

            if (old_task_enable_access_to_user_memory_count != 0) {
                @branchHint(.unlikely); // we expect this to be 0 most of the time
                architecture.paging.disableAccessToUserMemory();
            }
        },
        .user_to_user => {
            const old_process: *const innigkeit.user.Process = .from(transition.old_task);
            const new_process: *innigkeit.user.Process = .from(transition.new_task);
            if (old_process != new_process) new_process.address_space.page_table.load();

            if (old_task_enable_access_to_user_memory_count !=
                new_task_enable_access_to_user_memory_count)
            {
                @branchHint(.unlikely); // we expect both to be 0 most of the time

                if (new_task_enable_access_to_user_memory_count == 0) {
                    architecture.paging.disableAccessToUserMemory();
                } else {
                    architecture.paging.enableAccessToUserMemory();
                }
            }
        },
    }

    architecture.scheduling.beforeSwitchTask(transition);
}

fn idle() callconv(.c) noreturn {
    const current_task: innigkeit.Task.Current = .get();

    if (core.is_debug) {
        const scheduler_task = current_task.task;
        std.debug.assert(scheduler_task.is_scheduler_task);
        std.debug.assert(scheduler_task.scheduler_locked);
        std.debug.assert(scheduler_task.interrupt_disable_count.load(.acquire) == 1);
        std.debug.assert(scheduler_task.migration_disable_count.load(.acquire) == 1);
        std.debug.assert(scheduler_task.spinlocks_held == 1);
        std.debug.assert(!architecture.interrupts.areEnabled());
    }

    current_task.knownExecutor().scheduler.unlock();

    log.debug("idle: entering idle loop", .{});

    while (true) {
        {
            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            defer scheduler_handle.unlock();

            scheduler_handle.yield();

            // If a task was queued between unlock and halt, skip the halt.
            if (!scheduler_handle.isEmpty()) continue;
        }

        architecture.halt();
    }
}
