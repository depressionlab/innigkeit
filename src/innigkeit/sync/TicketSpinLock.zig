//! A fair in order spinlock.
//!
//! Recursive locks are not supported.
//!
//! Interrupts are disabled while locked.
const TicketSpinLock = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

container: Container align(std.atomic.cache_line) = .{ .full = 0 },
holding_executor: ?*const innigkeit.Executor = null,

pub fn lock(self: *TicketSpinLock) void {
    const current_task: innigkeit.Task.Current = .get();

    current_task.incrementInterruptDisable();

    if (core.is_debug) std.debug.assert(!self.isLockedByCurrent()); // recursive locks are not supported

    const ticket = @atomicRmw(u32, &self.container.contents.ticket, .Add, 1, .monotonic);

    if (@atomicLoad(u32, &self.container.contents.current, .acquire) != ticket) {
        while (true) {
            architecture.spinLoopHint();
            if (@atomicLoad(u32, &self.container.contents.current, .monotonic) == ticket) break;
        }

        _ = @atomicLoad(u32, &self.container.contents.current, .acquire);
    }

    self.holding_executor = current_task.knownExecutor();
    current_task.task.spinlocks_held += 1;
}

pub fn tryLock(self: *TicketSpinLock) bool {
    // no need to check if we already have the lock as the below logic will not allow us
    // to acquire it again

    const current_task: innigkeit.Task.Current = .get();

    current_task.incrementInterruptDisable();

    const old_container: Container = @bitCast(@atomicLoad(u64, &self.container.full, .monotonic));

    if (old_container.contents.current != old_container.contents.ticket) {
        current_task.decrementInterruptDisable();
        return false;
    }

    var new_container = old_container;
    new_container.contents.ticket +%= 1;

    if (@cmpxchgStrong(
        u64,
        &self.container.full,
        old_container.full,
        new_container.full,
        .acquire,
        .monotonic,
    )) |_| {
        current_task.decrementInterruptDisable();
        return false;
    }

    self.holding_executor = current_task.knownExecutor();
    current_task.task.spinlocks_held += 1;

    return true;
}

/// Unlock the spinlock.
///
/// Asserts that the current executor is the one that locked the spinlock.
pub fn unlock(self: *TicketSpinLock) void {
    const current_task: innigkeit.Task.Current = .get();

    if (core.is_debug) {
        std.debug.assert(current_task.task.spinlocks_held != 0);
        std.debug.assert(self.isLockedByCurrent());
    }

    self.unsafeUnlock();

    current_task.task.spinlocks_held -= 1;
    current_task.decrementInterruptDisable();
}

/// Unlocks the spinlock, without decrementing interrupt disable count or spinlock held count.
///
/// Performs no checks, prefer `unlock` instead.
pub inline fn unsafeUnlock(self: *TicketSpinLock) void {
    self.holding_executor = null;
    _ = @atomicRmw(u32, &self.container.contents.current, .Add, 1, .release);
}

/// Poison the spinlock, this will cause any future attempts to lock the spinlock to deadlock.
pub fn poison(self: *TicketSpinLock) void {
    _ = @atomicRmw(u32, &self.container.contents.current, .Sub, 1, .release);
}

/// Returns true if the spinlock is locked by the current executor.
pub fn isLockedByCurrent(self: *const TicketSpinLock) bool {
    const executor = innigkeit.Task.Current.get().task.known_executor orelse return false;
    return self.holding_executor == executor;
}

test "TicketSpinLock: tryLock fails while held; isLockedByCurrent tracks holder" {
    var spinlock: TicketSpinLock = .{};
    try std.testing.expect(!spinlock.isLockedByCurrent());

    spinlock.lock();
    try std.testing.expect(spinlock.isLockedByCurrent());
    // The lock is held: a tryLock (even from the holder) must fail without
    // perturbing the interrupt-disable bookkeeping.
    try std.testing.expect(!spinlock.tryLock());
    try std.testing.expect(spinlock.isLockedByCurrent());
    spinlock.unlock();
    try std.testing.expect(!spinlock.isLockedByCurrent());

    // tryLock on a free lock succeeds and pairs with unlock.
    try std.testing.expect(spinlock.tryLock());
    try std.testing.expect(spinlock.isLockedByCurrent());
    spinlock.unlock();
    try std.testing.expect(!spinlock.isLockedByCurrent());
}

const Container = extern union {
    contents: extern struct {
        current: u32 = 0,
        ticket: u32 = 0,
    },
    full: u64,

    comptime {
        std.debug.assert(@sizeOf(Container) == @sizeOf(u64));
    }
};
