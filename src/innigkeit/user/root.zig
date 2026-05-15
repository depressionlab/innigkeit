const std = @import("std");

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const elf = @import("elf/root.zig");
pub const Process = @import("Process.zig");
pub const Thread = @import("Thread.zig");

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

    const syscall = syscall_frame.syscall() orelse {
        // TODO: return an error to userspace, ideally to the process that did the oopsie
        std.debug.panic("invalid syscall!\n{f}", .{syscall_frame});
    };

    log.verbose("received syscall: {t}", .{syscall});

    const arch_frame = syscall_frame.arch_specific;

    switch (syscall) {

        // ------------------------------------------------------------------ //
        // exit_thread — terminate the calling thread.                        //
        // ------------------------------------------------------------------ //
        .exit_thread => {
            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            scheduler_handle.terminate();
            unreachable;
        },

        // ------------------------------------------------------------------ //
        // write(fd: usize, buf: [*]const u8, len: usize) isize              //
        //   arg1 = fd   (0=stdin, 1=stdout, 2=stderr)                       //
        //   arg2 = buf  (pointer into user address space)                    //
        //   arg3 = len  (byte count)                                         //
        //   return: bytes written, or negative error code                    //
        // ------------------------------------------------------------------ //
        .write => {
            const fd = @as(i32, @intCast(syscall_frame.arg(.one)));
            const buf_ptr = syscall_frame.arg(.two);
            const buf_len = syscall_frame.arg(.three);

            if (fd != 1 and fd != 2) {
                arch_frame.rax = errCode(-9); // EBADF
                return;
            }

            if (buf_len == 0) {
                arch_frame.rax = 0;
                return;
            }

            if (!validateUserBuffer(buf_ptr, buf_len)) {
                arch_frame.rax = errCode(-14); // EFAULT
                return;
            }

            const current_task: innigkeit.Task.Current = .get();
            current_task.incrementEnableAccessToUserMemory();
            defer current_task.decrementEnableAccessToUserMemory();

            const buffer: []const u8 = @as([*]const u8, @ptrFromInt(buf_ptr))[0..buf_len];

            // TODO: route through per-process file descriptor table.
            const output = innigkeit.init.Output.terminal;
            output.writer.writeAll(buffer) catch |err| {
                log.err("write: {t}", .{err});
                arch_frame.rax = errCode(-5); // EIO
                return;
            };
            output.writer.flush() catch |err| {
                log.err("write flush: {t}", .{err});
                arch_frame.rax = errCode(-5); // EIO
                return;
            };

            arch_frame.rax = @intCast(buf_len);
        },

        // ------------------------------------------------------------------ //
        // read(fd: usize, buf: [*]u8, len: usize) isize                     //
        //   arg1 = fd   (0=stdin only)                                       //
        //   arg2 = buf  (pointer into user address space)                    //
        //   arg3 = len  (max bytes to read)                                  //
        //   return: bytes read, or negative error code                       //
        // ------------------------------------------------------------------ //
        .read => {
            const fd = @as(i32, @intCast(syscall_frame.arg(.one)));
            const buf_ptr = syscall_frame.arg(.two);
            const buf_len = syscall_frame.arg(.three);

            if (fd != 0) {
                arch_frame.rax = errCode(-9); // EBADF
                return;
            }

            if (buf_len == 0) {
                arch_frame.rax = 0;
                return;
            }

            if (!validateUserBuffer(buf_ptr, buf_len)) {
                arch_frame.rax = errCode(-14); // EFAULT
                return;
            }

            const current_task: innigkeit.Task.Current = .get();
            current_task.incrementEnableAccessToUserMemory();
            defer current_task.decrementEnableAccessToUserMemory();

            const buffer: []u8 = @as([*]u8, @ptrFromInt(buf_ptr))[0..buf_len];

            // TODO: route through per-process file descriptor table.
            const bytes_read = globals.input_buffer.readUntilNewline(buffer);
            arch_frame.rax = @intCast(bytes_read);
        },

        // ------------------------------------------------------------------ //
        // exit_process(status: u8) noreturn                                  //
        //   arg1 = exit status (reserved; future wait/waitpid API)           //
        // ------------------------------------------------------------------ //
        .exit_process => {
            const status: u8 = @truncate(syscall_frame.arg(.one));
            _ = status; // TODO: expose via a future wait() syscall.

            // TODO: For multi-core: send IPIs to CPUs running sibling threads
            //       and force-terminate them before deallocating process state.
            //       For now we terminate the calling thread; process cleanup
            //       runs automatically when the reference count reaches zero.
            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            scheduler_handle.terminate();
            unreachable;
        },

        // ------------------------------------------------------------------ //
        // yield() void                                                        //
        // ------------------------------------------------------------------ //
        .yield => {
            // TODO: expose a scheduler.yield() API that moves the current task
            //       to the back of the run queue.  For now this is a no-op;
            //       the next timer interrupt will preempt as usual.
            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            scheduler_handle.yield();
            unreachable;
        },

        // ------------------------------------------------------------------ //
        // spawn_thread(entry: usize, arg: usize) isize                       //
        //   arg1 = pointer to user-space entry function                      //
        //   arg2 = opaque argument forwarded to entry                        //
        //   return: 0 on success, negative error code on failure             //
        // ------------------------------------------------------------------ //
        .spawn_thread => {
            const entry_ptr = syscall_frame.arg(.one);
            const user_arg = syscall_frame.arg(.two);

            if (entry_ptr == 0) {
                arch_frame.rax = errCode(-22); // EINVAL
                return;
            }

            // TODO: Implement full thread spawning:
            //   1. Call `current_process.createThread(.{ .entry = ... })` with a
            //      kernel-side stub that sets `user_arg` in the ABI argument register
            //      then calls `Thread.start(entry_ptr)`.
            //   2. Enqueue the new thread on the run queue.
            //   3. Return an opaque thread handle for future join/detach syscalls.
            _ = user_arg;
            log.warn("spawn_thread: not yet implemented (entry=0x{x})", .{entry_ptr});
            arch_frame.rax = errCode(-38); // ENOSYS
        },

        // ------------------------------------------------------------------ //
        // cap_invoke(handle: u32, op: u64, arg: usize) → usize|error         //
        //   Invoke a capability-specific operation.                           //
        // ------------------------------------------------------------------ //
        .cap_invoke => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));
            const op: u64 = @intCast(syscall_frame.arg(.two));
            const arg3: usize = syscall_frame.arg(.three);

            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            const slot_info = cap_table.getAndRefLocked(handle) orelse {
                cap_table.lock.unlock();
                arch_frame.rax = errCode(-9); // EBADF
                return;
            };
            cap_table.lock.unlock();
            defer innigkeit.caps.CapabilityTable.unrefObject(slot_info.cap_type, slot_info.ptr);

            switch (slot_info.cap_type) {
                .null => unreachable,

                .notify => {
                    const notify: *innigkeit.caps.Notify = @ptrCast(@alignCast(slot_info.ptr));
                    const notify_op = std.enums.fromInt(innigkeit.caps.Notify.Op, op) orelse {
                        arch_frame.rax = errCode(-22); // EINVAL
                        return;
                    };
                    switch (notify_op) {
                        .signal => {
                            if (!slot_info.rights.write) {
                                arch_frame.rax = errCode(-1); // EPERM
                                return;
                            }
                            notify.signal(arg3);
                            arch_frame.rax = 0;
                        },
                        .wait => {
                            if (!slot_info.rights.read) {
                                arch_frame.rax = errCode(-1); // EPERM
                                return;
                            }
                            arch_frame.rax = notify.wait(arg3);
                        },
                        .poll => {
                            if (!slot_info.rights.read) {
                                arch_frame.rax = errCode(-1); // EPERM
                                return;
                            }
                            arch_frame.rax = notify.poll(arg3);
                        },
                    }
                },

                .endpoint => {
                    const endpoint: *innigkeit.caps.Endpoint = @ptrCast(@alignCast(slot_info.ptr));
                    const ep_op = std.enums.fromInt(innigkeit.caps.Endpoint.Op, op) orelse {
                        arch_frame.rax = errCode(-22); // EINVAL
                        return;
                    };
                    switch (ep_op) {
                        .send => {
                            if (!slot_info.rights.write) {
                                arch_frame.rax = errCode(-1); // EPERM
                                return;
                            }
                            if (!validateUserBuffer(arg3, @sizeOf(innigkeit.caps.Message))) {
                                arch_frame.rax = errCode(-14); // EFAULT
                                return;
                            }
                            // Copy message out of user memory before blocking.
                            const msg_uptr: *const innigkeit.caps.Message = @ptrFromInt(arg3);
                            current_task.incrementEnableAccessToUserMemory();
                            const msg = msg_uptr.*;
                            current_task.decrementEnableAccessToUserMemory();
                            endpoint.send(msg);
                            arch_frame.rax = 0;
                        },
                        .recv => {
                            if (!slot_info.rights.read) {
                                arch_frame.rax = errCode(-1); // EPERM
                                return;
                            }
                            if (!validateUserBuffer(arg3, @sizeOf(innigkeit.caps.Message))) {
                                arch_frame.rax = errCode(-14); // EFAULT
                                return;
                            }
                            // Block first, then copy into user memory.
                            const msg = endpoint.recv();
                            const msg_uptr: *innigkeit.caps.Message = @ptrFromInt(arg3);
                            current_task.incrementEnableAccessToUserMemory();
                            msg_uptr.* = msg;
                            current_task.decrementEnableAccessToUserMemory();
                            arch_frame.rax = 0;
                        },
                    }
                },

                .frame => {
                    const frame: *innigkeit.caps.Frame = @ptrCast(@alignCast(slot_info.ptr));
                    const frame_op = std.enums.fromInt(innigkeit.caps.Frame.Op, op) orelse {
                        arch_frame.rax = errCode(-22); // EINVAL
                        return;
                    };
                    switch (frame_op) {
                        .clone => {
                            if (!slot_info.rights.grant) {
                                arch_frame.rax = errCode(-1); // EPERM
                                return;
                            }
                            // Bump refcount before inserting the new slot.
                            frame.ref();
                            cap_table.lock.lock();
                            const new_idx = cap_table.insertLocked(
                                .frame,
                                frame,
                                slot_info.rights,
                            ) catch {
                                cap_table.lock.unlock();
                                frame.unref();
                                arch_frame.rax = errCode(-12); // ENOMEM (table full)
                                return;
                            };
                            cap_table.lock.unlock();
                            arch_frame.rax = @intCast(new_idx);
                        },
                        .phys_addr => {
                            if (!slot_info.rights.read) {
                                arch_frame.rax = errCode(-1); // EPERM
                                return;
                            }
                            arch_frame.rax = frame.physicalAddress().value;
                        },
                    }
                },
            }
        },

        // ------------------------------------------------------------------ //
        // cap_copy(handle: u32, rights: u16) → new_handle|error              //
        // ------------------------------------------------------------------ //
        .cap_copy => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));
            const rights_raw: u16 = @truncate(syscall_frame.arg(.two));
            const new_rights: innigkeit.caps.Rights = @bitCast(rights_raw);

            const process = Process.from(innigkeit.Task.Current.get().task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            const new_idx = cap_table.copyLocked(handle, new_rights) catch |err| {
                cap_table.lock.unlock();
                arch_frame.rax = switch (err) {
                    error.NotFound => errCode(-9),        // EBADF
                    error.Full => errCode(-12),           // ENOMEM
                    error.RightsEscalation => errCode(-1), // EPERM
                };
                return;
            };
            cap_table.lock.unlock();
            arch_frame.rax = @intCast(new_idx);
        },

        // ------------------------------------------------------------------ //
        // cap_move(handle: u32) → new_handle|error                           //
        //   Moves the capability to a new slot and invalidates the old one.  //
        // ------------------------------------------------------------------ //
        .cap_move => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));

            const process = Process.from(innigkeit.Task.Current.get().task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();

            const slot = cap_table.getLocked(handle) orelse {
                cap_table.lock.unlock();
                arch_frame.rax = errCode(-9); // EBADF
                return;
            };
            const current_rights = slot.rights;

            // Copy to a new slot (bumps refcount to 2).
            const new_idx = cap_table.copyLocked(handle, current_rights) catch |err| {
                cap_table.lock.unlock();
                arch_frame.rax = switch (err) {
                    error.NotFound => errCode(-9),
                    error.Full => errCode(-12),
                    error.RightsEscalation => unreachable, // same rights
                };
                return;
            };

            // Remove the original slot (decrements refcount back to 1).
            cap_table.removeLocked(handle) catch unreachable;

            cap_table.lock.unlock();
            arch_frame.rax = @intCast(new_idx);
        },

        // ------------------------------------------------------------------ //
        // cap_delete(handle: u32) → 0|error                                  //
        // ------------------------------------------------------------------ //
        .cap_delete => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));

            const process = Process.from(innigkeit.Task.Current.get().task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            cap_table.removeLocked(handle) catch {
                cap_table.lock.unlock();
                arch_frame.rax = errCode(-9); // EBADF
                return;
            };
            cap_table.lock.unlock();
            arch_frame.rax = 0;
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

/// Cast a signed error code to the bit pattern expected in rax / a0 / x0.
inline fn errCode(code: i64) usize {
    return @bitCast(code);
}

/// Return true if `[ptr, ptr+len)` is a non-wrapping range inside the
/// user virtual address space.
///
/// This is a coarse guard against obviously bogus pointers. The paging
/// hardware provides the true isolation guarantee.
fn validateUserBuffer(ptr: usize, len: usize) bool {
    if (len == 0) return true;
    const end = ptr +% len; // wrapping add to detect overflow
    if (end < ptr) return false; // wrapped around
    // TODO: tighten against `architecture.user.user_memory_range` once the
    //       address-space layout is stable.
    return ptr != 0;
}

const globals = struct {
    var input_buffer: innigkeit.init.SerialInputBuffer = .{};
};
