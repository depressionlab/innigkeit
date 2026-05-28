//! Kernel sleep queue: blocks userspace tasks until a uptime_ms deadline passes.
//!
//! The per-executor periodic tick wakes any tasks whose deadline_ms <= now.
const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");

var sleep_lock: innigkeit.sync.TicketSpinLock = .{};
var sleep_queue: innigkeit.sync.WaitQueue = .{};

/// Block the calling task until `uptime_ms >= deadline_ms`.
/// Returns immediately if the deadline has already passed.
pub fn wait(deadline_ms: u64) void {
    sleep_lock.lock();

    if (innigkeit.time.init.getUptimeMs() >= deadline_ms) {
        sleep_lock.unlock();
        return;
    }

    const current_task: innigkeit.Task.Current = .get();
    current_task.task.sleep_deadline_ms = deadline_ms;
    sleep_queue.wait(&sleep_lock);
    current_task.task.sleep_deadline_ms = 0;
}

/// Called from the per-executor periodic interrupt handler.
/// Wakes all tasks whose `sleep_deadline_ms <= uptime_ms`.
pub fn tick() void {
    sleep_lock.lock();

    const now_ms = innigkeit.time.init.getUptimeMs();

    var still_sleeping: core.containers.FIFO = .{};
    while (sleep_queue.waiting_tasks.pop()) |node| {
        const task: *innigkeit.Task = .fromNode(node);
        if (task.sleep_deadline_ms <= now_ms) {
            task.sleep_deadline_ms = 0;
            task.wakeFromBlocked();
        } else {
            still_sleeping.append(node);
        }
    }
    sleep_queue.waiting_tasks = still_sleeping;

    sleep_lock.unlock();
}
