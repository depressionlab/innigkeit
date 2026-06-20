const std = @import("std");
const innigkeit = @import("innigkeit");
const Error = @import("Error.zig");

/// The required signature for a spawned thread entry point.
///
/// The thread must call `thread.exitCurrent()` before returning; falling
/// off the end of the function is undefined behaviour.
pub const EntryFn = *const fn (arg: usize) callconv(.c) noreturn;

/// Exit the current thread.
pub fn exitCurrent() noreturn {
    _ = innigkeit.Syscall.invoke(.exit_thread, .{});
    unreachable;
}

/// Voluntarily yield the CPU to another runnable thread.
pub fn yield() void {
    _ = innigkeit.Syscall.invoke(.yield, .{});
}

/// P/E-core scheduling hint values for `setCoreHint`.
pub const CoreHint = enum(u8) {
    unknown = 0,
    p_core = 1,
    e_core = 2,
};

/// Suggest to the scheduler which core class should run the calling thread.
/// On non-hybrid systems the hint is stored but never acted upon.
pub fn setCoreHint(hint: CoreHint) void {
    _ = innigkeit.Syscall.invoke(.thread_set_hint, .{@as(usize, @intFromEnum(hint))});
}

/// Quality-of-Service class for `setQos`. Maps to scheduler weight + slice:
/// `interactive` favours latency, `background` favors throughput.
pub const Qos = enum(u8) {
    interactive = 0,
    default = 1,
    background = 2,
};

/// Set the calling thread's QoS class. Affects only this thread, raising or
/// lowering one's own QoS is always permitted.
pub fn setQos(qos: Qos) void {
    // TODO: is this type conversion necessary?
    _ = innigkeit.Syscall.invoke(.thread_set_qos, .{@as(usize, @intFromEnum(qos))});
}

/// Spawn a new thread in the current process.
///
/// The kernel creates a thread that begins executing `entry(arg)`.
/// The new thread shares the process address space.
pub fn spawn(entry: EntryFn, arg: usize) Error.Syscall!void {
    const result = innigkeit.Syscall.invoke(
        .spawn_thread,
        .{ @intFromPtr(entry), arg },
    );
    _ = try innigkeit.Syscall.decode(result);
}

/// Sleep for at least `nanoseconds` using the kernel's sleep queue.
///
/// Precision is bounded by the scheduler tick period (5 ms by default).
pub fn sleep(nanoseconds: u64) void {
    const duration: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromNanoseconds(@intCast(nanoseconds)),
        .clock = .awake,
    };
    duration.sleep(innigkeit.interop.debug_io) catch {};
}

/// High-level thread handle for Innigkeit userspace.
pub const Thread = struct {
    impl: InnigkeitThreadImpl,

    pub fn spawn(comptime f: anytype, args: anytype) std.Thread.SpawnError!Thread {
        return .{ .impl = try InnigkeitThreadImpl.spawn(.{}, f, args) };
    }

    pub fn join(self: Thread) void {
        self.impl.join();
    }

    pub fn detach(self: Thread) void {
        self.impl.detach();
    }
};

/// A mutex backed by `std.Io.Mutex` with `innigkeit.interop.debug_io` baked in.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub const init: Mutex = .{};

    pub fn lock(m: *Mutex) void {
        m.inner.lockUncancelable(innigkeit.interop.debug_io);
    }

    pub fn unlock(m: *Mutex) void {
        m.inner.unlock(innigkeit.interop.debug_io);
    }

    /// Non-blocking acquire; returns `true` if the lock was taken.
    pub fn tryLock(m: *Mutex) bool {
        return m.inner.tryLock();
    }
};

/// A condition variable backed by `std.Io.Condition` with `innigkeit.interop.debug_io` baked in.
///
/// Must always be used with a matching `innigkeit.Mutex`.
///
///   var cv: Condition = .init;
///   var mu: Mutex = .init;
///   // waiter:
///   mu.lock();
///   while (!ready) cv.wait(&mu);
///   mu.unlock();
///   // signaler:
///   mu.lock();
///   ready = true;
///   cv.signal();
///   mu.unlock();
pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub const init: Condition = .{};

    /// Atomically unlock `m`, block until signaled, then re-lock `m`.
    pub fn wait(c: *Condition, m: *Mutex) void {
        c.inner.waitUncancelable(innigkeit.interop.debug_io, &m.inner);
    }

    /// Wake one thread blocked in `wait`.
    pub fn signal(c: *Condition) void {
        c.inner.signal(innigkeit.interop.debug_io);
    }

    /// Wake all threads blocked in `wait`.
    pub fn broadcast(c: *Condition) void {
        c.inner.broadcast(innigkeit.interop.debug_io);
    }
};

/// std.Thread Impl for Innigkeit userspace.
///
/// Uses spawn_thread + heap-allocated Instance for join/detach, with a 3-state
/// atomic (running/completed/detached) and futex signaling.
///
/// Register via std_options:
/// ```zig
/// pub const std_options_thread_impl = innigkeit.thread.InnigkeitThreadImpl;
/// ```
pub const InnigkeitThreadImpl = struct {
    completion: *Completion,

    pub const ThreadHandle = usize;

    var next_id: std.atomic.Value(usize) = .init(2); // main thread gets 1

    const State = enum(u32) {
        running = 0,
        completed = 1,
        detached = 2,
    };

    /// Per-thread completion record, heap-allocated by spawn().
    ///
    /// The `destroy` function pointer allows join()/detach() to free the
    /// containing Instance without knowing its concrete type.
    pub const Completion = struct {
        state: std.atomic.Value(u32),
        id: usize,
        destroy: *const fn (*Completion) void,
    };

    pub fn getCurrentId() usize {
        // Without a set_tls_base syscall we cannot cheaply identify the
        // running thread. Returning a sentinel is enough for now; callers
        // that need per-thread identity should use the ThreadHandle returned
        // from spawn().
        return next_id.load(.monotonic) - 1;
    }

    pub fn getCpuCount() !usize {
        return 1;
    }

    pub fn spawn(config: std.Thread.SpawnConfig, comptime f: anytype, args: anytype) std.Thread.SpawnError!InnigkeitThreadImpl {
        _ = config;
        const Args = @TypeOf(args);
        const bad_ret = "thread function must return void, noreturn, !void, or !noreturn";

        const Instance = struct {
            completion: Completion,
            fn_args: Args,

            fn entryFn(raw_arg: usize) callconv(.c) noreturn {
                const self: *@This() = @ptrFromInt(raw_arg);

                // Dispatch the thread function, handling all valid return types.
                const ret_type = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
                switch (@typeInfo(ret_type)) {
                    .noreturn => @call(.auto, f, self.fn_args),
                    .void => @call(.auto, f, self.fn_args),
                    .error_union => |eu| {
                        comptime switch (eu.payload) {
                            void, noreturn => {},
                            else => @compileError(bad_ret),
                        };
                        @call(.auto, f, self.fn_args) catch |err| {
                            std.debug.print("thread error: {s}\n", .{@errorName(err)});
                        };
                    },
                    else => @compileError(bad_ret),
                }

                // Transition state: running -> completed, wake any join() waiter.
                const prev: State = @enumFromInt(
                    self.completion.state.swap(@intFromEnum(State.completed), .seq_cst),
                );
                switch (prev) {
                    .running => {
                        // join() will free; wake it
                        innigkeit.interop.debug_io.futexWake(u32, &self.completion.state.raw, std.math.maxInt(u32));
                    },
                    .detached => {
                        // detach() already ran; we own the allocation.
                        self.completion.destroy(&self.completion);
                    },
                    .completed => unreachable,
                }
                exitCurrent();
            }

            fn destroyFn(c: *Completion) void {
                const self: *@This() = @fieldParentPtr("completion", c);
                innigkeit.mem.page_allocator.destroy(self);
            }
        };

        const id = next_id.fetchAdd(1, .monotonic);
        const instance = try innigkeit.mem.page_allocator.create(Instance);
        errdefer innigkeit.mem.page_allocator.destroy(instance);

        instance.* = .{
            .completion = .{
                .state = .init(@intFromEnum(State.running)),
                .id = id,
                .destroy = Instance.destroyFn,
            },
            .fn_args = args,
        };

        innigkeit.thread.spawn(Instance.entryFn, @intFromPtr(instance)) catch |err|
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SystemResources,
            };
        return .{ .completion = &instance.completion };
    }

    pub fn getHandle(self: InnigkeitThreadImpl) ThreadHandle {
        return self.completion.id;
    }

    /// Release the obligation to call join(); the thread frees its own
    /// Instance when it completes.
    pub fn detach(self: InnigkeitThreadImpl) void {
        const prev: State = @enumFromInt(
            self.completion.state.swap(@intFromEnum(State.detached), .seq_cst),
        );
        switch (prev) {
            .running => {}, // thread will destroy on completion
            .completed => self.completion.destroy(self.completion),
            .detached => unreachable,
        }
    }

    /// Block until the thread completes, then free its resources.
    ///
    /// May only be called once per handle. A second call is a programming
    /// error; in this implementation it silently returns without double-freeing.
    pub fn join(self: InnigkeitThreadImpl) void {
        innigkeit.interop.debug_io.futexWaitUncancelable(u32, &self.completion.state.raw, @intFromEnum(State.running));
        // CAS completed -> detached claims the destroy right atomically.
        // A racing second join() loses the CAS and returns without double-freeing.
        if (self.completion.state.cmpxchgStrong(
            @intFromEnum(State.completed),
            @intFromEnum(State.detached),
            .acq_rel,
            .acquire,
        ) == null) {
            self.completion.destroy(self.completion);
        }
    }
};

test "Mutex.tryLock fast path" {
    var m: Mutex = .init;
    try std.testing.expect(m.tryLock()); // unlocked -> locked_once
    try std.testing.expect(!m.tryLock()); // already held
    m.unlock(); // locked_once -> unlocked, no futex wake
    try std.testing.expect(m.tryLock()); // can re-acquire
    m.unlock();
}

test "Condition.signal and broadcast with no waiters" {
    var cv: Condition = .init;
    // Both are no-ops when nobody is waiting (early-out before futex).
    cv.signal();
    cv.broadcast();
}

test "Thread.join waits for completion" {
    if (@import("builtin").os.tag != .freestanding) return error.SkipZigTest;
    var flag: std.atomic.Value(u32) = .init(0);
    const t = try Thread.spawn(setFlag, .{&flag});
    t.join();
    try std.testing.expectEqual(@as(u32, 1), flag.load(.acquire));
}

test "Thread.detach does not crash" {
    if (@import("builtin").os.tag != .freestanding) return error.SkipZigTest;
    // Detach before the thread has a chance to finish; kernel frees resources.
    const t = try Thread.spawn(justYield, .{});
    t.detach();
}

test "Mutex serializes concurrent increments" {
    if (@import("builtin").os.tag != .freestanding) return error.SkipZigTest;
    var counter: u32 = 0;
    var mu: Mutex = .init;
    const State = struct { counter: *u32, mu: *Mutex };
    var s: State = .{ .counter = &counter, .mu = &mu };
    const t1 = try Thread.spawn(lockedIncrement, .{&s});
    const t2 = try Thread.spawn(lockedIncrement, .{&s});
    t1.join();
    t2.join();
    try std.testing.expectEqual(@as(u32, 200), @atomicLoad(u32, &counter, .acquire));
}

fn setFlag(flag: *std.atomic.Value(u32)) void {
    flag.store(1, .release);
}

fn justYield() void {
    innigkeit.thread.yield();
}

const MutexState = struct { counter: *u32, mu: *Mutex };

fn lockedIncrement(s: *MutexState) void {
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        s.mu.lock();
        s.counter.* += 1;
        s.mu.unlock();
    }
}
