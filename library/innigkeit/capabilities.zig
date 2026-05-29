const Syscall = @import("syscall.zig").Syscall;

/// An opaque index into the process capability table.
pub const Handle = u32;

/// The kernel will never allocate this index; use it as a sentinel.
pub const invalid_handle: Handle = ~@as(Handle, 0);

/// Subset of capability permissions.
pub const Rights = packed struct(u16) {
    read: bool = false,
    write: bool = false,
    grant: bool = false,
    _pad: u13 = 0,

    pub const all: Rights = .{ .read = true, .write = true, .grant = true };
    pub const read_only: Rights = .{ .read = true };
    pub const write_only: Rights = .{ .write = true };
};

/// ABI-stable IPC message. Layout must match the kernel's `capabilities.Message`.
/// Total size: 8 (tag) + 32 (words) + 16 (caps) = 56 bytes
pub const Message = extern struct {
    tag: u64 = 0,
    words: [4]u64 = [_]u64{0} ** 4,
    /// Capability handles to transfer. 0 = none.
    /// During IPC handoff the kernel copies each non-zero handle from the
    /// sender's cap table into the receiver's cap table and updates the field.
    caps: [4]u32 = [_]u32{0} ** 4,
};

/// Invoke a capability operation.
///
/// `op` and `arg` semantics depend on the object type; see the `*Op` enums.
pub fn invoke(handle: Handle, op: u64, arg: usize) Syscall.Error!usize {
    const result = Syscall.invoke(.cap_invoke, .{ handle, @as(usize, @intCast(op)), arg });
    return Syscall.decode(result);
}

/// Copy a capability slot, optionally restricting rights.
///
/// `new_rights` must be a subset of the source slot's rights.
/// Returns the new handle on success.
pub fn copy(handle: Handle, new_rights: Rights) Syscall.Error!Handle {
    const result = Syscall.invoke(.cap_copy, .{
        handle,
        @as(usize, @as(u16, @bitCast(new_rights))),
    });
    return @intCast(try Syscall.decode(result));
}

/// Move a capability to a new slot (copy with same rights, then delete the original).
///
/// Returns the new handle. The old handle is invalidated.
pub fn move(handle: Handle) Syscall.Error!Handle {
    const result = Syscall.invoke(.cap_move, .{handle});
    return @intCast(try Syscall.decode(result));
}

/// Delete a capability, releasing the kernel object if this was the last reference.
pub fn delete(handle: Handle) Syscall.Error!void {
    const result = Syscall.invoke(.cap_delete, .{handle});
    _ = try Syscall.decode(result);
}

pub const NotifyOp = enum(u64) {
    signal = 0,
    wait = 1,
    poll = 2,
};

/// Set bits on a Notify capability. Never blocks. Requires write rights.
pub fn notifySignal(handle: Handle, bits: u64) Syscall.Error!void {
    _ = try invoke(handle, @intFromEnum(NotifyOp.signal), @intCast(bits));
}

/// Block until at least one bit in `clear_mask` is set. Returns the bits received.
/// Requires read rights.
pub fn notifyWait(handle: Handle, clear_mask: u64) Syscall.Error!u64 {
    return try invoke(handle, @intFromEnum(NotifyOp.wait), @intCast(clear_mask));
}

/// Non-blocking check: returns matching pending bits (0 if none). Requires read rights.
pub fn notifyPoll(handle: Handle, clear_mask: u64) Syscall.Error!u64 {
    return try invoke(handle, @intFromEnum(NotifyOp.poll), @intCast(clear_mask));
}

pub const EndpointOp = enum(u64) {
    send = 0,
    recv = 1,
    call = 2,
    reply = 3,
    reply_recv = 4,
    /// Like `recv`, but returns a Reply capability handle for call-mode senters.
    recv_call = 5,
};

/// Send a message on an Endpoint, blocking until the receiver picks it up.
/// Requires write rights.
pub fn endpointSend(handle: Handle, msg: *const Message) Syscall.Error!void {
    _ = try invoke(handle, @intFromEnum(EndpointOp.send), @intFromPtr(msg));
}

/// Block until a sender arrives and copy the message into `msg`.
/// Requires read rights.
pub fn endpointRecv(handle: Handle, msg: *Message) Syscall.Error!void {
    _ = try invoke(handle, @intFromEnum(EndpointOp.recv), @intFromPtr(msg));
}

/// Synchronous call: send `msg` and block until a reply is written back.
/// The reply overwrites `msg` in place. Requires write rights.
pub fn endpointCall(handle: Handle, msg: *Message) Syscall.Error!void {
    _ = try invoke(handle, @intFromEnum(EndpointOp.call), @intFromPtr(msg));
}

/// Reply to the pending call-mode sender. `msg` is the reply payload.
/// Requires write rights.
pub fn endpointReply(handle: Handle, msg: *const Message) Syscall.Error!void {
    _ = try invoke(handle, @intFromEnum(EndpointOp.reply), @intFromPtr(msg));
}

/// Atomically reply to the current pending sender, then block for the next message.
/// `msg` in: reply payload; `msg` out: next incoming message. Requires read+write rights.
pub fn endpointReplyRecv(handle: Handle, msg: *Message) Syscall.Error!void {
    _ = try invoke(handle, @intFromEnum(EndpointOp.reply_recv), @intFromPtr(msg));
}

/// Result of `endpointRecvCall`.
pub const RecvCallResult = struct {
    /// The received message.
    msg: Message,
    /// Handle to a Reply capability if the sender used `endpointCall`; otherwise
    /// `invalid_handle`. Invoke `.replyCapSend` with this handle to unblock the
    /// caller. The cap is automatically deleted after being used.
    reply_handle: Handle,

    /// True when a Reply cap is available (sender used call, not send).
    pub fn hasReply(self: RecvCallResult) bool {
        return self.reply_handle != invalid_handle;
    }
};

/// Receive a message; for call-mode senders also obtain a Reply cap.
///
/// Returns `RecvCallResult.reply_handle == invalid_handle` for fire-and-forget
/// senders. For call-mode senders, call `replyCapSend` with the handle before
/// deleting it, otherwise the sender is unblocked with an empty error message.
pub fn endpointRecvCall(handle: Handle, msg: *Message) Syscall.Error!RecvCallResult {
    const raw = try invoke(handle, @intFromEnum(EndpointOp.recv_call), @intFromPtr(msg));
    // Kernel returns null_slot (0xFFFF_FFFF) for fire-and-forget, or a real handle.
    const reply_handle: Handle = @truncate(raw);
    return .{ .msg = msg.*, .reply_handle = reply_handle };
}

pub const ReplyOp = enum(u64) {
    send = 0,
};

/// Send a reply via a Reply capability and unblock the waiting caller.
///
/// Returns `error.InvalidArgument` if the reply was already sent (double-reply).
/// The caller should `caps.delete(reply_handle)` after this returns.
pub fn replyCapSend(handle: Handle, msg: *const Message) Syscall.Error!void {
    _ = try invoke(handle, @intFromEnum(ReplyOp.send), @intFromPtr(msg));
}

/// Kernel object types that can be created via `cap_create`.
pub const CreateType = enum(u8) {
    notify = 2,
    endpoint = 3,
};

/// Create a new kernel capability object and return a handle to it.
/// The caller gets a slot with full rights (read + write + grant).
pub fn create(object_type: CreateType) Syscall.Error!Handle {
    const result = Syscall.invoke(.cap_create, .{@intFromEnum(object_type)});
    return @intCast(try Syscall.decode(result));
}

pub const SecureVaultOp = enum(u64) {
    seal = 0,
    unseal = 1,
    status = 2,
};

/// Create a software-only SecureVault capability.
/// The vault generates a random 256-bit wrapping key kept in kernel memory.
pub fn secureVaultCreate() Syscall.Error!Handle {
    const result = Syscall.invoke(.cap_create, .{ @as(usize, 5), @as(usize, 0) });
    return @intCast(try Syscall.decode(result));
}

/// Seal `plaintext` into `out_blob`.
/// Returns the number of bytes written to `out_blob` (plaintext.len + 40).
/// `out_blob` must be at least `plaintext.len + 40` bytes.
pub fn secureVaultSeal(handle: Handle, plaintext: []const u8, out_blob: []u8) Syscall.Error!usize {
    const result = Syscall.invoke(.cap_invoke, .{
        @as(usize, handle),
        @as(usize, @intFromEnum(SecureVaultOp.seal)),
        @intFromPtr(plaintext.ptr),
        plaintext.len,
        @intFromPtr(out_blob.ptr),
        out_blob.len,
    });
    return Syscall.decode(result);
}

/// Unseal a blob produced by `secureVaultSeal`.
/// Returns the number of bytes written to `out_plaintext`.
/// Returns `error.PermissionDenied` if authentication fails.
pub fn secureVaultUnseal(handle: Handle, blob: []const u8, out_plaintext: []u8) Syscall.Error!usize {
    const result = Syscall.invoke(.cap_invoke, .{
        @as(usize, handle),
        @as(usize, @intFromEnum(SecureVaultOp.unseal)),
        @intFromPtr(blob.ptr),
        blob.len,
        @intFromPtr(out_plaintext.ptr),
        out_plaintext.len,
    });
    return Syscall.decode(result);
}

/// Returns 1 if the vault is backed by a TPM 2.0 device, 0 otherwise.
pub fn secureVaultStatus(handle: Handle) Syscall.Error!usize {
    return invoke(handle, @intFromEnum(SecureVaultOp.status), 0);
}

pub const GpuBufferUsage = packed struct(u32) {
    vertex_buffer: bool = false,
    texture: bool = false,
    render_target: bool = false,
    readback: bool = false,
    cpu_visible: bool = true,
    _pad: u27 = 0,
};

pub const GpuBufferOp = enum(u64) {
    phys_addr = 0,
    size = 1,
    usage = 2,
};

/// Allocate a GpuBuffer capability backed by `page_count` physical pages.
/// `page_count` must be >= 1.
pub fn gpuBufferCreate(page_count: usize, usage: GpuBufferUsage) Syscall.Error!Handle {
    const result = Syscall.invoke(.cap_create, .{
        @as(usize, 6),
        page_count,
        @as(usize, @as(u32, @bitCast(usage))),
    });
    return @intCast(try Syscall.decode(result));
}

/// Return the physical base address of the buffer.
pub fn gpuBufferPhysAddr(handle: Handle) Syscall.Error!usize {
    return invoke(handle, @intFromEnum(GpuBufferOp.phys_addr), 0);
}

/// Return the size of the buffer in bytes.
pub fn gpuBufferSize(handle: Handle) Syscall.Error!usize {
    return invoke(handle, @intFromEnum(GpuBufferOp.size), 0);
}

/// Return the usage bitmask as a raw u32.
pub fn gpuBufferUsageRaw(handle: Handle) Syscall.Error!u32 {
    return @intCast(try invoke(handle, @intFromEnum(GpuBufferOp.usage), 0));
}

pub const FrameOp = enum(u64) {
    clone = 0,
    phys_addr = 1,
};

/// Clone a frame capability (new handle to the same physical page).
/// Requires grant rights.
pub fn frameClone(handle: Handle) Syscall.Error!Handle {
    return @intCast(try invoke(handle, @intFromEnum(FrameOp.clone), 0));
}

/// Return the physical base address of the frame.
/// Requires read rights.
pub fn framePhysAddr(handle: Handle) Syscall.Error!usize {
    return try invoke(handle, @intFromEnum(FrameOp.phys_addr), 0);
}

/// Map a Frame capability into the calling process's address space.
///
/// Returns the virtual base address of the mapped region on success.
/// The frame is mapped with read+write protection.
pub fn vmemMap(handle: Handle) Syscall.Error!usize {
    const result = Syscall.invoke(.vmem_map, .{@as(usize, handle)});
    return Syscall.decode(result);
}

/// Unmap a virtual address range from the calling process's address space.
///
/// `addr` and `size` must be page-aligned.
pub fn vmemUnmap(addr: usize, size: usize) Syscall.Error!void {
    const result = Syscall.invoke(.vmem_unmap, .{ addr, size });
    _ = try Syscall.decode(result);
}
