//! Kernel futex subsystem: fast userspace mutexes.
//!
//! 256 hash buckets, each with a TicketSpinLock and a WaitQueue.
//! Tasks store the futex virtual address in task.futex_addr so that
//! wake() can selectively wake only tasks waiting on a specific address
//! even when multiple addresses hash to the same bucket.

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const validate = innigkeit.user.validate;

const num_buckets = 256;

const Bucket = struct {
    lock: innigkeit.sync.TicketSpinLock = .{},
    queue: innigkeit.sync.WaitQueue = .{},
};

var buckets: [num_buckets]Bucket = [_]Bucket{.{}} ** num_buckets;

fn bucketOf(addr: usize) *Bucket {
    return &buckets[((addr >> 2) *% 2654435761) % num_buckets];
}

/// Block the calling task until futex_wake is called on `addr`.
///
/// Reads `*(atomic u32*)addr` while the bucket lock is held so there is
/// no race between checking and enqueuing. If the word no longer equals
/// `expected`, returns immediately (retry signal to caller).
/// Caller must have validated that [addr, addr+4) lies inside user space.
pub fn wait(addr: usize, expected: u32) void {
    if (!validate.validateUserBuffer(addr, @sizeOf(u32))) return;
    const bucket = bucketOf(addr);
    bucket.lock.lock();

    const current_task: innigkeit.Task.Current = .get();
    // Fault-safe atomic load under the bucket lock: a bad/unmapped futex word
    // returns an error (a no-op; the caller retries) instead of panicking the
    // kernel. The load is atomic (lost-wakeup correctness) and the lock guards
    // the check-then-enqueue against a concurrent wake.
    const current_val = innigkeit.mem.safe.atomicLoadU32(.from(addr)) catch {
        bucket.lock.unlock();
        return;
    };

    if (current_val != expected) {
        bucket.lock.unlock();
        return;
    }

    current_task.task.futex_addr = addr;
    current_task.task.block_reason = .futex;
    // WaitQueue.wait() appends the task and atomically blocks + unlocks bucket.lock.
    bucket.queue.wait(&bucket.lock);
    // On return, bucket.lock is already unlocked.
    current_task.task.futex_addr = 0;
}

/// Block the calling task until futex_wake is called on `addr` or `deadline_ms` passes.
///
/// Same as wait() but with a millisecond deadline. Sets futex_timeout_ms and block_reason.
/// Caller must have validated that [addr, addr+4) lies inside user space.
pub fn waitTimeout(addr: usize, expected: u32, deadline_ms: u64) void {
    if (!validate.validateUserBuffer(addr, @sizeOf(u32))) return;
    const bucket = bucketOf(addr);
    bucket.lock.lock();

    const current_task: innigkeit.Task.Current = .get();
    // Fault-safe atomic load under the bucket lock (see `wait`).
    const current_val = innigkeit.mem.safe.atomicLoadU32(.from(addr)) catch {
        bucket.lock.unlock();
        return;
    };

    if (current_val != expected) {
        bucket.lock.unlock();
        return;
    }

    current_task.task.futex_addr = addr;
    current_task.task.futex_timeout_ms = deadline_ms;
    current_task.task.block_reason = .futex_timeout;
    // WaitQueue.wait() appends the task and atomically blocks + unlocks bucket.lock.
    bucket.queue.wait(&bucket.lock);
    // On return, bucket.lock is already unlocked.
    current_task.task.futex_addr = 0;
    current_task.task.futex_timeout_ms = 0;
}

/// Called from the periodic interrupt handler.
/// Wakes tasks whose futex_timeout_ms deadline has passed.
pub fn tick() void {
    const now_ms = innigkeit.time.init.getUptimeMs();
    for (&buckets) |*bucket| {
        bucket.lock.lock();
        var unmatched: core.containers.FIFO = .{};
        while (bucket.queue.popFirst()) |task| {
            if (task.futex_timeout_ms != 0 and task.futex_timeout_ms <= now_ms) {
                task.futex_timeout_ms = 0;
                task.futex_addr = 0;
                task.block_reason = .other;
                task.wakeFromBlocked();
            } else {
                unmatched.append(&task.next_task_node);
            }
        }
        bucket.queue.waiting_tasks = unmatched;
        bucket.lock.unlock();
    }
}

/// Remove `task` from its futex bucket without waking it.
///
/// Must be called before freeing any task whose futex_addr is non-zero (i.e. one
/// that may be blocked in a futex bucket with a timeout).
/// Safe to call if the task is not in any bucket (no-op).
pub fn cancel(task: *innigkeit.Task) void {
    if (task.futex_addr == 0) return;
    const bucket = bucketOf(task.futex_addr);
    bucket.lock.lock();
    var unmatched: core.containers.FIFO = .{};
    while (bucket.queue.popFirst()) |t| {
        if (t != task) unmatched.append(&t.next_task_node);
    }
    bucket.queue.waiting_tasks = unmatched;
    bucket.lock.unlock();
    task.futex_addr = 0;
    task.futex_timeout_ms = 0;
}

/// Wake up to `max_wake` tasks blocked on `addr`.
///
/// Returns the number of tasks actually woken.
pub fn wake(addr: usize, max_wake: u32) u32 {
    if (max_wake == 0) return 0;

    const bucket = bucketOf(addr);
    bucket.lock.lock();

    var woken: u32 = 0;

    // Drain all tasks into a local FIFO, categorize, then rebuild the queue
    // with only the unmatched tasks (preserving their relative order).
    var unmatched: core.containers.FIFO = .{};

    while (bucket.queue.popFirst()) |task| {
        if (task.futex_addr == addr and woken < max_wake) {
            task.futex_addr = 0;
            task.wakeFromBlocked();
            woken += 1;
        } else {
            // node.next was cleared by popFirst; safe to re-append.
            unmatched.append(&task.next_task_node);
        }
    }

    // Restore unmatched tasks. The bucket queue is empty after the drain,
    // so we can directly assign the rebuilt list.
    bucket.queue.waiting_tasks = unmatched;

    bucket.lock.unlock();
    return woken;
}
