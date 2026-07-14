//! Kernel-side handler for the `cap_invoke` syscall.
//!
//! Dispatches a capability-specific operation (Notify / Reply / Endpoint /
//! SecureVault / GpuBuffer / Frame) after looking the handle up in the calling
//! process's capability table (which validates the generation and takes a
//! reference) and enforcing the per-operation rights.
//!
//! Threat model (user->kernel boundary): the handle/op/arg come from userspace;
//! the handle is validated by `getAndRefLocked` (bad/stale -> BadHandle), rights
//! are checked per op (-> PermissionDenied), and every message/buffer transfer
//! goes through the fault-safe `validate` helpers (-> BadAddress). No user
//! pointer is dereferenced outside those helpers. There is no entitlement gate:
//! authority comes from holding the capability with the right bits.

const innigkeit = @import("innigkeit");
const std = @import("std");

const validate = @import("../validate.zig");
const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");

const Message = innigkeit.capabilities.Message;
const Reply = innigkeit.capabilities.Reply;

/// Service the `cap_invoke` syscall.
pub fn capInvoke(context: Context) Error.Syscall!usize {
    const handle = context.arg32(.one);
    const op = context.arg64(.two);
    const arg3 = context.arg(.three);

    const cap_table = context.process().cap_table;

    cap_table.lock.lock();
    const slot_info = cap_table.getAndRefLocked(handle) orelse {
        cap_table.lock.unlock();
        return Error.Syscall.BadHandle;
    };
    cap_table.lock.unlock();
    defer innigkeit.capabilities.CapabilityTable.unrefObject(slot_info.cap_type, slot_info.ptr);

    switch (slot_info.cap_type) {
        .null => unreachable,

        .notify => {
            const Notify = innigkeit.capabilities.Notify;
            const notify: *Notify = @ptrCast(@alignCast(slot_info.ptr));
            const notify_op = std.enums.fromInt(Notify.Op, op) orelse
                return Error.Syscall.InvalidArgument;
            switch (notify_op) {
                .signal => {
                    if (!slot_info.rights.write)
                        return Error.Syscall.PermissionDenied;
                    notify.signal(arg3);
                    return 0;
                },
                .wait => {
                    if (!slot_info.rights.read)
                        return Error.Syscall.PermissionDenied;
                    return notify.wait(arg3);
                },
                .poll => {
                    if (!slot_info.rights.read)
                        return Error.Syscall.PermissionDenied;
                    return notify.poll(arg3);
                },
            }
        },

        .reply => {
            const reply_cap: *Reply = @ptrCast(@alignCast(slot_info.ptr));
            const reply_op = std.enums.fromInt(Reply.Op, op) orelse
                return Error.Syscall.InvalidArgument;
            switch (reply_op) {
                .send => {
                    if (!slot_info.rights.write) return Error.Syscall.PermissionDenied;
                    const msg = try validate.readUser(Message, arg3);
                    reply_cap.send(msg) catch return Error.Syscall.InvalidArgument; // already replied
                    return 0;
                },
            }
        },

        .endpoint => {
            const Endpoint = innigkeit.capabilities.Endpoint;
            const endpoint: *Endpoint = @ptrCast(@alignCast(slot_info.ptr));
            const ep_op = std.enums.fromInt(Endpoint.Op, op) orelse
                return Error.Syscall.InvalidArgument;
            switch (ep_op) {
                .send => {
                    if (!slot_info.rights.write) return Error.Syscall.PermissionDenied;
                    // Copy message out of user memory before blocking.
                    const msg = try validate.readUser(Message, arg3);
                    endpoint.send(msg);
                    return 0;
                },
                .recv => {
                    if (!slot_info.rights.read) return Error.Syscall.PermissionDenied;
                    // Validate before blocking so a bad buffer faults
                    // without consuming a message.
                    if (!validate.userBuffer(arg3, @sizeOf(Message)))
                        return Error.Syscall.BadAddress;
                    // Block first, then copy into user memory.
                    const msg = endpoint.recv();
                    try validate.writeUser(arg3, msg);
                    return 0;
                },
                .call => {
                    if (!slot_info.rights.write) return Error.Syscall.PermissionDenied;
                    // arg3 = pointer to Message (in: request, out: reply).
                    // Copy the request out before blocking; copy the
                    // reply back after unblocking.
                    const request = try validate.readUser(Message, arg3);
                    const reply = endpoint.call(request);
                    try validate.writeUser(arg3, reply);
                    return 0;
                },
                .reply => {
                    if (!slot_info.rights.write) return Error.Syscall.PermissionDenied;
                    const msg = try validate.readUser(Message, arg3);
                    endpoint.reply(msg) catch return Error.Syscall.InvalidArgument; // no pending sender
                    return 0;
                },
                .reply_recv => {
                    if (!slot_info.rights.read or !slot_info.rights.write) return Error.Syscall.PermissionDenied;
                    // arg3 = pointer to Message (in: reply to send, out: next request).
                    // Copy the reply out before blocking; copy the
                    // next request back after unblocking.
                    const reply_msg = try validate.readUser(Message, arg3);
                    const next_request = endpoint.replyRecv(reply_msg);
                    try validate.writeUser(arg3, next_request);
                    return 0;
                },
                .recv_call => {
                    if (!slot_info.rights.read) return Error.Syscall.PermissionDenied;
                    // Validate before blocking so a bad buffer faults
                    // without consuming a message.
                    if (!validate.userBuffer(arg3, @sizeOf(Message)))
                        return Error.Syscall.BadAddress;
                    // Block until a message arrives.
                    const result = endpoint.recvCall();
                    // Copy message to user memory.
                    try validate.writeUser(arg3, result.msg);
                    // If the sender used call(), create a Reply cap for them.
                    if (result.sender) |sender_task| {
                        const reply_cap = Reply.create(sender_task) catch {
                            sender_task.ipc_message = .{};
                            sender_task.wakeFromBlocked();
                            return Error.Syscall.OutOfMemory;
                        };
                        const tbl = context.process().cap_table;
                        tbl.lock.lock();
                        const idx = tbl.insertLocked(.reply, reply_cap, .{ .write = true }) catch {
                            tbl.lock.unlock();
                            reply_cap.unref(); // wakes sender with empty reply
                            return Error.Syscall.OutOfMemory;
                        };
                        tbl.lock.unlock();
                        return @intCast(idx);
                    }
                    return @intCast(innigkeit.config.capabilities.null_slot);
                },
            }
        },

        .secure_vault => {
            const Vault = innigkeit.capabilities.SecureVault;
            const vault: *Vault = @ptrCast(@alignCast(slot_info.ptr));
            const vault_op = std.enums.fromInt(Vault.Op, op) orelse
                return Error.Syscall.InvalidArgument;
            switch (vault_op) {
                .status => return if (vault.tpm_backed) 1 else 0,
                .seal => {
                    // arg.three=src_ptr, .four=src_len, .five=dst_ptr, .six=dst_len.
                    const src_ptr = context.arg(.three);
                    const src_len = context.arg(.four);
                    const dst_ptr = context.arg(.five);
                    const dst_len = context.arg(.six);

                    // Bound before allocating; oversized inputs are
                    // rejected the same way `seal` would (TooBig).
                    if (src_len > Vault.MAX_PLAINTEXT)
                        return Error.Syscall.InvalidArgument;
                    if (!validate.userBuffer(src_ptr, src_len) or
                        !validate.userBuffer(dst_ptr, dst_len))
                    {
                        return Error.Syscall.BadAddress;
                    }

                    // Bounce through kernel buffers so the crypto never
                    // touches user memory: a bad/unmapped user page is a
                    // BadAddress from the fault-safe copies, not a panic.
                    const out_cap = @min(dst_len, Vault.MAX_PLAINTEXT + Vault.OVERHEAD);
                    const heap = innigkeit.memory.heap.allocator;
                    const in_buf = try heap.alloc(u8, src_len);
                    defer heap.free(in_buf);
                    const out_buf = try heap.alloc(u8, out_cap);
                    defer heap.free(out_buf);

                    try validate.copyFromUser(in_buf, src_ptr);
                    const written = vault.seal(in_buf, out_buf) catch |err| return switch (err) {
                        error.TooBig => Error.Syscall.InvalidArgument,
                        error.BufferTooSmall => Error.Syscall.InvalidArgument,
                    };
                    try validate.copyToUser(dst_ptr, out_buf[0..written]);
                    return @intCast(written);
                },
                .unseal => {
                    // arg.three=src_ptr (blob), .four=src_len, .five=dst_ptr, .six=dst_len.
                    const src_ptr = context.arg(.three);
                    const src_len = context.arg(.four);
                    const dst_ptr = context.arg(.five);
                    const dst_len = context.arg(.six);

                    if (src_len > Vault.MAX_PLAINTEXT + Vault.OVERHEAD) return Error.Syscall.InvalidArgument;
                    if (!validate.userBuffer(src_ptr, src_len) or
                        !validate.userBuffer(dst_ptr, dst_len))
                    {
                        return Error.Syscall.BadAddress;
                    }

                    // Bounce through kernel buffers (fault-safe copies).
                    const out_cap = @min(dst_len, Vault.MAX_PLAINTEXT);
                    const heap = innigkeit.memory.heap.allocator;
                    const in_buf = try heap.alloc(u8, src_len);
                    defer heap.free(in_buf);
                    const out_buf = try heap.alloc(u8, out_cap);
                    defer heap.free(out_buf);

                    try validate.copyFromUser(in_buf, src_ptr);
                    const written = vault.unseal(in_buf, out_buf) catch |err| return switch (err) {
                        error.TooSmall => Error.Syscall.InvalidArgument,
                        error.BufferTooSmall => Error.Syscall.InvalidArgument,
                        error.AuthFailed => Error.Syscall.PermissionDenied,
                    };
                    try validate.copyToUser(dst_ptr, out_buf[0..written]);
                    return @intCast(written);
                },
            }
        },

        .gpu_buffer => {
            const GpuBuffer = innigkeit.capabilities.GpuBuffer;
            const gpu: *GpuBuffer = @ptrCast(@alignCast(slot_info.ptr));
            const gpu_op = std.enums.fromInt(GpuBuffer.Op, op) orelse
                return Error.Syscall.InvalidArgument;
            switch (gpu_op) {
                .phys_addr => return gpu.phys_base.value,
                .size => return gpu.size_bytes,
                .usage => return @as(u32, @bitCast(gpu.usage)),
            }
        },

        .frame => {
            const Frame = innigkeit.capabilities.Frame;
            const frame: *Frame = @ptrCast(@alignCast(slot_info.ptr));
            const frame_op = std.enums.fromInt(Frame.Op, op) orelse
                return Error.Syscall.InvalidArgument;
            switch (frame_op) {
                .clone => {
                    if (!slot_info.rights.grant)
                        return Error.Syscall.PermissionDenied;
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
                        return Error.Syscall.OutOfMemory; // table full
                    };
                    return @intCast(new_idx);
                },
                .phys_addr => {
                    if (!slot_info.rights.read)
                        return Error.Syscall.PermissionDenied;
                    return frame.physicalAddress().value;
                },
            }
        },
    }
}

/// cap_copy(handle, rights) -> new_handle : copy a capability into a new slot,
/// optionally restricting rights (never escalating).
pub fn capCopy(context: Context) Error.Syscall!usize {
    const handle = context.arg32(.one);
    const rights_raw: u16 = @truncate(context.arg(.two));
    const new_rights: innigkeit.capabilities.Rights = @bitCast(rights_raw);

    const cap_table = context.process().cap_table;
    cap_table.lock.lock();
    defer cap_table.lock.unlock();
    const new_idx = cap_table.copyLocked(handle, new_rights) catch |err| return switch (err) {
        error.NotFound => Error.Syscall.BadHandle,
        error.Full => Error.Syscall.OutOfMemory,
        error.RightsEscalation => Error.Syscall.PermissionDenied,
    };
    return @intCast(new_idx);
}

/// cap_move(handle) -> new_handle : move a capability to a new slot and
/// invalidate the original.
pub fn capMove(context: Context) Error.Syscall!usize {
    const handle = context.arg32(.one);

    const cap_table = context.process().cap_table;
    cap_table.lock.lock();
    defer cap_table.lock.unlock();

    const slot = cap_table.getLocked(handle) orelse return Error.Syscall.BadHandle;
    const current_rights = slot.rights;

    // Copy to a new slot (bumps refcount to 2). The defer handles unlock on all
    // exit paths; do NOT unlock explicitly here.
    const new_idx = cap_table.copyLocked(handle, current_rights) catch |err| return switch (err) {
        error.NotFound => Error.Syscall.BadHandle,
        error.Full => Error.Syscall.OutOfMemory,
        error.RightsEscalation => unreachable, // same rights
    };

    // Remove the original slot (decrements refcount back to 1).
    cap_table.removeLocked(handle) catch unreachable;

    return @intCast(new_idx);
}

/// cap_delete(handle) -> 0 : remove a capability slot.
pub fn capDelete(context: Context) Error.Syscall!usize {
    const handle = context.arg32(.one);
    const cap_table = context.process().cap_table;
    cap_table.lock.lock();
    defer cap_table.lock.unlock();
    cap_table.removeLocked(handle) catch return Error.Syscall.BadHandle;
    return 0;
}

/// cap_create(type) -> handle : create a new kernel capability object.
/// Object types secure_vault and gpu_buffer are entitlement-gated (the gate is
/// conditional on the requested type, so it lives here, not in the table).
pub fn capCreate(context: Context) Error.Syscall!usize {
    const type_raw: u8 = @truncate(context.arg(.one));
    const cap_type = std.enums.fromInt(innigkeit.capabilities.ObjectType, type_raw) orelse
        return Error.Syscall.InvalidArgument;

    const cap_table = context.process().cap_table;

    switch (cap_type) {
        .null => return Error.Syscall.InvalidArgument,
        .notify => {
            const notify: *innigkeit.capabilities.Notify = try .create();
            cap_table.lock.lock();
            defer cap_table.lock.unlock();
            const idx = cap_table.insertLocked(.notify, notify, .all) catch {
                notify.unref();
                return Error.Syscall.OutOfMemory;
            };
            return @intCast(idx);
        },
        .endpoint => {
            const endpoint: *innigkeit.capabilities.Endpoint = try .create();
            cap_table.lock.lock();
            defer cap_table.lock.unlock();
            const idx = cap_table.insertLocked(.endpoint, endpoint, .all) catch {
                endpoint.unref();
                return Error.Syscall.OutOfMemory;
            };
            return @intCast(idx);
        },
        .frame => {
            // Physical frame allocation requires a size; use cap_invoke on a Vmem capability.
            const frame: *innigkeit.capabilities.Frame = try .create();
            cap_table.lock.lock();
            defer cap_table.lock.unlock();
            const idx = cap_table.insertLocked(.frame, frame, .all) catch {
                frame.unref();
                return Error.Syscall.OutOfMemory;
            };
            return @intCast(idx);
        },
        // Reply capabilities are created by the kernel (recv_call), not userspace.
        .reply => return Error.Syscall.InvalidArgument,
        .secure_vault => {
            if (!context.entitled("secure_vault")) return Error.Syscall.PermissionDenied;
            // arg2 reserved (was a software-only/prefer-TPM hint): create() now
            // roots the key in the TPM hardware RNG automatically whenever a
            // TPM 2.0 device is present.
            _ = context.arg(.two);
            const vault: *innigkeit.capabilities.SecureVault = try .create();
            cap_table.lock.lock();
            defer cap_table.lock.unlock();
            const idx = cap_table.insertLocked(.secure_vault, vault, .all) catch {
                vault.unref();
                return Error.Syscall.OutOfMemory;
            };
            return @intCast(idx);
        },
        .gpu_buffer => {
            if (!context.entitled("gpu")) return Error.Syscall.PermissionDenied;
            // arg2: page_count (>= 1); arg3: usage bitmask (GpuBuffer.Usage as u32).
            const page_count = context.arg(.two);
            const usage_raw = context.arg32(.three);
            if (page_count == 0) return Error.Syscall.InvalidArgument;
            const gpu: *innigkeit.capabilities.GpuBuffer = try .create(page_count, @bitCast(usage_raw));
            cap_table.lock.lock();
            defer cap_table.lock.unlock();
            const idx = cap_table.insertLocked(.gpu_buffer, gpu, .all) catch {
                gpu.unref();
                return Error.Syscall.OutOfMemory;
            };
            return @intCast(idx);
        },
    }
}

/// cap_revoke(handle) -> 0 : bump the object's generation counter, invalidating
/// every slot in every process that points to the same object. Requires .revoke.
pub fn capRevoke(context: Context) Error.Syscall!usize {
    const handle = context.arg32(.one);
    const cap_table = context.process().cap_table;
    cap_table.lock.lock();
    defer cap_table.lock.unlock();
    cap_table.revokeLocked(handle) catch |err| return switch (err) {
        error.NotFound => Error.Syscall.BadHandle,
        error.NoRevokeRight => Error.Syscall.PermissionDenied,
    };
    return 0;
}
