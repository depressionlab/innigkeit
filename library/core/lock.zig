const std = @import("std");

// SPINNING LOCKS

pub const SpinLock = packed struct {
    inner: usize = 0,

    pub fn lock(self: *SpinLock) void {
        while (@cmpxchgWeak(usize, &self.inner, 0, 1, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    pub fn tryLock(self: *SpinLock) bool {
        return @cmpxchgWeak(usize, &self.inner, 0, 1, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *SpinLock) void {
        @atomicStore(usize, &self.inner, 0, .release);
    }
};

pub const SpinSharedLock = packed struct {
    inner: u32 = 0,

    pub fn lock(self: *SpinSharedLock) void {
        return self.lockInner(0);
    }

    /// Upgrades a shared lock to an exclusive one.
    pub fn relock(self: *SpinSharedLock) void {
        return self.lockInner(1);
    }

    inline fn lockInner(self: *SpinSharedLock, allowed: u32) void {
        while (@cmpxchgWeak(u32, &self.inner, allowed, 0x80000000, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    pub fn lockShared(self: *SpinSharedLock) void {
        while (true) {
            const state = @atomicLoad(u32, &self.inner, .unordered);
            if (state & 0x80000000 == 0 and
                @cmpxchgWeak(u32, &self.inner, state, state + 1, .acquire, .monotonic) == null)
                return;

            std.atomic.spinLoopHint();
        }
    }

    pub fn tryLock(self: *SpinSharedLock) bool {
        return @cmpxchgWeak(u32, &self.inner, 0, 0x80000000, .acquire, .monotonic) == null;
    }

    pub fn tryLockShared(self: *SpinSharedLock) bool {
        const state = @atomicLoad(u32, &self.inner, .unordered);
        return state & 0x80000000 == 0 and
            @cmpxchgWeak(u32, &self.inner, state, state + 1, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *SpinSharedLock) void {
        @atomicStore(u32, &self.inner, 0, .release);
    }

    pub fn unlockShared(self: *SpinSharedLock) void {
        _ = @atomicRmw(u32, &self.inner, .Sub, 1, .release);
    }
};

// NO-OP LOCKS

pub const NoopLock = struct {
    pub fn lock(_: *NoopLock) void {}
    pub fn tryLock(_: *NoopLock) bool {}
    pub fn unlock(_: *NoopLock) void {}
};

pub const NoopSharedLock = struct {
    pub fn lock(_: *NoopSharedLock) void {}
    pub fn relock(_: *NoopSharedLock) void {}
    pub fn lockShared(_: *NoopSharedLock) void {}
    pub fn tryLock(_: *NoopSharedLock) bool {}
    pub fn tryLockShared(_: *NoopSharedLock) bool {}
    pub fn unlock(_: *NoopSharedLock) void {}
    pub fn unlockShared(_: *NoopSharedLock) void {}
};

// GENERIC LOCKS

pub fn Lock(comptime thread_safe: bool) type {
    if (!thread_safe) return NoopLock;
    if (@import("options").spinlock) return SpinLock;
    return std.Thread.Mutex;
}

pub fn SharedLock(comptime thread_safe: bool) type {
    if (!thread_safe) return NoopSharedLock;
    if (@import("options").spinlock) return SpinSharedLock;
    return std.Thread.RwLock;
}
