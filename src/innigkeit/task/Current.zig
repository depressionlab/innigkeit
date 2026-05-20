const Current = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const wallclock = innigkeit.time.wallclock;
const log = innigkeit.debug.log.scoped(.task);

task: *innigkeit.Task,

/// Returns the executor that the current task is running on if it is known.
///
/// Asserts that the `known_executor` field is non-null.
pub inline fn knownExecutor(self: Current) *innigkeit.Executor {
    return self.task.known_executor.?;
}

pub inline fn get() Current {
    return .{ .task = architecture.scheduling.getCurrentTask() };
}

pub fn incrementInterruptDisable(self: Current) void {
    architecture.interrupts.disable();

    const previous = self.task.interrupt_disable_count.fetchAdd(1, .acq_rel);
    if (core.is_debug) std.debug.assert(previous < std.math.maxInt(u32));

    // Only update known_executor from state when the task is running.
    // If the task is transitioning (e.g. state == .ready inside yield()), known_executor
    // was already pinned by a prior incrementInterruptDisable call; leave it as-is.
    if (self.task.state == .running) {
        self.task.known_executor = self.task.state.running;
    }
}

pub fn decrementInterruptDisable(self: Current) void {
    if (core.is_debug) std.debug.assert(!architecture.interrupts.areEnabled());

    const previous = self.task.interrupt_disable_count.fetchSub(1, .acq_rel);
    if (core.is_debug) std.debug.assert(previous > 0);

    if (previous == 1) {
        self.setKnownExecutor();
        architecture.interrupts.enable();

        // Deferred preemption: if a timer interrupt set needs_resched while we were
        // in an interrupt-disabled critical section, honour it now that we're back on
        // the task stack with no spinlocks held and no nesting.
        if (self.task.needs_resched and
            self.task.spinlocks_held == 0 and
            !self.task.is_scheduler_task and
            self.task.state == .running)
        {
            self.maybePreempt();
        }
    }
}

pub fn incrementMigrationDisable(self: Current) void {
    const previous = self.task.migration_disable_count.fetchAdd(1, .acq_rel);
    if (core.is_debug) std.debug.assert(previous < std.math.maxInt(u32));

    if (self.task.state == .running) {
        self.task.known_executor = self.task.state.running;
    }
}

pub fn decrementMigrationDisable(self: Current) void {
    const previous = self.task.migration_disable_count.fetchSub(1, .acq_rel);
    if (core.is_debug) std.debug.assert(previous > 0);

    if (previous == 1) self.setKnownExecutor();
}

pub fn incrementEnableAccessToUserMemory(self: Current) void {
    if (core.is_debug) std.debug.assert(self.task.type == .user);

    const previous = self.task.enable_access_to_user_memory_count.fetchAdd(1, .acq_rel);
    if (core.is_debug) std.debug.assert(previous < std.math.maxInt(u32));

    if (previous == 0) architecture.paging.enableAccessToUserMemory();
}

pub fn decrementEnableAccessToUserMemory(self: Current) void {
    if (core.is_debug) std.debug.assert(self.task.type == .user);

    const previous = self.task.enable_access_to_user_memory_count.fetchSub(1, .acq_rel);
    if (core.is_debug) std.debug.assert(previous > 0);

    if (previous == 1) architecture.paging.disableAccessToUserMemory();
}

/// Tick the scheduler and set needs_resched if preemption is warranted.
///
/// Safe to call from interrupt context (IRQ stack): does NOT switch tasks.
/// Actual preemption is deferred to the next decrementInterruptDisable(1→0).
pub fn tickAndRequestPreemptIfNeeded(self: Current) void {
    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();

    const now = wallclock.read();
    if (self.task.needs_resched or scheduler_handle.scheduler.tick(self.task, now)) {
        self.task.needs_resched = true;
    }
}

/// Maybe preempt the current task.
///
/// Asks the active scheduling class whether preemption is warranted (via tick).
/// Also honours the needs_resched flag set asynchronously by the scheduler.
///
/// The scheduler lock must *not* be held.
pub fn maybePreempt(self: Current) void {
    if (core.is_debug) {
        std.debug.assert(self.task.spinlocks_held == 0);
        std.debug.assert(self.task.state == .running);
    }

    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();

    const now = wallclock.read();

    // Tick advances vruntime accounting and decides whether to preempt.
    // needs_resched is a fast-path flag set by the scheduler class asynchronously.
    const should_preempt = self.task.needs_resched or
        scheduler_handle.scheduler.tick(self.task, now);
    self.task.needs_resched = false;

    if (!should_preempt) return;

    log.verbose("preempting {f}", .{self});
    scheduler_handle.yield();
}

pub fn onInterruptEntry() StateBeforeInterrupt {
    if (core.is_debug) std.debug.assert(!architecture.interrupts.areEnabled());

    const task = architecture.scheduling.getCurrentTask();

    const before_interrupt_interrupt_disable_count = task.interrupt_disable_count.fetchAdd(1, .acq_rel);

    const before_interrupt_enable_access_to_user_memory_count = task.enable_access_to_user_memory_count.swap(0, .acq_rel);

    if (before_interrupt_enable_access_to_user_memory_count != 0) {
        @branchHint(.unlikely);
        architecture.paging.disableAccessToUserMemory();
    }

    task.known_executor = task.state.running;

    return .{
        .interrupt_disable_count = before_interrupt_interrupt_disable_count,
        .enable_access_to_user_memory_count = before_interrupt_enable_access_to_user_memory_count,
    };
}

/// Tracks the state of the task before an interrupt was triggered.
///
/// Stored separately from the task to allow nested interrupts.
pub const StateBeforeInterrupt = struct {
    interrupt_disable_count: u32,
    enable_access_to_user_memory_count: u32,

    pub fn onInterruptExit(self: StateBeforeInterrupt) void {
        const current_task: Current = .get();

        current_task.task.interrupt_disable_count.store(self.interrupt_disable_count, .release);

        const before_interrupt_enable_access_to_user_memory_count = self.enable_access_to_user_memory_count;
        const current_enable_access_to_user_memory_count = current_task.task.enable_access_to_user_memory_count.swap(
            before_interrupt_enable_access_to_user_memory_count,
            .release,
        );

        if (current_enable_access_to_user_memory_count != before_interrupt_enable_access_to_user_memory_count) {
            @branchHint(.unlikely);

            if (before_interrupt_enable_access_to_user_memory_count == 0) {
                architecture.paging.disableAccessToUserMemory();
            } else {
                architecture.paging.enableAccessToUserMemory();
            }
        }

        current_task.setKnownExecutor();
    }
};

/// Called when panicking to fetch the current task.
///
/// Interrupts must already be disabled when this function is called.
pub fn panicked() Current {
    std.debug.assert(!architecture.interrupts.areEnabled());

    const task = architecture.scheduling.getCurrentTask();

    _ = task.interrupt_disable_count.fetchAdd(1, .acq_rel);
    task.known_executor = task.state.running;

    return .{ .task = task };
}

pub inline fn format(self: Current, writer: *std.Io.Writer) !void {
    return self.task.format(writer);
}

/// Set the `known_executor` field of the task based on the state of the task.
fn setKnownExecutor(self: Current) void {
    if (self.task.interrupt_disable_count.load(.acquire) != 0 or
        self.task.migration_disable_count.load(.acquire) != 0)
    {
        if (self.task.state == .running) {
            self.task.known_executor = self.task.state.running;
        }
        // If not running, known_executor was already pinned; leave it as-is.
        return;
    }

    self.task.known_executor = null;
}
