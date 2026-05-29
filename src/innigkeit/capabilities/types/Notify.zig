//! An async notification capability.
//!
//! A 64-bit bitmask of pending signals. Any thread with write rights can signal
//! one or more bits; any thread with read rights can wait for specific bits.
//! This is the lowest-overhead IPC primitive. Signalling never blocks.
const Notify = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");

/// Revocation generation counter. Incremented by `cap_revoke`; checked on every
/// capability lookup. All slots whose stored generation differs from this value
/// are treated as revoked and return EBADF.
generation: std.atomic.Value(u32) = .init(0),
refcount: std.atomic.Value(usize) = .init(1),
lock: innigkeit.sync.TicketSpinLock = .{},
pending: u64 = 0,
wait_queue: innigkeit.sync.WaitQueue = .{},

pub fn create() error{OutOfMemory}!*Notify {
    const self = innigkeit.mem.heap.allocator.create(Notify) catch return error.OutOfMemory;
    self.* = .{};
    return self;
}

pub fn ref(self: *Notify) void {
    _ = self.refcount.fetchAdd(1, .acq_rel);
}

pub fn unref(self: *Notify) void {
    if (self.refcount.fetchSub(1, .acq_rel) != 1) return;
    innigkeit.mem.heap.allocator.destroy(self);
}

/// Set bits in the pending mask and wake one waiter if any.
///
/// Never blocks. Safe to call from interrupt context (with interrupts disabled).
pub fn signal(self: *Notify, bits: u64) void {
    self.lock.lock();
    defer self.lock.unlock();
    self.pending |= bits;
    self.wait_queue.wakeOne(&self.lock);
}

/// Block the calling task until at least one bit in `clear_mask` is set.
///
/// Returns the bits that were set (anded with clear_mask) and clears them.
pub fn wait(self: *Notify, clear_mask: u64) u64 {
    self.lock.lock();
    while (self.pending & clear_mask == 0) {
        // wait() unlocks the spinlock as a deferred action and blocks us.
        // On wakeup, the spinlock is NOT held so we must re-acquire it.
        innigkeit.Task.Current.get().task.block_reason = .notify;
        self.wait_queue.wait(&self.lock);
        self.lock.lock();
    }
    const result = self.pending & clear_mask;
    self.pending &= ~clear_mask;
    self.lock.unlock();
    return result;
}

/// Return pending bits matching `clear_mask` immediately (no blocking).
///
/// Clears and returns the matching bits; returns 0 if nothing is pending.
pub fn poll(self: *Notify, clear_mask: u64) u64 {
    self.lock.lock();
    defer self.lock.unlock();
    const result = self.pending & clear_mask;
    self.pending &= ~clear_mask;
    return result;
}

/// cap_invoke operations for Notify.
pub const Op = enum(u64) {
    /// Signal: arg1 = bitmask of bits to set.
    signal = 0,
    /// Wait: arg1 = clear_mask; return word[0] = bits received.
    wait = 1,
    /// Poll: like wait but returns immediately (0 if nothing pending).
    poll = 2,
};

const testing = @import("std").testing;

test "notify: poll returns 0 when nothing is pending" {
    const n = try Notify.create();
    defer n.unref();
    try testing.expectEqual(@as(u64, 0), n.poll(0xFF));
}

test "notify: signal then poll returns and clears the signaled bits" {
    const n = try Notify.create();
    defer n.unref();
    n.signal(0b101);
    try testing.expectEqual(@as(u64, 0b101), n.poll(0xFF));
    try testing.expectEqual(@as(u64, 0), n.poll(0xFF));
}

test "notify: poll mask filters which pending bits are consumed" {
    const n = try Notify.create();
    defer n.unref();
    n.signal(0b1111);
    try testing.expectEqual(@as(u64, 0b0011), n.poll(0b0011));
    try testing.expectEqual(@as(u64, 0b1100), n.poll(0b1100));
    try testing.expectEqual(@as(u64, 0), n.poll(0xFF));
}

test "notify: multiple signal calls accumulate bits" {
    const n = try Notify.create();
    defer n.unref();
    n.signal(0b0001);
    n.signal(0b0010);
    n.signal(0b0100);
    try testing.expectEqual(@as(u64, 0b0111), n.poll(0xFF));
}

test "notify: wait returns immediately when bits are already pending" {
    const n = try Notify.create();
    defer n.unref();
    n.signal(0b1);
    const result = n.wait(0b1);
    try testing.expectEqual(@as(u64, 1), result);
    try testing.expectEqual(@as(u64, 0), n.poll(0xFF));
}
