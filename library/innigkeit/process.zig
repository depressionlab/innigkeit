const innigkeit = @import("innigkeit");

/// Exit the process.
///
/// The kernel will terminate all threads in the process and release all
/// process resources. `status` is reserved for a future wait/waitpid API.
pub fn exit(status: u8) noreturn {
    _ = innigkeit.Syscall.invoke(.exit_process, .{status});
    unreachable;
}
