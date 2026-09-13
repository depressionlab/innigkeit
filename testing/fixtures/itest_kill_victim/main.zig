const innigkeit = @import("innigkeit");

/// Busy-loops forever. Used by `testing.integration.test.zig`'s
/// `process_kill` syscall test: reaching `exit_notify` at all proves the
/// killer fixture's `killProcess` call force-signaled it, not that this
/// process happened to exit on its own.
pub fn main() void {
    while (true) innigkeit.thread.yield();
}
