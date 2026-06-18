const std = @import("std");

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const codesign = @import("codesign/root.zig");
pub const elf = @import("elf/root.zig");
pub const FdTable = @import("FdTable.zig");
pub const Process = @import("Process.zig");
pub const Thread = @import("Thread.zig");
pub const handlers = @import("handlers/root.zig");
pub const validate = @import("validate.zig");
const validateUserBuffer = validate.validateUserBuffer;

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
/// architecture's return register (a successful value, or a negated errno bit
/// pattern via `errCode`). Arms that terminate the thread diverge and never
/// return.
fn dispatch(syscall_frame: architecture.user.SyscallFrame) usize {
    const syscall = syscall_frame.syscall() orelse {
        log.warn("invalid syscall from usersapce\n{f}", .{syscall_frame});
        return errCode(e.ENOSYS);
    };

    log.verbose("received syscall: {t}", .{syscall});

    var syscall_result: usize = 0;

    switch (syscall) {
        // ------------------------------------------------------------------ //
        // exit_thread: terminate the calling thread.                         //
        // ------------------------------------------------------------------ //
        .exit_thread => {
            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            scheduler_handle.terminate();
            unreachable;
        },

        // ------------------------------------------------------------------ //
        // write(fd: usize, buf: [*]const u8, len: usize) isize               //
        //   arg1 = fd   (resolved via the per-processs fd table)             //
        //   arg2 = buf  (pointer into user address space)                    //
        //   arg3 = len  (byte count)                                         //
        //   return: bytes written, or negative error code                    //
        // ------------------------------------------------------------------ //
        .write => {
            const fd = syscall_frame.arg(.one);
            const buf_ptr = syscall_frame.arg(.two);
            const buf_len = syscall_frame.arg(.three);

            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);

            const resolved = process.fd_table.resolve(fd) orelse {
                syscall_result = errCode(e.EBADF);
                return syscall_result;
            };

            if (buf_len == 0) {
                syscall_result = 0;
                return syscall_result;
            }

            switch (resolved.desc) {
                .terminal_out => {
                    // The terminal writer consumes the user buffer in place, so
                    // keep a single explicit access window around the streaming
                    // write.
                    const buffer = validate.userSliceConst(buf_ptr, buf_len) catch {
                        syscall_result = errCode(e.EFAULT);
                        return syscall_result;
                    };
                    const access: validate.UserAccess = .acquire();
                    defer access.release();
                    const output = innigkeit.init.Output.terminal;
                    output.writer.writeAll(buffer) catch |err| {
                        log.err("write: {t}", .{err});
                        syscall_result = errCode(e.EIO);
                        return syscall_result;
                    };
                    output.writer.flush() catch |err| {
                        log.err("write flush: {t}", .{err});
                        syscall_result = errCode(e.EIO);
                        return syscall_result;
                    };

                    syscall_result = @intCast(buf_len);
                },
                .file => {
                    syscall_result = handlers.file.syscallWriteFile(
                        &process.fd_table,
                        fd,
                        buf_ptr,
                        buf_len,
                    );
                },
                // keyboard_in is not writable; .closed never escapes resolve.
                else => syscall_result = errCode(e.EBADF),
            }
        },

        // ------------------------------------------------------------------ //
        // read(fd: usize, buf: [*]u8, len: usize) isize                      //
        //   arg1 = fd   (resolved via the per-process fd table)              //
        //   arg2 = buf  (pointer into user address space)                    //
        //   arg3 = len  (max bytes to read)                                  //
        //   return: bytes read, or negative error code                       //
        // ------------------------------------------------------------------ //
        .read => {
            const fd = syscall_frame.arg(.one);
            const buf_ptr = syscall_frame.arg(.two);
            const buf_len = syscall_frame.arg(.three);

            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);

            const resolved = process.fd_table.resolve(fd) orelse {
                syscall_result = errCode(e.EBADF);
                return syscall_result;
            };

            if (buf_len == 0) {
                syscall_result = 0;
                return syscall_result;
            }

            switch (resolved.desc) {
                .keyboard_in => {
                    // The keyboard driver fills the user buffer in place, so
                    // keep a single explicit access window around the streaming
                    // read.
                    const buffer = validate.userSlice(buf_ptr, buf_len) catch {
                        syscall_result = errCode(e.EFAULT);
                        return syscall_result;
                    };
                    const access: validate.UserAccess = .acquire();
                    defer access.release();

                    const bytes_read = innigkeit.drivers.input.ps2.keyboard_buffer.readLine(buffer);
                    syscall_result = @intCast(bytes_read);
                },
                .file => {
                    syscall_result = handlers.file.syscallReadFile(
                        &process.fd_table,
                        fd,
                        buf_ptr,
                        buf_len,
                    );
                },
                // terminal_out is not readable; .closed never escapes resolve.
                else => syscall_result = errCode(e.EBADF),
            }
        },

        // ------------------------------------------------------------------ //
        // exit_process(status: u8) noreturn                                  //
        //   arg1 = exit status (reserved; future wait/waitpid API)           //
        // ------------------------------------------------------------------ //
        .exit_process => {
            const status: u8 = @truncate(syscall_frame.arg(.one));
            const current_task: innigkeit.Task.Current = .get();
            const thread: *innigkeit.user.Thread = .from(current_task.task);
            thread.process.exit_status = status;

            // TODO: For multi-core: send IPIs to CPUs running sibling threads
            //       and force-terminate them before deallocating process state.
            //       For now we terminate the calling thread; process cleanup
            //       runs automatically when the reference count reaches zero.
            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            scheduler_handle.terminate();
            unreachable;
        },

        // ------------------------------------------------------------------ //
        // yield() void                                                       //
        // ------------------------------------------------------------------ //
        .yield => {
            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            scheduler_handle.yield();
            scheduler_handle.unlock();
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
                syscall_result = errCode(e.EINVAL);
                return syscall_result;
            }

            const vaddr: innigkeit.VirtualAddress = .from(entry_ptr);
            if (vaddr.getType() != .user) {
                syscall_result = errCode(e.EFAULT);
                return syscall_result;
            }
            const entry_point = vaddr.toUser();

            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);

            const new_thread = process.createThread(.{
                .entry = .prepare(spawnThreadEntry, .{ entry_point, user_arg }),
            }) catch {
                syscall_result = errCode(e.ENOMEM);
                return syscall_result;
            };

            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            defer scheduler_handle.unlock();
            scheduler_handle.queueTask(&new_thread.task, .{ .initial = true });

            syscall_result = 0;
        },

        // ------------------------------------------------------------------ //
        // cap_invoke(handle: u32, op: u64, arg: usize) -> usize|error        //
        //   Invoke a capability-specific operation.                          //
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
                syscall_result = errCode(e.EBADF);
                return syscall_result;
            };
            cap_table.lock.unlock();
            defer innigkeit.capabilities.CapabilityTable.unrefObject(slot_info.cap_type, slot_info.ptr);

            switch (slot_info.cap_type) {
                .null => unreachable,

                .notify => {
                    const notify: *innigkeit.capabilities.Notify = @ptrCast(@alignCast(slot_info.ptr));
                    const notify_op = std.enums.fromInt(innigkeit.capabilities.Notify.Op, op) orelse {
                        syscall_result = errCode(e.EINVAL);
                        return syscall_result;
                    };
                    switch (notify_op) {
                        .signal => {
                            if (!slot_info.rights.write) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            notify.signal(arg3);
                            syscall_result = 0;
                        },
                        .wait => {
                            if (!slot_info.rights.read) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            syscall_result = notify.wait(arg3);
                        },
                        .poll => {
                            if (!slot_info.rights.read) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            syscall_result = notify.poll(arg3);
                        },
                    }
                },

                .reply => {
                    const reply_cap: *innigkeit.capabilities.Reply = @ptrCast(@alignCast(slot_info.ptr));
                    const reply_op = std.enums.fromInt(innigkeit.capabilities.Reply.Op, op) orelse {
                        syscall_result = errCode(e.EINVAL);
                        return syscall_result;
                    };
                    switch (reply_op) {
                        .send => {
                            if (!slot_info.rights.write) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            const msg = validate.readUser(innigkeit.capabilities.Message, arg3) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            reply_cap.send(msg) catch {
                                syscall_result = errCode(e.EINVAL); // already replied
                                return syscall_result;
                            };
                            syscall_result = 0;
                        },
                    }
                },

                .endpoint => {
                    const endpoint: *innigkeit.capabilities.Endpoint = @ptrCast(@alignCast(slot_info.ptr));
                    const ep_op = std.enums.fromInt(innigkeit.capabilities.Endpoint.Op, op) orelse {
                        syscall_result = errCode(e.EINVAL);
                        return syscall_result;
                    };
                    switch (ep_op) {
                        .send => {
                            if (!slot_info.rights.write) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            // Copy message out of user memory before blocking.
                            const msg = validate.readUser(innigkeit.capabilities.Message, arg3) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            endpoint.send(msg);
                            syscall_result = 0;
                        },
                        .recv => {
                            if (!slot_info.rights.read) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            // Validate before blocking so a bad buffer faults without consuming a message.
                            if (!validateUserBuffer(arg3, @sizeOf(innigkeit.capabilities.Message))) {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            }
                            // Block first, then copy into user memory.
                            const msg = endpoint.recv();
                            validate.writeUser(arg3, msg) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            syscall_result = 0;
                        },
                        .call => {
                            if (!slot_info.rights.write) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            // arg3 = pointer to Message (in: request, out: reply).
                            // Copy the request out before blocking; copy the
                            // reply back after unblocking.
                            const request = validate.readUser(innigkeit.capabilities.Message, arg3) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            const reply = endpoint.call(request);
                            validate.writeUser(arg3, reply) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            syscall_result = 0;
                        },
                        .reply => {
                            if (!slot_info.rights.write) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            const msg = validate.readUser(innigkeit.capabilities.Message, arg3) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            endpoint.reply(msg) catch {
                                syscall_result = errCode(e.EINVAL); // no pending sender
                                return syscall_result;
                            };
                            syscall_result = 0;
                        },
                        .reply_recv => {
                            if (!slot_info.rights.read or !slot_info.rights.write) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            // arg3 = pointer to Message (in: reply to send, out: next request).
                            // Copy the reply out before blocking; copy the
                            // next request back after unblocking.
                            const reply_msg = validate.readUser(innigkeit.capabilities.Message, arg3) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            const next_request = endpoint.replyRecv(reply_msg);
                            validate.writeUser(arg3, next_request) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            syscall_result = 0;
                        },
                        .recv_call => {
                            if (!slot_info.rights.read) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            // Validate before blocking so a bad buffer faults without consuming a message.
                            if (!validateUserBuffer(arg3, @sizeOf(innigkeit.capabilities.Message))) {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            }
                            // Block until a message arrives.
                            const result = endpoint.recvCall();
                            // Copy message to user memory.
                            validate.writeUser(arg3, result.msg) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            // If the sender used call(), create a Reply cap for them.
                            if (result.sender) |sender_task| {
                                const reply_cap = innigkeit.capabilities.Reply.create(sender_task) catch {
                                    sender_task.ipc_message = .{};
                                    sender_task.wakeFromBlocked();
                                    syscall_result = errCode(e.ENOMEM);
                                    return syscall_result;
                                };
                                const idx = blk: {
                                    const tbl = Process.from(current_task.task).cap_table;
                                    tbl.lock.lock();
                                    const i = tbl.insertLocked(.reply, reply_cap, .{ .write = true }) catch {
                                        tbl.lock.unlock();
                                        reply_cap.unref(); // wakes sender with empty reply
                                        syscall_result = errCode(e.ENOMEM);
                                        return syscall_result;
                                    };
                                    tbl.lock.unlock();
                                    break :blk i;
                                };
                                syscall_result = @intCast(idx);
                            } else {
                                syscall_result = @intCast(innigkeit.config.capabilities.null_slot);
                            }
                        },
                    }
                },

                .secure_vault => {
                    const vault: *innigkeit.capabilities.SecureVault = @ptrCast(@alignCast(slot_info.ptr));
                    const vault_op = std.enums.fromInt(innigkeit.capabilities.SecureVault.Op, op) orelse {
                        syscall_result = errCode(e.EINVAL);
                        return syscall_result;
                    };
                    switch (vault_op) {
                        .status => {
                            syscall_result = if (vault.tpm_backed) 1 else 0;
                        },
                        .seal => {
                            // arg.one=handle, arg.two=op, arg.three=src_ptr,
                            // arg.four=src_len, arg.five=dst_ptr, arg.six=dst_len
                            const src_ptr: usize = syscall_frame.arg(.three);
                            const src_len: usize = syscall_frame.arg(.four);
                            const dst_ptr: usize = syscall_frame.arg(.five);
                            const dst_len: usize = syscall_frame.arg(.six);
                            // The vault streams directly from/to the user buffers, so keep one explicit access window.
                            const plaintext = validate.userSliceConst(src_ptr, src_len) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            const out = validate.userSlice(dst_ptr, dst_len) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            const access: validate.UserAccess = .acquire();
                            defer access.release();
                            const written = vault.seal(plaintext, out) catch |err| {
                                syscall_result = switch (err) {
                                    error.TooBig => errCode(e.EINVAL),
                                    error.BufferTooSmall => errCode(e.EINVAL),
                                };
                                return syscall_result;
                            };
                            syscall_result = @intCast(written);
                        },
                        .unseal => {
                            // arg.one=handle, arg.two=op, arg.three=src_ptr,
                            // arg.four=src_len, arg.five=dst_ptr, arg.six=dst_len
                            const src_ptr: usize = syscall_frame.arg(.three);
                            const src_len: usize = syscall_frame.arg(.four);
                            const dst_ptr: usize = syscall_frame.arg(.five);
                            const dst_len: usize = syscall_frame.arg(.six);
                            // The vault streams directly from/to the user
                            // buffers, so keep one explicit access window.
                            const blob = validate.userSliceConst(src_ptr, src_len) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            const out = validate.userSlice(dst_ptr, dst_len) catch {
                                syscall_result = errCode(e.EFAULT);
                                return syscall_result;
                            };
                            const access: validate.UserAccess = .acquire();
                            defer access.release();
                            const written = vault.unseal(blob, out) catch |err| {
                                syscall_result = switch (err) {
                                    error.TooSmall => errCode(e.EINVAL),
                                    error.BufferTooSmall => errCode(e.EINVAL),
                                    error.AuthFailed => errCode(e.EPERM),
                                };
                                return syscall_result;
                            };
                            syscall_result = @intCast(written);
                        },
                    }
                },

                .gpu_buffer => {
                    const gpu: *innigkeit.capabilities.GpuBuffer = @ptrCast(@alignCast(slot_info.ptr));
                    const gpu_op = std.enums.fromInt(innigkeit.capabilities.GpuBuffer.Op, op) orelse {
                        syscall_result = errCode(e.EINVAL);
                        return syscall_result;
                    };
                    switch (gpu_op) {
                        .phys_addr => syscall_result = gpu.phys_base.value,
                        .size => syscall_result = gpu.size_bytes,
                        .usage => syscall_result = @as(u32, @bitCast(gpu.usage)),
                    }
                },

                .frame => {
                    const frame: *innigkeit.capabilities.Frame = @ptrCast(@alignCast(slot_info.ptr));
                    const frame_op = std.enums.fromInt(innigkeit.capabilities.Frame.Op, op) orelse {
                        syscall_result = errCode(e.EINVAL);
                        return syscall_result;
                    };
                    switch (frame_op) {
                        .clone => {
                            if (!slot_info.rights.grant) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            // Bump refcount before inserting the new slot.
                            frame.ref();
                            cap_table.lock.lock();
                            defer cap_table.lock.unlock();
                            const new_idx = cap_table.insertLocked(
                                .frame,
                                frame,
                                slot_info.rights,
                            ) catch {
                                frame.unref();
                                syscall_result = errCode(e.ENOMEM); // table full
                                return syscall_result;
                            };
                            syscall_result = @intCast(new_idx);
                        },
                        .phys_addr => {
                            if (!slot_info.rights.read) {
                                syscall_result = errCode(e.EPERM);
                                return syscall_result;
                            }
                            syscall_result = frame.physicalAddress().value;
                        },
                    }
                },
            }
        },

        // ------------------------------------------------------------------ //
        // cap_copy(handle: u32, rights: u16) -> new_handle|error             //
        // ------------------------------------------------------------------ //
        .cap_copy => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));
            const rights_raw: u16 = @truncate(syscall_frame.arg(.two));
            const new_rights: innigkeit.capabilities.Rights = @bitCast(rights_raw);

            const process = Process.from(innigkeit.Task.Current.get().task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            defer cap_table.lock.unlock();
            const new_idx = cap_table.copyLocked(handle, new_rights) catch |err| {
                syscall_result = switch (err) {
                    error.NotFound => errCode(e.EBADF),
                    error.Full => errCode(e.ENOMEM),
                    error.RightsEscalation => errCode(e.EPERM),
                };
                return syscall_result;
            };
            syscall_result = @intCast(new_idx);
        },

        // ------------------------------------------------------------------ //
        // cap_move(handle: u32) -> new_handle|error                          //
        //   Moves the capability to a new slot and invalidates the old one.  //
        // ------------------------------------------------------------------ //
        .cap_move => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));

            const process = Process.from(innigkeit.Task.Current.get().task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            defer cap_table.lock.unlock();

            const slot = cap_table.getLocked(handle) orelse {
                syscall_result = errCode(e.EBADF);
                return syscall_result;
            };
            const current_rights = slot.rights;

            // Copy to a new slot (bumps refcount to 2).
            // Note: the defer above handles unlock on all exit paths; do NOT unlock explicitly here.
            const new_idx = cap_table.copyLocked(handle, current_rights) catch |err| {
                syscall_result = switch (err) {
                    error.NotFound => errCode(e.EBADF),
                    error.Full => errCode(e.ENOMEM),
                    error.RightsEscalation => unreachable, // same rights
                };
                return syscall_result;
            };

            // Remove the original slot (decrements refcount back to 1).
            cap_table.removeLocked(handle) catch unreachable;

            syscall_result = @intCast(new_idx);
        },

        // ------------------------------------------------------------------ //
        // cap_delete(handle: u32) -> 0|error                                 //
        // ------------------------------------------------------------------ //
        .cap_delete => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));

            const process = Process.from(innigkeit.Task.Current.get().task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            defer cap_table.lock.unlock();
            cap_table.removeLocked(handle) catch {
                syscall_result = errCode(e.EBADF);
                return syscall_result;
            };
            syscall_result = 0;
        },

        // ------------------------------------------------------------------ //
        // cap_create(type: u8) -> handle|error                               //
        //   type 2 = Notify, type 3 = Endpoint                               //
        // ------------------------------------------------------------------ //
        .cap_create => {
            const type_raw: u8 = @truncate(syscall_frame.arg(.one));
            const cap_type = std.enums.fromInt(innigkeit.capabilities.ObjectType, type_raw) orelse {
                syscall_result = errCode(e.EINVAL);
                return syscall_result;
            };

            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);
            const cap_table = process.cap_table;

            switch (cap_type) {
                .null => {
                    syscall_result = errCode(e.EINVAL);
                },
                .notify => {
                    const notify = innigkeit.capabilities.Notify.create() catch {
                        syscall_result = errCode(e.ENOMEM);
                        return syscall_result;
                    };
                    cap_table.lock.lock();
                    defer cap_table.lock.unlock();
                    const idx = cap_table.insertLocked(.notify, notify, .all) catch {
                        notify.unref();
                        syscall_result = errCode(e.ENOMEM);
                        return syscall_result;
                    };
                    syscall_result = @intCast(idx);
                },
                .endpoint => {
                    const endpoint = innigkeit.capabilities.Endpoint.create() catch {
                        syscall_result = errCode(e.ENOMEM);
                        return syscall_result;
                    };
                    cap_table.lock.lock();
                    defer cap_table.lock.unlock();
                    const idx = cap_table.insertLocked(.endpoint, endpoint, .all) catch {
                        endpoint.unref();
                        syscall_result = errCode(e.ENOMEM);
                        return syscall_result;
                    };
                    syscall_result = @intCast(idx);
                },
                .frame => {
                    // Physical frame allocation requires a size; use cap_invoke on a Vmem capability.
                    const frame = innigkeit.capabilities.Frame.create() catch {
                        syscall_result = errCode(e.ENOMEM);
                        return syscall_result;
                    };
                    cap_table.lock.lock();
                    defer cap_table.lock.unlock();
                    const idx = cap_table.insertLocked(.frame, frame, .all) catch {
                        frame.unref();
                        syscall_result = errCode(e.ENOMEM);
                        return syscall_result;
                    };
                    syscall_result = @intCast(idx);
                },
                // Reply capabilities are created by the kernel (recv_call), not by userspace.
                .reply => syscall_result = errCode(e.EINVAL),
                .secure_vault => {
                    if (!checkEntitlement(current_task, "secure_vault")) {
                        syscall_result = errCode(e.EPERM);
                        return syscall_result;
                    }
                    // arg2: 0 = software-only, 1 = prefer TPM-backed.
                    // TPM-backed mode will be wired up once the TPM 2.0 CRB driver
                    // lands; for now always software-only.
                    _ = syscall_frame.arg(.two);
                    const vault = innigkeit.capabilities.SecureVault.create(null) catch {
                        syscall_result = errCode(e.ENOMEM);
                        return syscall_result;
                    };
                    cap_table.lock.lock();
                    defer cap_table.lock.unlock();
                    const idx = cap_table.insertLocked(.secure_vault, vault, .all) catch {
                        vault.unref();
                        syscall_result = errCode(e.ENOMEM);
                        return syscall_result;
                    };
                    syscall_result = @intCast(idx);
                },

                .gpu_buffer => {
                    if (!checkEntitlement(current_task, "gpu")) {
                        syscall_result = errCode(e.EPERM);
                        return syscall_result;
                    }
                    // arg2: page_count (must be >= 1)
                    // arg3: usage bitmask (GpuBuffer.Usage packed struct as u32)
                    const page_count: usize = syscall_frame.arg(.two);
                    const usage_raw: u32 = @truncate(syscall_frame.arg(.three));
                    if (page_count == 0) {
                        syscall_result = errCode(e.EINVAL);
                        return syscall_result;
                    }
                    const gpu = innigkeit.capabilities.GpuBuffer.create(
                        page_count,
                        @bitCast(usage_raw),
                    ) catch {
                        syscall_result = errCode(e.ENOMEM);
                        return syscall_result;
                    };
                    cap_table.lock.lock();
                    defer cap_table.lock.unlock();
                    const idx = cap_table.insertLocked(.gpu_buffer, gpu, .all) catch {
                        gpu.unref();
                        syscall_result = errCode(e.ENOMEM);
                        return syscall_result;
                    };
                    syscall_result = @intCast(idx);
                },
            }
        },

        // ------------------------------------------------------------------ //
        // mmap(size: usize, prot: u32) -> addr|error                         //
        //   Maps `size` bytes of anonymous zero-fill memory.                 //
        //   prot bits: 0=read, 1=write, 2=exec.                              //
        //   Size is rounded up to page granularity.                          //
        //   Returns the virtual base address on success.                     //
        // ------------------------------------------------------------------ //
        .mmap => {
            const size_bytes = syscall_frame.arg(.one);
            const prot_raw: u32 = @truncate(syscall_frame.arg(.two));

            if (size_bytes == 0) {
                syscall_result = errCode(e.EINVAL);
                return syscall_result;
            }

            const page_align = architecture.paging.standard_page_size_alignment;
            const page_size = page_align.toByteUnits();
            // Guard against integer overflow in alignment rounding.
            if (size_bytes > std.math.maxInt(usize) - (page_size - 1)) {
                syscall_result = errCode(e.EINVAL);
                return syscall_result;
            }
            const aligned_size = core.Size.from(size_bytes, .byte).alignForward(page_align);

            const protection: innigkeit.mem.MapType.Protection = .{
                .read = (prot_raw & 1) != 0,
                .write = (prot_raw & 2) != 0,
                .execute = (prot_raw & 4) != 0,
            };

            if (protection.equal(.none)) {
                syscall_result = errCode(e.EINVAL); // must have at least one permission
                return syscall_result;
            }

            if (protection.write and protection.execute) {
                syscall_result = errCode(e.EINVAL); // W^X: writable+executable disallowed
                return syscall_result;
            }

            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);

            const range = process.address_space.map(.{
                .size = aligned_size,
                .protection = protection,
                .type = .zero_fill,
            }) catch |err| {
                syscall_result = switch (err) {
                    error.OutOfMemory, error.RequestedRangeUnavailable => errCode(e.ENOMEM),
                    else => errCode(e.EINVAL),
                };
                return syscall_result;
            };

            syscall_result = range.address.value;
        },

        // ------------------------------------------------------------------ //
        // munmap(addr: usize, size: usize) -> 0|error                        //
        //   Unmaps the region [addr, addr+size).                             //
        //   addr and size must be page-aligned.                              //
        // ------------------------------------------------------------------ //
        .munmap => {
            const addr_raw = syscall_frame.arg(.one);
            const size_bytes = syscall_frame.arg(.two);

            if (size_bytes == 0 or addr_raw == 0) {
                syscall_result = errCode(e.EINVAL);
                return syscall_result;
            }

            const page_align = architecture.paging.standard_page_size_alignment;
            if (!page_align.check(addr_raw) or !page_align.check(size_bytes)) {
                syscall_result = errCode(e.EINVAL);
                return syscall_result;
            }

            const vaddr: innigkeit.VirtualAddress = .from(addr_raw);
            if (vaddr.getType() != .user) {
                syscall_result = errCode(e.EFAULT);
                return syscall_result;
            }

            const range: innigkeit.VirtualRange = .{
                .address = vaddr,
                .size = .from(size_bytes, .byte),
            };

            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);

            process.address_space.unmap(range) catch |err| {
                syscall_result = switch (err) {
                    error.OutOfMemory => errCode(e.ENOMEM),
                    error.RangeNotPageAligned => errCode(e.EINVAL),
                };
                return syscall_result;
            };

            syscall_result = 0;
        },

        // ------------------------------------------------------------------ //
        // futex_wait(addr: usize, expected: u32) -> 0|error                  //
        //   Block until *addr != expected or a matching futex_wake arrives.  //
        //   Returns 0 on wake or if the value already differed.              //
        // ------------------------------------------------------------------ //
        .futex_wait => {
            const addr = syscall_frame.arg(.one);
            const expected: u32 = @truncate(syscall_frame.arg(.two));

            if (!validateUserBuffer(addr, @sizeOf(u32))) {
                syscall_result = errCode(e.EFAULT);
                return syscall_result;
            }

            innigkeit.sync.futex.wait(addr, expected);
            syscall_result = 0;
        },

        // ------------------------------------------------------------------ //
        // futex_wait_timeout(addr: usize, expected: u32, deadline_ms: u64)   //
        //   -> 0|error                                                       //
        //   Block until *addr != expected, a matching futex_wake arrives, or //
        //   uptime_ms >= deadline_ms.                                        //
        // ------------------------------------------------------------------ //
        .futex_wait_timeout => {
            const addr = syscall_frame.arg(.one);
            const expected: u32 = @truncate(syscall_frame.arg(.two));
            const deadline_ms: u64 = syscall_frame.arg(.three);
            if (!validateUserBuffer(addr, @sizeOf(u32))) {
                syscall_result = errCode(e.EFAULT);
                return syscall_result;
            }
            innigkeit.sync.futex.waitTimeout(addr, expected, deadline_ms);
            syscall_result = 0;
        },

        // ------------------------------------------------------------------ //
        // futex_wake(addr: usize, max_wake: u32) -> woken_count|error        //
        //   Wake up to max_wake threads blocked on addr.                     //
        //   Returns the number of threads actually woken.                    //
        // ------------------------------------------------------------------ //
        .futex_wake => {
            const addr = syscall_frame.arg(.one);
            const max_wake: u32 = @truncate(syscall_frame.arg(.two));

            if (!validateUserBuffer(addr, @sizeOf(u32))) {
                syscall_result = errCode(e.EFAULT);
                return syscall_result;
            }

            const woken = innigkeit.sync.futex.wake(addr, max_wake);
            syscall_result = @intCast(woken);
        },

        // ------------------------------------------------------------------ //
        // spawn(spec_ptr: usize) -> notify_handle|error                      //
        //   Reads a SpawnSpec from user memory, loads the named ELF from     //
        //   initfs, creates a new process, and returns a Notify handle that  //
        //   is signalled when the child exits.                               //
        // ------------------------------------------------------------------ //
        .spawn => {
            const current_task: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task, "spawn")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            const spec_ptr = syscall_frame.arg(.one);
            syscall_result = handlers.spawn.syscallSpawn(spec_ptr, current_task);
        },

        // ------------------------------------------------------------------ //
        // wait_process(notify_handle: u32) -> 0|error                        //
        //   Blocks until the Notify at the given handle has bit 1 set.       //
        //   Convenience wrapper over cap_invoke(.notify, .wait, 1).          //
        // ------------------------------------------------------------------ //
        .wait_process => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));
            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            const slot_info = cap_table.getAndRefLocked(handle) orelse {
                cap_table.lock.unlock();
                syscall_result = errCode(e.EBADF);
                return syscall_result;
            };
            cap_table.lock.unlock();
            defer innigkeit.capabilities.CapabilityTable.unrefObject(slot_info.cap_type, slot_info.ptr);

            if (slot_info.cap_type != .notify) {
                syscall_result = errCode(e.EINVAL);
                return syscall_result;
            }
            if (!slot_info.rights.read) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }

            const notify: *innigkeit.capabilities.Notify = @ptrCast(@alignCast(slot_info.ptr));
            const bits = notify.wait(0xFF_01); // wait for bit 0 (exit), read bits 8..15 (status)
            const exit_status: u8 = @truncate(bits >> 8);
            syscall_result = exit_status;
        },

        // -------------------------------------------------------------------- //
        // cap_revoke(handle: u32) -> 0|error                                   //
        //   Increments the object's generation counter, instantly invalidating //
        //   every slot in every process that points to the same object.        //
        //   Requires .revoke rights on the calling slot.                       //
        // -------------------------------------------------------------------- //
        .cap_revoke => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));
            const process = Process.from(innigkeit.Task.Current.get().task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            defer cap_table.lock.unlock();

            cap_table.revokeLocked(handle) catch |err| {
                syscall_result = switch (err) {
                    error.NotFound => errCode(e.EBADF),
                    error.NoRevokeRight => errCode(e.EPERM),
                };
                return syscall_result;
            };
            syscall_result = 0;
        },

        // ------------------------------------------------------------------ //
        // vmem_map(handle: u32) -> addr|error                                //
        //   Maps the Frame at `handle` into the calling process's address    //
        //   space. Returns the virtual base address of the new mapping.      //
        // ------------------------------------------------------------------ //
        .vmem_map => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));
            const current_task: innigkeit.Task.Current = .get();
            syscall_result = handlers.vmem.syscallVmemMap(handle, current_task);
        },

        // ------------------------------------------------------------------ //
        // vmem_unmap(addr: usize, size: usize) -> 0|error                    //
        //   Unmaps the region [addr, addr+size) from the calling process.    //
        //   addr and size must be page-aligned.                              //
        // ------------------------------------------------------------------ //
        .vmem_unmap => {
            const addr_raw = syscall_frame.arg(.one);
            const size_bytes = syscall_frame.arg(.two);
            const current_task: innigkeit.Task.Current = .get();
            syscall_result = handlers.vmem.syscallVmemUnmap(addr_raw, size_bytes, current_task);
        },

        // ------------------------------------------------------------------ //
        // framebuffer_map(info_ptr: usize) -> va|error                       //
        //   Maps the bootloader framebuffer (write-combining) into the       //
        //   calling process's VA. Fills FramebufferInfo at info_ptr.         //
        //   Returns the virtual base address of the mapping.                 //
        // ------------------------------------------------------------------ //
        .framebuffer_map => {
            const current_task: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task, "framebuffer")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            const info_ptr = syscall_frame.arg(.one);
            syscall_result = handlers.framebuffer.syscallFramebufferMap(info_ptr, current_task);
        },

        // ------------------------------------------------------------------ //
        // initfs_read(spec_ptr: usize) -> bytes|error                        //
        //   spec_ptr -> InitfsReadSpec{name_ptr, name_len, buf_ptr, buf_len} //
        //   Read a file from the embedded initfs archive into a user buffer. //
        //   buf_len==0 returns the file size without copying (stat mode).    //
        // ------------------------------------------------------------------ //
        .initfs_read => {
            const spec_ptr = syscall_frame.arg(.one);
            const current_task: innigkeit.Task.Current = .get();
            syscall_result = handlers.framebuffer.syscallInitfsRead(spec_ptr, current_task);
        },

        // ------------------------------------------------------------------ //
        // uptime_ms() -> ms:usize                                            //
        //   Returns milliseconds elapsed since kernel boot.                  //
        // ------------------------------------------------------------------ //
        .uptime_ms => {
            syscall_result = handlers.framebuffer.syscallUptimeMs();
        },

        // ------------------------------------------------------------------------ //
        // blk_read(spec_ptr: usize) -> bytes|error                                 //
        //   spec_ptr -> BlkReadSpec{byte_offset:u64, buf_ptr:usize, buf_len:usize} //
        //   Reads bytes from the data disk (virtio-blk device 1).                  //
        // ------------------------------------------------------------------------ //
        .blk_read => {
            const spec_ptr = syscall_frame.arg(.one);
            const current_task: innigkeit.Task.Current = .get();
            syscall_result = handlers.framebuffer.syscallBlkRead(spec_ptr, current_task);
        },

        // ------------------------------------------------------------------ //
        // kbd_read(buf_ptr: usize, buf_len: usize) -> count                  //
        //   Non-blocking drain of raw PS/2 bytes (incl. 0xE0 prefix and      //
        //   break bit) into a user buffer. Returns 0 when no keys pending.   //
        // ------------------------------------------------------------------ //
        .kbd_read => {
            const current_task: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task, "keyboard")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            const buf_ptr = syscall_frame.arg(.one);
            const buf_len = syscall_frame.arg(.two);
            syscall_result = handlers.framebuffer.syscallKbdRead(buf_ptr, buf_len, current_task);
        },

        // ------------------------------------------------------------------ //
        // nanosleep_ms(deadline_ms: u64) -> 0                                //
        //   Block until uptime_ms >= deadline_ms. Returns immediately if     //
        //   the deadline is already past.                                    //
        // ------------------------------------------------------------------ //
        .nanosleep_ms => {
            const deadline_ms: u64 = syscall_frame.arg(.one);
            innigkeit.sync.nanosleep.wait(deadline_ms);
            syscall_result = 0;
        },

        // ------------------------------------------------------------------ //
        // getpid() -> pid:u64                                                //
        //   Returns a stable opaque identifier assigned at process creation. //
        //   This is a monotonic counter value, NOT a kernel pointer.         //
        // ------------------------------------------------------------------ //
        .getpid => {
            const current_task: innigkeit.Task.Current = .get();
            const thread: *innigkeit.user.Thread = innigkeit.user.Thread.from(current_task.task);
            syscall_result = thread.process.pid;
        },

        // ------------------------------------------------------------------ //
        // wait_process_nb(notify_handle: u32) -> exit_status:u8|error        //
        //   Non-blocking check: returns exit status if the process has       //
        //   exited, or -EAGAIN if it is still running.                       //
        // ------------------------------------------------------------------ //
        .wait_process_nb => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));
            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            const slot_info = cap_table.getAndRefLocked(handle) orelse {
                cap_table.lock.unlock();
                syscall_result = errCode(e.EBADF);
                return syscall_result;
            };
            cap_table.lock.unlock();
            defer innigkeit.capabilities.CapabilityTable.unrefObject(slot_info.cap_type, slot_info.ptr);

            if (slot_info.cap_type != .notify) {
                syscall_result = errCode(e.EINVAL);
                return syscall_result;
            }
            if (!slot_info.rights.read) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }

            const notify: *innigkeit.capabilities.Notify = @ptrCast(@alignCast(slot_info.ptr));
            const bits = notify.poll(0xFF_01); // non-blocking: check bits 0 (exit) and 8..15 (status)
            if (bits == 0) {
                // Nothing pending: process still running.
                syscall_result = errCode(e.EAGAIN);
                return syscall_result;
            }
            const exit_status: u8 = @truncate(bits >> 8);
            syscall_result = exit_status;
        },

        // ------------------------------------------------------------------- //
        // process_kill(notify_handle: u32) -> 0|error                         //
        //   Signals the exit Notify for the process associated with the given //
        //   handle, unblocking any waitProcess / wait_process_nb callers and  //
        //   reporting exit status 130 (SIGINT convention).                    //
        // ------------------------------------------------------------------- //
        .process_kill => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));
            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            const slot_info = cap_table.getAndRefLocked(handle) orelse {
                cap_table.lock.unlock();
                syscall_result = errCode(e.EBADF);
                return syscall_result;
            };
            cap_table.lock.unlock();
            defer innigkeit.capabilities.CapabilityTable.unrefObject(slot_info.cap_type, slot_info.ptr);

            if (slot_info.cap_type != .notify) {
                syscall_result = errCode(e.EINVAL);
                return syscall_result;
            }

            const notify: *innigkeit.capabilities.Notify = @ptrCast(@alignCast(slot_info.ptr));
            // Signal exit with status 130 (killed by Ctrl+C / SIGINT convention).
            // Bit 0 = exited, bits 8..15 = exit status.
            notify.signal(@as(u64, 1) | (@as(u64, 130) << 8));
            syscall_result = 0;
        },

        // ------------------------------------------------------------------------ //
        // blk_write(spec_ptr: usize) -> 0|error                                    //
        //   spec_ptr -> BlkReadSpec{byte_offset:u64, buf_ptr:usize, buf_len:usize} //
        //   Writes sector-aligned bytes to the data disk (virtio-blk device 1).    //
        //   Offset and length must be multiples of 512 (sector size).              //
        // ------------------------------------------------------------------------ //
        .blk_write => {
            const current_task: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task, "storage")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            const spec_ptr = syscall_frame.arg(.one);
            syscall_result = handlers.framebuffer.syscallBlkWrite(spec_ptr, current_task);
        },

        // ------------------------------------------------------------------ //
        // fs_open(name_ptr, name_len, flags) -> fd|error                     //
        //   Open or create a file on the simple flat filesystem.             //
        // ------------------------------------------------------------------ //
        .fs_open => {
            const name_ptr = syscall_frame.arg(.one);
            const name_len = syscall_frame.arg(.two);
            const flags_raw = syscall_frame.arg(.three);
            const current_task: innigkeit.Task.Current = .get();
            syscall_result = handlers.fs_handler.syscallFsOpen(name_ptr, name_len, flags_raw, current_task);
        },

        // ------------------------------------------------------------------ //
        // fs_read(fd, buf_ptr, buf_len) -> nbytes|error                      //
        // ------------------------------------------------------------------ //
        .fs_read => {
            const fd = syscall_frame.arg(.one);
            const buf_ptr = syscall_frame.arg(.two);
            const buf_len = syscall_frame.arg(.three);
            const current_task: innigkeit.Task.Current = .get();
            syscall_result = handlers.fs_handler.syscallFsRead(fd, buf_ptr, buf_len, current_task);
        },

        // ------------------------------------------------------------------ //
        // fs_write(fd, buf_ptr, buf_len) -> nbytes|error                     //
        // ------------------------------------------------------------------ //
        .fs_write => {
            const fd = syscall_frame.arg(.one);
            const buf_ptr = syscall_frame.arg(.two);
            const buf_len = syscall_frame.arg(.three);
            const current_task: innigkeit.Task.Current = .get();
            syscall_result = handlers.fs_handler.syscallFsWrite(fd, buf_ptr, buf_len, current_task);
        },

        // ------------------------------------------------------------------ //
        // fs_close(fd) -> 0|error                                            //
        // ------------------------------------------------------------------ //
        .fs_close => {
            const fd = syscall_frame.arg(.one);
            const current_task: innigkeit.Task.Current = .get();
            syscall_result = handlers.fs_handler.syscallFsClose(fd, current_task);
        },

        // ------------------------------------------------------------------ //
        // thread_set_hint(hint: u8) -> 0                                     //
        //   Set the P/E-core scheduling hint for the calling thread.         //
        //   hint: 0=unknown, 1=p_core, 2=e_core (maps to Executor.CoreType). //
        // ------------------------------------------------------------------ //
        .thread_set_hint => {
            const raw: u8 = @truncate(syscall_frame.arg(.one));
            const current_task: innigkeit.Task.Current = .get();
            current_task.task.core_hint = switch (raw) {
                1 => innigkeit.Executor.CoreType.p_core,
                2 => innigkeit.Executor.CoreType.e_core,
                else => innigkeit.Executor.CoreType.unknown,
            };
            syscall_result = 0;
        },

        // ------------------------------------------------------------------ //
        // efi_var_get / efi_var_set: stubs, not yet implemented.             //
        // ------------------------------------------------------------------ //
        .efi_var_get, .efi_var_set => {
            syscall_result = errCode(e.ENOSYS);
        },

        // ------------------------------------------------------------------ //
        // blk_disk_size(dev_idx: u32) -> sectors:u64|error                   //
        //   Returns the capacity (in 512-byte sectors) of virtio-blk device  //
        //   dev_idx. Returns ENODEV if no such device exists.                //
        // ------------------------------------------------------------------ //
        .blk_disk_size => {
            const dev_idx: usize = syscall_frame.arg(.one);
            if (innigkeit.drivers.virtio.blk.diskSectorCount(dev_idx)) |sectors| {
                syscall_result = @intCast(sectors);
            } else {
                syscall_result = errCode(e.ENODEV);
            }
        },

        // ------------------------------------------------------------------ //
        // mouse_read(buf_ptr: usize, buf_len: usize) -> count                //
        //   Non-blocking drain of decoded PS/2 mouse events into a user      //
        //   buffer.  buf_len is event count; returns events written.         //
        // ------------------------------------------------------------------ //
        .mouse_read => {
            const current_task: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task, "mouse")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            const buf_ptr = syscall_frame.arg(.one);
            const buf_len = syscall_frame.arg(.two);
            syscall_result = handlers.framebuffer.syscallMouseRead(buf_ptr, buf_len, current_task);
        },

        // ------------------------------------------------------------------ //
        // gpu_flush(w: u32, h: u32) -> 0                                     //
        //   Flush the virtio-gpu backing store to the host display.          //
        //   No-op (returns 0) if virtio-gpu is not initialized.              //
        // ------------------------------------------------------------------ //
        .gpu_flush => {
            const w: u32 = @truncate(syscall_frame.arg(.one));
            const h: u32 = @truncate(syscall_frame.arg(.two));
            innigkeit.drivers.virtio.gpu.flush(w, h) catch {};
            syscall_result = 0;
        },

        // ------------------------------------------------------------------ //
        // net_set_ip(ip: u32) -> 0                                           //
        //   Set NIC IPv4 address.  ip is packed big-endian.                  //
        // ------------------------------------------------------------------ //
        .net_set_ip => {
            const current_task: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            syscall_result = handlers.net.syscallNetSetIp(syscall_frame.arg(.one));
        },

        // ------------------------------------------------------------------ //
        // net_get_mac(buf_ptr: usize) -> 0|ENODEV                            //
        // ------------------------------------------------------------------ //
        .net_get_mac => {
            const current_task: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            syscall_result = handlers.net.syscallNetGetMac(syscall_frame.arg(.one), current_task);
        },

        // ------------------------------------------------------------------ //
        // net_udp_open(port: u16) -> sock_id|err                             //
        // ------------------------------------------------------------------ //
        .net_udp_open => {
            const current_task: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            syscall_result = handlers.net.syscallNetUdpOpen(syscall_frame.arg(.one));
        },

        // ------------------------------------------------------------------ //
        // net_udp_send(sock, dst_ip, dst_port, buf_ptr, buf_len) -> 0|err    //
        // ------------------------------------------------------------------ //
        .net_udp_send => {
            const current_task_net_send: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task_net_send, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            syscall_result = handlers.net.syscallNetUdpSend(
                syscall_frame.arg(.one),
                syscall_frame.arg(.two),
                syscall_frame.arg(.three),
                syscall_frame.arg(.four),
                syscall_frame.arg(.five),
                current_task_net_send,
            );
        },

        // ------------------------------------------------------------------ //
        // net_udp_recv(sock, from_ptr, buf_ptr, buf_len) -> bytes|EAGAIN|err //
        // ------------------------------------------------------------------ //
        .net_udp_recv => {
            const current_task_net_recv: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task_net_recv, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            syscall_result = handlers.net.syscallNetUdpRecv(
                syscall_frame.arg(.one),
                syscall_frame.arg(.two),
                syscall_frame.arg(.three),
                syscall_frame.arg(.four),
                current_task_net_recv,
            );
        },

        // ------------------------------------------------------------------ //
        // net_udp_recv_nb(sock, from_ptr, buf_ptr, buf_len)                  //
        //   -> bytes | EWOULDBLOCK (never blocks)                            //
        // ------------------------------------------------------------------ //
        .net_udp_recv_nb => {
            const current_task_net_recv_nb: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task_net_recv_nb, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            syscall_result = handlers.net.syscallNetUdpRecvNb(
                syscall_frame.arg(.one),
                syscall_frame.arg(.two),
                syscall_frame.arg(.three),
                syscall_frame.arg(.four),
            );
        },

        // ------------------------------------------------------------------ //
        // net_udp_close(sock_id: u32) -> 0                                   //
        // ------------------------------------------------------------------ //
        .net_udp_close => {
            const current_task_net_close: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task_net_close, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            syscall_result = handlers.net.syscallNetUdpClose(syscall_frame.arg(.one));
        },

        // ------------------------------------------------------------------ //
        // net_ping(dst_ip: u32, timeout_ms: u32) -> rtt_ms|ENODEV           //
        // ------------------------------------------------------------------ //
        .net_ping => {
            const current_task_net_ping: innigkeit.Task.Current = .get();
            if (!checkEntitlement(current_task_net_ping, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            syscall_result = handlers.net.syscallNetPing(
                syscall_frame.arg(.one),
                syscall_frame.arg(.two),
            );
        },

        // ------------------------------------------------------------------ //
        // net_tcp_listen(port: u16) -> sock_id|err                           //
        // ------------------------------------------------------------------ //
        .net_tcp_listen => {
            const task_tcp_listen: innigkeit.Task.Current = .get();
            if (!checkEntitlement(task_tcp_listen, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            const port: u16 = @truncate(syscall_frame.arg(.one));
            const id = innigkeit.net.socket.openTcpListener(port) orelse {
                syscall_result = errCode(e.ENOMEM);
                return syscall_result;
            };
            syscall_result = id;
        },

        // ------------------------------------------------------------------ //
        // net_tcp_accept(listener_id: u8) -> sock_id|EAGAIN|err              //
        // ------------------------------------------------------------------ //
        .net_tcp_accept => {
            const task_tcp_accept: innigkeit.Task.Current = .get();
            if (!checkEntitlement(task_tcp_accept, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            const lid: u8 = @truncate(syscall_frame.arg(.one));
            const id = innigkeit.net.socket.tcpAccept(lid) orelse {
                syscall_result = errCode(e.EAGAIN);
                return syscall_result;
            };
            syscall_result = id;
        },

        // ------------------------------------------------------------------ //
        // net_tcp_connect(dst_ip: u32, dst_port: u16, src_port: u16)         //
        //   -> sock_id|err                                                    //
        // ------------------------------------------------------------------ //
        .net_tcp_connect => {
            const task_tcp_connect: innigkeit.Task.Current = .get();
            if (!checkEntitlement(task_tcp_connect, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            const dst_ip_raw: u32 = @truncate(syscall_frame.arg(.one));
            const dst_port: u16 = @truncate(syscall_frame.arg(.two));
            const src_port: u16 = @truncate(syscall_frame.arg(.three));
            const dst_ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, dst_ip_raw));
            const id = innigkeit.net.socket.openTcpConnect(src_port, dst_ip, dst_port) orelse {
                syscall_result = errCode(e.ENOMEM);
                return syscall_result;
            };
            // Block until ESTABLISHED (or fail).
            if (!innigkeit.net.socket.tcpWaitConnected(id)) {
                innigkeit.net.socket.closeTcp(id);
                syscall_result = errCode(e.ENODEV);
                return syscall_result;
            }
            syscall_result = id;
        },

        // ------------------------------------------------------------------ //
        // net_tcp_send(sock_id, buf_ptr, buf_len) -> bytes|err               //
        // ------------------------------------------------------------------ //
        .net_tcp_send => {
            const task_tcp_send: innigkeit.Task.Current = .get();
            if (!checkEntitlement(task_tcp_send, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            const sock_id_s: u8 = @truncate(syscall_frame.arg(.one));
            const buf_ptr = syscall_frame.arg(.two);
            const buf_len = syscall_frame.arg(.three);
            // tcpSend consumes the user buffer directly; keep one explicit
            // access window around the streaming send.
            const buf_send = validate.userSliceConst(buf_ptr, buf_len) catch {
                syscall_result = errCode(e.EFAULT);
                return syscall_result;
            };
            const access: validate.UserAccess = .acquire();
            defer access.release();
            const sent = innigkeit.net.socket.tcpSend(sock_id_s, buf_send);
            syscall_result = sent;
        },

        // ------------------------------------------------------------------ //
        // net_tcp_recv(sock_id, buf_ptr, buf_len) -> bytes|EAGAIN            //
        // ------------------------------------------------------------------ //
        .net_tcp_recv => {
            const task_tcp_recv: innigkeit.Task.Current = .get();
            if (!checkEntitlement(task_tcp_recv, "network")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            const sock_id_r: u8 = @truncate(syscall_frame.arg(.one));
            const buf_ptr = syscall_frame.arg(.two);
            const buf_len = syscall_frame.arg(.three);
            // tcpRecv fills the user buffer directly; keep one explicit
            // access window around the streaming receive.
            const buf_recv = validate.userSlice(buf_ptr, buf_len) catch {
                syscall_result = errCode(e.EFAULT);
                return syscall_result;
            };
            const access: validate.UserAccess = .acquire();
            defer access.release();
            const n = innigkeit.net.socket.tcpRecv(sock_id_r, buf_recv);
            if (n == 0) {
                syscall_result = errCode(e.EAGAIN);
            } else {
                syscall_result = n;
            }
        },

        // ------------------------------------------------------------------ //
        // net_tcp_close(sock_id: u32) -> 0                                   //
        // ------------------------------------------------------------------ //
        .net_tcp_close => {
            const sock_id_c: u8 = @truncate(syscall_frame.arg(.one));
            innigkeit.net.socket.closeTcp(sock_id_c);
            syscall_result = 0;
        },

        // ------------------------------------------------------------------ //
        // open(path_ptr: usize, path_len: usize, flags: u32) -> fd|error     //
        //   Opens a VFS file into the per-process fd table.                  //
        //   flags bit 0 = open for writing (creates the file; requires the   //
        //   storage entitlement).                                            //
        // ------------------------------------------------------------------ //
        .open => {
            const current_task: innigkeit.Task.Current = .get();
            const flags: u32 = @truncate(syscall_frame.arg(.three));
            if (flags & 1 != 0 and !checkEntitlement(current_task, "storage")) {
                syscall_result = errCode(e.EPERM);
                return syscall_result;
            }
            syscall_result = handlers.file.syscallOpen(
                syscall_frame.arg(.one),
                syscall_frame.arg(.two),
                syscall_frame.arg(.three),
                current_task,
            );
        },

        // ------------------------------------------------------------------ //
        // close(fd: usize) -> 0|error                                        //
        // ------------------------------------------------------------------ //
        .close => {
            const current_task: innigkeit.Task.Current = .get();
            syscall_result = handlers.file.syscallClose(syscall_frame.arg(.one), current_task);
        },

        // ------------------------------------------------------------------ //
        // lseek(fd: usize, offset: i64, whence: u32) -> new_offset|error     //
        //   whence: 0 = SET, 1 = CUR, 2 = END.                               //
        // ------------------------------------------------------------------ //
        .lseek => {
            const current_task: innigkeit.Task.Current = .get();
            syscall_result = handlers.file.syscallLseek(
                syscall_frame.arg(.one),
                syscall_frame.arg(.two),
                syscall_frame.arg(.three),
                current_task,
            );
        },

        // ------------------------------------------------------------------ //
        // fstat(fd: usize, stat_ptr: usize) -> 0|error                       //
        //   Fills Stat{size: u64, kind: u8} at stat_ptr.                     //
        //   kind: 0 = file, 1 = directory, 2 = tty.                          //
        // ------------------------------------------------------------------ //
        .fstat => {
            const current_task: innigkeit.Task.Current = .get();
            syscall_result = handlers.file.syscallFstat(
                syscall_frame.arg(.one),
                syscall_frame.arg(.two),
                current_task,
            );
        },
    }

    return syscall_result;
}

/// Kernel-side entry for threads spawned via the spawn_thread syscall.
/// Runs in the new thread's context; calls `Thread.start` to enter userspace.
fn spawnThreadEntry(entry_point: innigkeit.UserVirtualAddress, arg: usize) !noreturn {
    const current_task: innigkeit.Task.Current = .get();
    const thread: *Thread = .from(current_task.task);
    try thread.start(entry_point, arg);
    unreachable;
}

pub const init = struct {
    pub fn initialize() !void {
        try Process.init.initializeProcesses();
        try Thread.init.initializeThreads();
        try architecture.user.init.initialize();
    }
};

/// Returns true if the calling process holds the given entitlement.
/// In non-enforcing mode always returns true so the syscall proceeds normally.
inline fn checkEntitlement(task: innigkeit.Task.Current, comptime field: []const u8) bool {
    if (!innigkeit.config.security.enforce_entitlements) return true;
    const process = Process.from(task.task);
    return @field(process.entitlements, field);
}

/// Cast a signed error code to the bit pattern expected in rax / a0 / x0.
inline fn errCode(code: i64) usize {
    return @bitCast(code);
}

/// Negated POSIX errno values used as syscall return codes.
const e = struct {
    const EPERM: i64 = -1;
    const EIO: i64 = -5;
    const EBADF: i64 = -9;
    const EAGAIN: i64 = -11;
    const ENOMEM: i64 = -12;
    const EFAULT: i64 = -14;
    const ENODEV: i64 = -19;
    const EINVAL: i64 = -22;
    const ENOSYS: i64 = -38;
};
