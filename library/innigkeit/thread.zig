const std = @import("std");
const innigkeit = @import("innigkeit");

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
    innigkeit.Syscall.invoke(.yield, .{});
}

/// Spawn a new thread in the current process.
///
/// The kernel creates a thread that begins executing `entry(arg)`.
/// The new thread shares the process address space.
pub fn spawn(entry: EntryFn, arg: usize) innigkeit.Syscall.Error!void {
    const result = innigkeit.Syscall.invoke(
        .spawn_thread,
        .{ @intFromPtr(entry), arg },
    );
    _ = try innigkeit.Syscall.decode(result);
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

                // Transition state: running → completed, wake any join() waiter.
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
    pub fn join(self: InnigkeitThreadImpl) void {
        innigkeit.interop.debug_io.futexWaitUncancelable(u32, &self.completion.state.raw, @intFromEnum(State.running));
        self.completion.destroy(self.completion);
    }
};
