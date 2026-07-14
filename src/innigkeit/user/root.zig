const std = @import("std");

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");

pub const codesign = @import("codesign/root.zig");
pub const elf = @import("elf/root.zig");
pub const FdTable = @import("FdTable.zig");
pub const handlers = @import("handlers/root.zig");
pub const Process = @import("Process.zig");
pub const syscalls = @import("syscalls.zig");
pub const Thread = @import("Thread.zig");
pub const validate = @import("validate.zig");

const log = innigkeit.debug.log.scoped(.user);

/// Called on every syscall entry.
///
/// Interrupts are disabled on entry and re-enabled immediately so the kernel
/// remains responsive during syscall handling.
pub fn onSyscall(syscall_frame: architecture.user.SyscallFrame) void {
    if (core.is_debug) {
        const current_task: innigkeit.Task.Current = .get();
        std.debug.assert(current_task.task.interrupt_disable_count.load(.acquire) == 0);
        std.debug.assert(current_task.task.enable_access_to_user_memory_count.load(.acquire) == 0);
        std.debug.assert(!architecture.interrupts.areEnabled());
    }

    architecture.interrupts.enable();

    // The dispatcher computes the result; the arch layer writes it into the
    // correct return register (rax on x86-64, x0 on AArch64). Generic code
    // never names a physical register.
    syscall_frame.setReturnValue(dispatch(syscall_frame));
}

/// Decode and service a syscall, returning the raw value to deliver in the
/// architecture's return register (a non-negative result, or a negated wire
/// error code). Every syscall is serviced by the comptime dispatch table in
/// `syscalls.zig`; handlers that terminate the thread diverge and never return.
fn dispatch(syscall_frame: architecture.user.SyscallFrame) usize {
    const syscall = syscall_frame.syscall() orelse {
        log.warn("invalid syscall from userspace\n{f}", .{syscall_frame});
        return syscalls.unsupported_code;
    };

    log.verbose("received syscall: {t}", .{syscall});
    return syscalls.dispatch(syscall, syscall_frame);
}

/// Kernel-side entry for threads spawned via the spawn_thread syscall.
/// Runs in the new thread's context; calls `Thread.start` to enter userspace.
pub const init = struct {
    pub fn initialize() !void {
        try Process.init.initializeProcesses();
        try Thread.init.initializeThreads();
        try architecture.user.init.initialize();
    }
};
