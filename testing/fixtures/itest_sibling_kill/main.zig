const innigkeit = @import("innigkeit");

/// Busy-loops forever. Used only as the sibling `main()` spawns below and never
/// exits on its own.
fn siblingEntry(_: usize) callconv(.c) noreturn {
    while (true) innigkeit.thread.yield();
}

/// Spawns a sibling thread that busy-loops forever, then exits the process
/// immediately. Used by `testing.integration.test.zig` to confirm the
/// still-running sibling is force-terminated by the exiting thread's
/// cascade (`Process.terminateCallingThread` -> `forceTerminateSiblings`)
/// instead of leaking forever. A sibling that never terminates keeps the
/// process's reference count above zero, so `exit_notify` (and this test's
/// wait) would never fire.
pub fn main() void {
    innigkeit.thread.spawn(siblingEntry, 0) catch
        @panic("spawn_thread failed");
    innigkeit.process.exit(77);
}
