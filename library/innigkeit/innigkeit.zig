pub const exportEntry = @import("entry.zig").exportEntry;
pub const Syscall = @import("syscall.zig").Syscall;
pub const SyscallError = @import("syscall.zig").SyscallError;
pub const caps = @import("caps.zig");
pub const io = @import("io.zig");

pub const thread = struct {
    /// The required signature for a spawned thread entry point.
    ///
    /// The thread must call `thread.exitCurrent()` before returning; falling
    /// off the end of the function is undefined behaviour.
    pub const EntryFn = *const fn (arg: usize) callconv(.c) noreturn;

    /// Exit the current thread.
    pub fn exitCurrent() noreturn {
        _ = Syscall.call0(.exit_thread);
        unreachable;
    }

    /// Voluntarily yield the CPU to another runnable thread.
    pub fn yield() void {
        _ = Syscall.call0(.yield);
    }

    /// Spawn a new thread in the current process.
    ///
    /// The kernel creates a thread that begins executing `entry(arg)`.
    /// The new thread shares the process address space.
    pub fn spawn(entry: EntryFn, arg: usize) SyscallError!void {
        const result = Syscall.call2(
            .spawn_thread,
            @intFromPtr(entry),
            arg,
        );
        _ = try Syscall.decode(result);
    }
};

pub const process = struct {
    /// Exit the process.
    ///
    /// The kernel will terminate all threads in the process and release all
    /// process resources. `status` is reserved for a future wait/waitpid API.
    pub fn exit(status: u8) noreturn {
        _ = Syscall.call1(.exit_process, status);
        unreachable;
    }
};
