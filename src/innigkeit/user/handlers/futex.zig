//! The futex syscalls: futex_wait, futex_wait_timeout, futex_wake.
//!
//! The futex word lives in user memory; each handler validates the 4-byte
//! address before touching it. The kernel-side futex (innigkeit.sync.futex)
//! performs the actual fault-safe atomic load of the word under its own lock.

const innigkeit = @import("innigkeit");
const validate = @import("../validate.zig");
const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");

/// futex_wait(addr, expected) -> 0 : block until *addr != expected or a matching
/// futex_wake arrives (returns immediately if the value already differed).
pub fn futexWait(context: Context) Error.Syscall!usize {
    const addr = context.arg(.one);
    const expected = context.arg32(.two);
    if (!validate.validateUserBuffer(addr, @sizeOf(u32)))
        return Error.Syscall.BadAddress;
    innigkeit.sync.futex.wait(addr, expected);
    return 0;
}

/// futex_wait_timeout(addr, expected, deadline_ms) -> 0 : like futex_wait, but
/// also wakes when uptime_ms >= deadline_ms.
pub fn futexWaitTimeout(context: Context) Error.Syscall!usize {
    const addr = context.arg(.one);
    const expected = context.arg32(.two);
    const deadline_ms = context.arg64(.three);
    if (!validate.validateUserBuffer(addr, @sizeOf(u32)))
        return Error.Syscall.BadAddress;
    innigkeit.sync.futex.waitTimeout(addr, expected, deadline_ms);
    return 0;
}

/// futex_wake(addr, max_wake) -> woken_count : wake up to max_wake threads
/// blocked on addr.
pub fn futexWake(context: Context) Error.Syscall!usize {
    const addr = context.arg(.one);
    const max_wake = context.arg32(.two);
    if (!validate.validateUserBuffer(addr, @sizeOf(u32)))
        return Error.Syscall.BadAddress;
    const woken = innigkeit.sync.futex.wake(addr, max_wake);
    return @intCast(woken);
}
