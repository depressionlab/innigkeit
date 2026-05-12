//! A reader writer lock.
//!
//! Based on `std.Thread.RwLock.DefaultRwLock`.
//!
//! TODO: replace this with something better, there should be no need for a mutex and we want seperate queues for
//! readers and writers allowing us to wake all readers when a write lock is released
const RwLock = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");

state: usize = 0,
mutex: innigkeit.sync.Mutex = .{},

wait_queue_spinlock: innigkeit.sync.TicketSpinLock = .{},
wait_queue: innigkeit.sync.WaitQueue = .{},

/// Attempt to upgrade a read lock to a write lock.
///
/// Returns `true` if the upgrade was successful.
///
/// If it fails the lock is left unlocked.
pub fn tryUpgradeLock(self: *RwLock) bool {
    _ = @atomicRmw(usize, &self.state, .Add, WRITER, .acquire);

    if (self.mutex.tryLock()) {
        const state = @atomicRmw(usize, &self.state, .Sub, READER, .release);

        if (state & READER_MASK == READER) {
            _ = @atomicRmw(usize, &self.state, .Or, IS_WRITING, .acquire);
            return true;
        }

        _ = @atomicRmw(usize, &self.state, .Sub, WRITER, .release);

        self.mutex.unlock();
    } else {
        _ = @atomicRmw(usize, &self.state, .Sub, READER + WRITER, .release);
    }

    return false;
}

pub fn tryWriteLock(self: *RwLock) bool {
    if (self.mutex.tryLock()) {
        const state = @atomicLoad(usize, &self.state, .monotonic);

        if (state & READER_MASK == 0) {
            _ = @atomicRmw(usize, &self.state, .Or, IS_WRITING, .acquire);
            return true;
        }

        self.mutex.unlock();
    }

    return false;
}

pub fn writeLock(self: *RwLock) void {
    _ = @atomicRmw(usize, &self.state, .Add, WRITER, .acquire);
    self.mutex.lock();

    const state = @atomicRmw(
        usize,
        &self.state,
        .Add,
        IS_WRITING -% WRITER,
        .acquire,
    );

    if (state & READER_MASK != 0) {
        self.wait_queue_spinlock.lock();
        self.wait_queue.wait(&self.wait_queue_spinlock);
    }
}

pub fn writeUnlock(self: *RwLock) void {
    _ = @atomicRmw(usize, &self.state, .And, ~IS_WRITING, .release);
    self.mutex.unlock();
}

/// Returns `true` if the lock is read locked.
///
/// This value can only be trusted if the lock is held by the current task.
pub fn isReadLocked(self: *const RwLock) bool {
    const state = @atomicLoad(usize, &self.state, .monotonic);
    return state & READER_MASK != 0;
}

/// Returns `true` if the lock is read locked.
///
/// This value can only be trusted if the lock is held by the current task.
pub fn isWriteLocked(self: *const RwLock) bool {
    const state = @atomicLoad(usize, &self.state, .monotonic);
    return state & IS_WRITING != 0;
}

pub fn tryReadLock(self: *RwLock) bool {
    const state = @atomicLoad(usize, &self.state, .monotonic);

    if (state & (IS_WRITING | WRITER_MASK) == 0) {
        _ = @cmpxchgStrong(
            usize,
            &self.state,
            state,
            state + READER,
            .acquire,
            .monotonic,
        ) orelse return true;
    }

    if (self.mutex.tryLock()) {
        _ = @atomicRmw(usize, &self.state, .Add, READER, .acquire);
        self.mutex.unlock();
        return true;
    }

    return false;
}

pub fn readLock(self: *RwLock) void {
    var state = @atomicLoad(usize, &self.state, .monotonic);

    while (state & (IS_WRITING | WRITER_MASK) == 0) {
        state = @cmpxchgWeak(
            usize,
            &self.state,
            state,
            state + READER,
            .acquire,
            .monotonic,
        ) orelse return;
    }

    self.mutex.lock();
    _ = @atomicRmw(usize, &self.state, .Add, READER, .acquire);
    self.mutex.unlock();
}

pub fn readUnlock(self: *RwLock) void {
    const state = @atomicRmw(usize, &self.state, .Sub, READER, .release);

    if ((state & READER_MASK == READER) and (state & IS_WRITING != 0)) {
        self.wait_queue_spinlock.lock();
        defer self.wait_queue_spinlock.unlock();
        self.wait_queue.wakeOne(&self.wait_queue_spinlock);
    }
}

const IS_WRITING: usize = 1;
const WRITER: usize = 1 << 1;
const READER: usize = 1 << (1 + @bitSizeOf(Count));
const WRITER_MASK: usize = std.math.maxInt(Count) << @ctz(WRITER);
const READER_MASK: usize = std.math.maxInt(Count) << @ctz(READER);
const Count = std.meta.Int(.unsigned, @divFloor(@bitSizeOf(usize) - 1, 2));
