const innigkeit = @import("innigkeit");

/// Block until `*addr != expected` or a futex_wake on addr is received.
///
/// Returns immediately if the word already differs from `expected`
/// (spurious wakeup, caller should re-check the condition).
pub fn wait(addr: *const u32, expected: u32) innigkeit.Syscall.Error!void {
    const result = innigkeit.Syscall.invoke(
        .futex_wait,
        .{ @intFromPtr(addr), expected },
    );
    _ = try innigkeit.Syscall.decode(result);
}

/// Wake up to `max_wake` threads blocked on `addr`.
///
/// Returns the number of threads actually woken.
pub fn wake(addr: *const u32, max_wake: u32) innigkeit.Syscall.Error!u32 {
    const result = innigkeit.Syscall.invoke(
        .futex_wake,
        .{ @intFromPtr(addr), max_wake },
    );
    return @intCast(try innigkeit.Syscall.decode(result));
}
