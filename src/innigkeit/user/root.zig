const std = @import("std");

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const elf = @import("elf.zig");
pub const Process = @import("Process.zig");
pub const Thread = @import("Thread.zig");

const log = innigkeit.debug.log.scoped(.user);

/// Called on syscall.
///
/// Interrupts are disabled on entry.
pub fn onSyscall(syscall_frame: architecture.user.SyscallFrame) void {
    if (core.is_debug) {
        const current_task: innigkeit.Task.Current = .get();
        std.debug.assert(current_task.task.interrupt_disable_count.load(.acquire) == 0);
        std.debug.assert(current_task.task.enable_access_to_user_memory_count.load(.acquire) == 0);
        std.debug.assert(!architecture.interrupts.areEnabled());
    }

    architecture.interrupts.enable();

    const syscall = syscall_frame.syscall() orelse {
        // TODO: return an error to userspace
        std.debug.panic("invalid syscall!\n{f}", .{syscall_frame});
    };

    log.verbose("received syscall: {t}", .{syscall});

    const arch_frame = syscall_frame.arch_specific;

    switch (syscall) {
        .exit_current_thread => {
            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            scheduler_handle.terminate();
            unreachable;
        },
        .write => {
            const fd = @as(i32, @intCast(syscall_frame.arg(.one)));
            const buf_ptr = syscall_frame.arg(.two);
            const buf_len = syscall_frame.arg(.three);

            // Only allow stdout (fd=1) and stderr (fd=2)
            if (fd != 1 and fd != 2) {
                arch_frame.rax = @bitCast(@as(i64, -9)); // EBADF
                return;
            }

            if (buf_len == 0) {
                arch_frame.rax = 0;
                return;
            }

            const current_task: innigkeit.Task.Current = .get();
            current_task.incrementEnableAccessToUserMemory();
            defer current_task.decrementEnableAccessToUserMemory();

            const buffer = @as([*]const u8, @ptrFromInt(buf_ptr))[0..buf_len];

            // Write to kernel console
            const output = innigkeit.init.Output.terminal;
            output.writer.writeAll(buffer) catch |err| {
                log.err("write syscall failed: {}", .{err});
                arch_frame.rax = @bitCast(@as(i64, -5)); // EIO
                return;
            };
            output.writer.flush() catch |err| {
                log.err("flush failed: {}", .{err});
                arch_frame.rax = @bitCast(@as(i64, -5)); // EIO
                return;
            };

            arch_frame.rax = @intCast(buf_len);
        },
        .read => {
            const fd = @as(i32, @intCast(syscall_frame.arg(.one)));
            const buf_ptr = syscall_frame.arg(.two);
            const buf_len = syscall_frame.arg(.three);

            // Only allow stdin (fd=0)
            if (fd != 0) {
                arch_frame.rax = @bitCast(@as(i64, -9)); // EBADF
                return;
            }

            if (buf_len == 0) {
                arch_frame.rax = 0;
                return;
            }

            const current_task: innigkeit.Task.Current = .get();
            current_task.incrementEnableAccessToUserMemory();
            defer current_task.decrementEnableAccessToUserMemory();

            const buffer = @as([*]u8, @ptrFromInt(buf_ptr))[0..buf_len];

            // Read from input buffer
            const bytes_read = globals.input_buffer.readUntilNewline(buffer);

            arch_frame.rax = @intCast(bytes_read);
        },
    }
}

pub const init = struct {
    pub fn initialize() !void {
        try Process.init.initializeProcesses();
        try Thread.init.initializeThreads();
        try architecture.user.init.initialize();
    }
};

const globals = struct {
    pub var input_buffer: @import("innigkeit").init.SerialInputBuffer = .{};
};
