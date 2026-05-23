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
