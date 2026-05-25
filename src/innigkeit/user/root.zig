const std = @import("std");

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const elf = @import("elf/root.zig");
pub const Process = @import("Process.zig");
pub const Thread = @import("Thread.zig");
pub const handlers = @import("handlers/root.zig");

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
        log.warn("invalid syscall from usersapce\n{f}", .{syscall_frame});
        syscall_frame.arch_specific.rax = errCode(e.ENOSYS);
        return;
    };

    log.verbose("received syscall: {t}", .{syscall});

    const arch_frame = syscall_frame.arch_specific;

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
        //   arg1 = fd   (0=stdin, 1=stdout, 2=stderr)                        //
        //   arg2 = buf  (pointer into user address space)                    //
        //   arg3 = len  (byte count)                                         //
        //   return: bytes written, or negative error code                    //
        // ------------------------------------------------------------------ //
        .write => {
            const fd = @as(i32, @intCast(syscall_frame.arg(.one)));
            const buf_ptr = syscall_frame.arg(.two);
            const buf_len = syscall_frame.arg(.three);

            if (fd != 1 and fd != 2) {
                arch_frame.rax = errCode(e.EBADF);
                return;
            }

            if (buf_len == 0) {
                arch_frame.rax = 0;
                return;
            }

            if (!validateUserBuffer(buf_ptr, buf_len)) {
                arch_frame.rax = errCode(e.EFAULT);
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
                arch_frame.rax = errCode(e.EIO);
                return;
            };
            output.writer.flush() catch |err| {
                log.err("write flush: {t}", .{err});
                arch_frame.rax = errCode(e.EIO);
                return;
            };

            arch_frame.rax = @intCast(buf_len);
        },

        // ------------------------------------------------------------------ //
        // read(fd: usize, buf: [*]u8, len: usize) isize                      //
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
                arch_frame.rax = errCode(e.EBADF);
                return;
            }

            if (buf_len == 0) {
                arch_frame.rax = 0;
                return;
            }

            if (!validateUserBuffer(buf_ptr, buf_len)) {
                arch_frame.rax = errCode(e.EFAULT);
                return;
            }

            const current_task: innigkeit.Task.Current = .get();
            current_task.incrementEnableAccessToUserMemory();
            defer current_task.decrementEnableAccessToUserMemory();

            const buffer: []u8 = @as([*]u8, @ptrFromInt(buf_ptr))[0..buf_len];

            const bytes_read = innigkeit.drivers.input.ps2.keyboard_buffer.readLine(buffer);
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
                arch_frame.rax = errCode(e.EINVAL);
                return;
            }

            const vaddr: innigkeit.VirtualAddress = .from(entry_ptr);
            if (vaddr.getType() != .user) {
                arch_frame.rax = errCode(e.EFAULT);
                return;
            }
            const entry_point = vaddr.toUser();

            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);

            const new_thread = process.createThread(.{
                .entry = .prepare(spawnThreadEntry, .{ entry_point, user_arg }),
            }) catch {
                arch_frame.rax = errCode(e.ENOMEM);
                return;
            };

            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            defer scheduler_handle.unlock();
            scheduler_handle.queueTask(&new_thread.task, .{ .initial = true });

            arch_frame.rax = 0;
        },

        // ------------------------------------------------------------------ //
        // cap_invoke(handle: u32, op: u64, arg: usize) -> usize|error         //
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
                arch_frame.rax = errCode(e.EBADF);
                return;
            };
            cap_table.lock.unlock();
            defer innigkeit.capabilities.CapabilityTable.unrefObject(slot_info.cap_type, slot_info.ptr);

            switch (slot_info.cap_type) {
                .null => unreachable,

                .notify => {
                    const notify: *innigkeit.capabilities.Notify = @ptrCast(@alignCast(slot_info.ptr));
                    const notify_op = std.enums.fromInt(innigkeit.capabilities.Notify.Op, op) orelse {
                        arch_frame.rax = errCode(e.EINVAL);
                        return;
                    };
                    switch (notify_op) {
                        .signal => {
                            if (!slot_info.rights.write) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
                            }
                            notify.signal(arg3);
                            arch_frame.rax = 0;
                        },
                        .wait => {
                            if (!slot_info.rights.read) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
                            }
                            arch_frame.rax = notify.wait(arg3);
                        },
                        .poll => {
                            if (!slot_info.rights.read) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
                            }
                            arch_frame.rax = notify.poll(arg3);
                        },
                    }
                },

                .reply => {
                    const reply_cap: *innigkeit.capabilities.Reply = @ptrCast(@alignCast(slot_info.ptr));
                    const reply_op = std.enums.fromInt(innigkeit.capabilities.Reply.Op, op) orelse {
                        arch_frame.rax = errCode(e.EINVAL);
                        return;
                    };
                    switch (reply_op) {
                        .send => {
                            if (!slot_info.rights.write) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
                            }
                            if (!validateUserBuffer(arg3, @sizeOf(innigkeit.capabilities.Message))) {
                                arch_frame.rax = errCode(e.EFAULT);
                                return;
                            }
                            const msg_uptr: *const innigkeit.capabilities.Message = @ptrFromInt(arg3);
                            current_task.incrementEnableAccessToUserMemory();
                            const msg = msg_uptr.*;
                            current_task.decrementEnableAccessToUserMemory();
                            reply_cap.send(msg) catch {
                                arch_frame.rax = errCode(e.EINVAL); // already replied
                                return;
                            };
                            arch_frame.rax = 0;
                        },
                    }
                },

                .endpoint => {
                    const endpoint: *innigkeit.capabilities.Endpoint = @ptrCast(@alignCast(slot_info.ptr));
                    const ep_op = std.enums.fromInt(innigkeit.capabilities.Endpoint.Op, op) orelse {
                        arch_frame.rax = errCode(e.EINVAL);
                        return;
                    };
                    switch (ep_op) {
                        .send => {
                            if (!slot_info.rights.write) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
                            }
                            if (!validateUserBuffer(arg3, @sizeOf(innigkeit.capabilities.Message))) {
                                arch_frame.rax = errCode(e.EFAULT);
                                return;
                            }
                            // Copy message out of user memory before blocking.
                            const msg_uptr: *const innigkeit.capabilities.Message = @ptrFromInt(arg3);
                            current_task.incrementEnableAccessToUserMemory();
                            const msg = msg_uptr.*;
                            current_task.decrementEnableAccessToUserMemory();
                            endpoint.send(msg);
                            arch_frame.rax = 0;
                        },
                        .recv => {
                            if (!slot_info.rights.read) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
                            }
                            if (!validateUserBuffer(arg3, @sizeOf(innigkeit.capabilities.Message))) {
                                arch_frame.rax = errCode(e.EFAULT);
                                return;
                            }
                            // Block first, then copy into user memory.
                            const msg = endpoint.recv();
                            const msg_uptr: *innigkeit.capabilities.Message = @ptrFromInt(arg3);
                            current_task.incrementEnableAccessToUserMemory();
                            msg_uptr.* = msg;
                            current_task.decrementEnableAccessToUserMemory();
                            arch_frame.rax = 0;
                        },
                        .call => {
                            if (!slot_info.rights.write) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
                            }
                            // arg3 = pointer to Message (in: request, out: reply).
                            if (!validateUserBuffer(arg3, @sizeOf(innigkeit.capabilities.Message))) {
                                arch_frame.rax = errCode(e.EFAULT);
                                return;
                            }
                            const msg_uptr: *innigkeit.capabilities.Message = @ptrFromInt(arg3);
                            current_task.incrementEnableAccessToUserMemory();
                            const request = msg_uptr.*;
                            current_task.decrementEnableAccessToUserMemory();
                            const reply = endpoint.call(request);
                            current_task.incrementEnableAccessToUserMemory();
                            msg_uptr.* = reply;
                            current_task.decrementEnableAccessToUserMemory();
                            arch_frame.rax = 0;
                        },
                        .reply => {
                            if (!slot_info.rights.write) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
                            }
                            if (!validateUserBuffer(arg3, @sizeOf(innigkeit.capabilities.Message))) {
                                arch_frame.rax = errCode(e.EFAULT);
                                return;
                            }
                            const msg_uptr: *const innigkeit.capabilities.Message = @ptrFromInt(arg3);
                            current_task.incrementEnableAccessToUserMemory();
                            const msg = msg_uptr.*;
                            current_task.decrementEnableAccessToUserMemory();
                            endpoint.reply(msg) catch {
                                arch_frame.rax = errCode(e.EINVAL); // no pending sender
                                return;
                            };
                            arch_frame.rax = 0;
                        },
                        .reply_recv => {
                            if (!slot_info.rights.read or !slot_info.rights.write) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
                            }
                            // arg3 = pointer to Message (in: reply to send, out: next request).
                            if (!validateUserBuffer(arg3, @sizeOf(innigkeit.capabilities.Message))) {
                                arch_frame.rax = errCode(e.EFAULT);
                                return;
                            }
                            const msg_uptr: *innigkeit.capabilities.Message = @ptrFromInt(arg3);
                            current_task.incrementEnableAccessToUserMemory();
                            const reply_msg = msg_uptr.*;
                            current_task.decrementEnableAccessToUserMemory();
                            const next_request = endpoint.replyRecv(reply_msg);
                            current_task.incrementEnableAccessToUserMemory();
                            msg_uptr.* = next_request;
                            current_task.decrementEnableAccessToUserMemory();
                            arch_frame.rax = 0;
                        },
                        .recv_call => {
                            if (!slot_info.rights.read) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
                            }
                            if (!validateUserBuffer(arg3, @sizeOf(innigkeit.capabilities.Message))) {
                                arch_frame.rax = errCode(e.EFAULT);
                                return;
                            }
                            // Block until a message arrives.
                            const result = endpoint.recvCall();
                            // Copy message to user memory.
                            const msg_uptr: *innigkeit.capabilities.Message = @ptrFromInt(arg3);
                            current_task.incrementEnableAccessToUserMemory();
                            msg_uptr.* = result.msg;
                            current_task.decrementEnableAccessToUserMemory();
                            // If the sender used call(), create a Reply cap for them.
                            if (result.sender) |sender_task| {
                                const reply_cap = innigkeit.capabilities.Reply.create(sender_task) catch {
                                    sender_task.ipc_message = .{};
                                    sender_task.wakeFromBlocked();
                                    arch_frame.rax = errCode(e.ENOMEM);
                                    return;
                                };
                                const idx = blk: {
                                    const tbl = Process.from(current_task.task).cap_table;
                                    tbl.lock.lock();
                                    const i = tbl.insertLocked(.reply, reply_cap, .{ .write = true }) catch {
                                        tbl.lock.unlock();
                                        reply_cap.unref(); // wakes sender with empty reply
                                        arch_frame.rax = errCode(e.ENOMEM);
                                        return;
                                    };
                                    tbl.lock.unlock();
                                    break :blk i;
                                };
                                arch_frame.rax = @intCast(idx);
                            } else {
                                arch_frame.rax = @intCast(innigkeit.config.capabilities.null_slot);
                            }
                        },
                    }
                },

                .frame => {
                    const frame: *innigkeit.capabilities.Frame = @ptrCast(@alignCast(slot_info.ptr));
                    const frame_op = std.enums.fromInt(innigkeit.capabilities.Frame.Op, op) orelse {
                        arch_frame.rax = errCode(e.EINVAL);
                        return;
                    };
                    switch (frame_op) {
                        .clone => {
                            if (!slot_info.rights.grant) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
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
                                arch_frame.rax = errCode(e.ENOMEM); // table full
                                return;
                            };
                            arch_frame.rax = @intCast(new_idx);
                        },
                        .phys_addr => {
                            if (!slot_info.rights.read) {
                                arch_frame.rax = errCode(e.EPERM);
                                return;
                            }
                            arch_frame.rax = frame.physicalAddress().value;
                        },
                    }
                },
            }
        },

        // ------------------------------------------------------------------ //
        // cap_copy(handle: u32, rights: u16) -> new_handle|error              //
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
                arch_frame.rax = switch (err) {
                    error.NotFound => errCode(e.EBADF),
                    error.Full => errCode(e.ENOMEM),
                    error.RightsEscalation => errCode(e.EPERM),
                };
                return;
            };
            arch_frame.rax = @intCast(new_idx);
        },

        // ------------------------------------------------------------------ //
        // cap_move(handle: u32) -> new_handle|error                           //
        //   Moves the capability to a new slot and invalidates the old one.  //
        // ------------------------------------------------------------------ //
        .cap_move => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));

            const process = Process.from(innigkeit.Task.Current.get().task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            defer cap_table.lock.unlock();

            const slot = cap_table.getLocked(handle) orelse {
                arch_frame.rax = errCode(e.EBADF);
                return;
            };
            const current_rights = slot.rights;

            // Copy to a new slot (bumps refcount to 2).
            const new_idx = cap_table.copyLocked(handle, current_rights) catch |err| {
                cap_table.lock.unlock();
                arch_frame.rax = switch (err) {
                    error.NotFound => errCode(e.EBADF),
                    error.Full => errCode(e.ENOMEM),
                    error.RightsEscalation => unreachable, // same rights
                };
                return;
            };

            // Remove the original slot (decrements refcount back to 1).
            cap_table.removeLocked(handle) catch unreachable;

            arch_frame.rax = @intCast(new_idx);
        },

        // ------------------------------------------------------------------ //
        // cap_delete(handle: u32) -> 0|error                                  //
        // ------------------------------------------------------------------ //
        .cap_delete => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));

            const process = Process.from(innigkeit.Task.Current.get().task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            defer cap_table.lock.unlock();
            cap_table.removeLocked(handle) catch {
                arch_frame.rax = errCode(e.EBADF);
                return;
            };
            arch_frame.rax = 0;
        },

        // ------------------------------------------------------------------ //
        // cap_create(type: u8) -> handle|error                                //
        //   type 2 = Notify, type 3 = Endpoint                               //
        // ------------------------------------------------------------------ //
        .cap_create => {
            const type_raw: u8 = @truncate(syscall_frame.arg(.one));
            const cap_type = std.enums.fromInt(innigkeit.capabilities.ObjectType, type_raw) orelse {
                arch_frame.rax = errCode(e.EINVAL);
                return;
            };

            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);
            const cap_table = process.cap_table;

            switch (cap_type) {
                .null => {
                    arch_frame.rax = errCode(e.EINVAL);
                },
                .notify => {
                    const notify = innigkeit.capabilities.Notify.create() catch {
                        arch_frame.rax = errCode(e.ENOMEM);
                        return;
                    };
                    cap_table.lock.lock();
                    defer cap_table.lock.unlock();
                    const idx = cap_table.insertLocked(.notify, notify, .all) catch {
                        notify.unref();
                        arch_frame.rax = errCode(e.ENOMEM);
                        return;
                    };
                    arch_frame.rax = @intCast(idx);
                },
                .endpoint => {
                    const endpoint = innigkeit.capabilities.Endpoint.create() catch {
                        arch_frame.rax = errCode(e.ENOMEM);
                        return;
                    };
                    cap_table.lock.lock();
                    defer cap_table.lock.unlock();
                    const idx = cap_table.insertLocked(.endpoint, endpoint, .all) catch {
                        endpoint.unref();
                        arch_frame.rax = errCode(e.ENOMEM);
                        return;
                    };
                    arch_frame.rax = @intCast(idx);
                },
                .frame => {
                    // Physical frame allocation requires a size; use cap_invoke on a Vmem capability.
                    const frame = innigkeit.capabilities.Frame.create() catch {
                        arch_frame.rax = errCode(e.ENOMEM);
                        return;
                    };
                    cap_table.lock.lock();
                    defer cap_table.lock.unlock();
                    const idx = cap_table.insertLocked(.frame, frame, .all) catch {
                        frame.unref();
                        arch_frame.rax = errCode(e.ENOMEM);
                        return;
                    };
                    arch_frame.rax = @intCast(idx);
                },
                // Reply capabilities are created by the kernel (recv_call), not by userspace.
                .reply => arch_frame.rax = errCode(e.EINVAL),
            }
        },

        // ------------------------------------------------------------------ //
        // mmap(size: usize, prot: u32) -> addr|error                         //
        //   Maps `size` bytes of anonymous zero-fill memory.                 //
        //   prot bits: 0=read, 1=write, 2=exec.                             //
        //   Size is rounded up to page granularity.                          //
        //   Returns the virtual base address on success.                     //
        // ------------------------------------------------------------------ //
        .mmap => {
            const size_bytes = syscall_frame.arg(.one);
            const prot_raw: u32 = @truncate(syscall_frame.arg(.two));

            if (size_bytes == 0) {
                arch_frame.rax = errCode(e.EINVAL);
                return;
            }

            const page_align = architecture.paging.standard_page_size_alignment;
            const page_size = page_align.toByteUnits();
            // Guard against integer overflow in alignment rounding.
            if (size_bytes > std.math.maxInt(usize) - (page_size - 1)) {
                arch_frame.rax = errCode(e.EINVAL);
                return;
            }
            const aligned_size = core.Size.from(size_bytes, .byte).alignForward(page_align);

            const protection: innigkeit.mem.MapType.Protection = .{
                .read = (prot_raw & 1) != 0,
                .write = (prot_raw & 2) != 0,
                .execute = (prot_raw & 4) != 0,
            };

            if (protection.equal(.none)) {
                arch_frame.rax = errCode(e.EINVAL); // must have at least one permission
                return;
            }

            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);

            const range = process.address_space.map(.{
                .size = aligned_size,
                .protection = protection,
                .type = .zero_fill,
            }) catch |err| {
                arch_frame.rax = switch (err) {
                    error.OutOfMemory, error.RequestedRangeUnavailable => errCode(e.ENOMEM),
                    else => errCode(e.EINVAL),
                };
                return;
            };

            arch_frame.rax = range.address.value;
        },

        // ------------------------------------------------------------------ //
        // munmap(addr: usize, size: usize) -> 0|error                         //
        //   Unmaps the region [addr, addr+size).                             //
        //   addr and size must be page-aligned.                              //
        // ------------------------------------------------------------------ //
        .munmap => {
            const addr_raw = syscall_frame.arg(.one);
            const size_bytes = syscall_frame.arg(.two);

            if (size_bytes == 0 or addr_raw == 0) {
                arch_frame.rax = errCode(e.EINVAL);
                return;
            }

            const page_align = architecture.paging.standard_page_size_alignment;
            if (!page_align.check(addr_raw) or !page_align.check(size_bytes)) {
                arch_frame.rax = errCode(e.EINVAL);
                return;
            }

            const vaddr: innigkeit.VirtualAddress = .from(addr_raw);
            if (vaddr.getType() != .user) {
                arch_frame.rax = errCode(e.EFAULT);
                return;
            }

            const range: innigkeit.VirtualRange = .{
                .address = vaddr,
                .size = .from(size_bytes, .byte),
            };

            const current_task: innigkeit.Task.Current = .get();
            const process = Process.from(current_task.task);

            process.address_space.unmap(range) catch |err| {
                arch_frame.rax = switch (err) {
                    error.OutOfMemory => errCode(e.ENOMEM),
                    error.RangeNotPageAligned => errCode(e.EINVAL),
                };
                return;
            };

            arch_frame.rax = 0;
        },

        // ------------------------------------------------------------------ //
        // futex_wait(addr: usize, expected: u32) -> 0|error                   //
        //   Block until *addr != expected or a matching futex_wake arrives.  //
        //   Returns 0 on wake or if the value already differed.              //
        // ------------------------------------------------------------------ //
        .futex_wait => {
            const addr = syscall_frame.arg(.one);
            const expected: u32 = @truncate(syscall_frame.arg(.two));

            if (!validateUserBuffer(addr, @sizeOf(u32))) {
                arch_frame.rax = errCode(e.EFAULT);
                return;
            }

            innigkeit.sync.futex.wait(addr, expected);
            arch_frame.rax = 0;
        },

        // ------------------------------------------------------------------ //
        // futex_wake(addr: usize, max_wake: u32) -> woken_count|error         //
        //   Wake up to max_wake threads blocked on addr.                     //
        //   Returns the number of threads actually woken.                    //
        // ------------------------------------------------------------------ //
        .futex_wake => {
            const addr = syscall_frame.arg(.one);
            const max_wake: u32 = @truncate(syscall_frame.arg(.two));

            if (!validateUserBuffer(addr, @sizeOf(u32))) {
                arch_frame.rax = errCode(e.EFAULT);
                return;
            }

            const woken = innigkeit.sync.futex.wake(addr, max_wake);
            arch_frame.rax = @intCast(woken);
        },

        // ------------------------------------------------------------------ //
        // spawn(spec_ptr: usize) -> notify_handle|error                       //
        //   Reads a SpawnSpec from user memory, loads the named ELF from     //
        //   initfs, creates a new process, and returns a Notify handle that  //
        //   is signalled when the child exits.                               //
        // ------------------------------------------------------------------ //
        .spawn => {
            const spec_ptr = syscall_frame.arg(.one);
            const current_task: innigkeit.Task.Current = .get();
            arch_frame.rax = handlers.spawn.syscallSpawn(spec_ptr, current_task);
        },

        // ------------------------------------------------------------------ //
        // wait_process(notify_handle: u32) -> 0|error                         //
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
                arch_frame.rax = errCode(e.EBADF);
                return;
            };
            cap_table.lock.unlock();
            defer innigkeit.capabilities.CapabilityTable.unrefObject(slot_info.cap_type, slot_info.ptr);

            if (slot_info.cap_type != .notify) {
                arch_frame.rax = errCode(e.EINVAL);
                return;
            }
            if (!slot_info.rights.read) {
                arch_frame.rax = errCode(e.EPERM);
                return;
            }

            const notify: *innigkeit.capabilities.Notify = @ptrCast(@alignCast(slot_info.ptr));
            _ = notify.wait(1);
            arch_frame.rax = 0;
        },

        // ------------------------------------------------------------------ //
        // cap_revoke(handle: u32) -> 0|error                                   //
        //   Increments the object's generation counter, instantly invalidating  //
        //   every slot in every process that points to the same object.        //
        //   Requires .revoke rights on the calling slot.                       //
        // ------------------------------------------------------------------ //
        .cap_revoke => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));
            const process = Process.from(innigkeit.Task.Current.get().task);
            const cap_table = process.cap_table;

            cap_table.lock.lock();
            defer cap_table.lock.unlock();

            cap_table.revokeLocked(handle) catch |err| {
                arch_frame.rax = switch (err) {
                    error.NotFound => errCode(e.EBADF),
                    error.NoRevokeRight => errCode(e.EPERM),
                };
                return;
            };
            arch_frame.rax = 0;
        },

        // ------------------------------------------------------------------ //
        // vmem_map(handle: u32) -> addr|error                                 //
        //   Maps the Frame at `handle` into the calling process's address    //
        //   space. Returns the virtual base address of the new mapping.      //
        // ------------------------------------------------------------------ //
        .vmem_map => {
            const handle: u32 = @truncate(syscall_frame.arg(.one));
            const current_task: innigkeit.Task.Current = .get();
            arch_frame.rax = handlers.vmem.syscallVmemMap(handle, current_task);
        },

        // ------------------------------------------------------------------ //
        // vmem_unmap(addr: usize, size: usize) -> 0|error                     //
        //   Unmaps the region [addr, addr+size) from the calling process.    //
        //   addr and size must be page-aligned.                              //
        // ------------------------------------------------------------------ //
        .vmem_unmap => {
            const addr_raw = syscall_frame.arg(.one);
            const size_bytes = syscall_frame.arg(.two);
            const current_task: innigkeit.Task.Current = .get();
            arch_frame.rax = handlers.vmem.syscallVmemUnmap(addr_raw, size_bytes, current_task);
        },

        // ------------------------------------------------------------------ //
        // framebuffer_map(info_ptr: usize) -> va|error                        //
        //   Maps the bootloader framebuffer (write-combining) into the       //
        //   calling process's VA. Fills FramebufferInfo at info_ptr.         //
        //   Returns the virtual base address of the mapping.                 //
        // ------------------------------------------------------------------ //
        .framebuffer_map => {
            const info_ptr = syscall_frame.arg(.one);
            const current_task: innigkeit.Task.Current = .get();
            arch_frame.rax = handlers.framebuffer.syscallFramebufferMap(info_ptr, current_task);
        },

        // ------------------------------------------------------------------ //
        // initfs_read(spec_ptr: usize) -> bytes|error                         //
        //   spec_ptr -> InitfsReadSpec{name_ptr, name_len, buf_ptr, buf_len}  //
        //   Read a file from the embedded initfs archive into a user buffer. //
        //   buf_len==0 returns the file size without copying (stat mode).    //
        // ------------------------------------------------------------------ //
        .initfs_read => {
            const spec_ptr = syscall_frame.arg(.one);
            const current_task: innigkeit.Task.Current = .get();
            arch_frame.rax = handlers.framebuffer.syscallInitfsRead(spec_ptr, current_task);
        },

        // ------------------------------------------------------------------ //
        // uptime_ms() -> ms:usize                                             //
        //   Returns milliseconds elapsed since kernel boot.                  //
        // ------------------------------------------------------------------ //
        .uptime_ms => {
            arch_frame.rax = handlers.framebuffer.syscallUptimeMs();
        },

        // ----------------------------------------------------------------------- //
        // blk_read(spec_ptr: usize) -> bytes|error                                 //
        //   spec_ptr -> BlkReadSpec{byte_offset:u64, buf_ptr:usize, buf_len:usize} //
        //   Reads bytes from the data disk (virtio-blk device 1).                 //
        // ----------------------------------------------------------------------- //
        .blk_read => {
            const spec_ptr = syscall_frame.arg(.one);
            const current_task: innigkeit.Task.Current = .get();
            arch_frame.rax = handlers.framebuffer.syscallBlkRead(spec_ptr, current_task);
        },

        // ------------------------------------------------------------------ //
        // kbd_read(buf_ptr: usize, buf_len: usize) -> count                   //
        //   Non-blocking drain of raw PS/2 bytes (incl. 0xE0 prefix and      //
        //   break bit) into a user buffer. Returns 0 when no keys pending.   //
        // ------------------------------------------------------------------ //
        .kbd_read => {
            const buf_ptr = syscall_frame.arg(.one);
            const buf_len = syscall_frame.arg(.two);
            const current_task: innigkeit.Task.Current = .get();
            arch_frame.rax = handlers.framebuffer.syscallKbdRead(buf_ptr, buf_len, current_task);
        },
    }
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

/// Cast a signed error code to the bit pattern expected in rax / a0 / x0.
inline fn errCode(code: i64) usize {
    return @bitCast(code);
}

/// Negated POSIX errno values used as syscall return codes.
const e = struct {
    const EPERM: i64 = -1;
    const EIO: i64 = -5;
    const EBADF: i64 = -9;
    const ENOMEM: i64 = -12;
    const EFAULT: i64 = -14;
    const EINVAL: i64 = -22;
    const ENOSYS: i64 = -38;
};

/// Return true if `[ptr, ptr+len)` is a non-wrapping range fully inside
/// the user virtual address space as defined by the architecture.
fn validateUserBuffer(ptr: usize, len: usize) bool {
    if (len == 0) return true;
    if (ptr +% len < ptr) return false; // integer overflow
    const range: innigkeit.VirtualRange = .from(
        .from(ptr),
        .from(len, .byte),
    );
    return architecture.user.user_memory_range.fullyContains(range);
}
