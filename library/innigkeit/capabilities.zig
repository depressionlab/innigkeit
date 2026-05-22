const Syscall = @import("syscall.zig").Syscall;
const SyscallError = @import("syscall.zig").SyscallError;

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
pub const Message = extern struct {
    tag: u64 = 0,
    words: [6]u64 = [_]u64{0} ** 6,
};

/// Invoke a capability operation.
///
/// `op` and `arg` semantics depend on the object type; see the `*Op` enums.
pub fn invoke(handle: Handle, op: u64, arg: usize) SyscallError!usize {
    const result = Syscall.invoke(.cap_invoke, .{ handle, @as(usize, @intCast(op)), arg });
    return Syscall.decode(result);
}

/// Copy a capability slot, optionally restricting rights.
///
/// `new_rights` must be a subset of the source slot's rights.
/// Returns the new handle on success.
pub fn copy(handle: Handle, new_rights: Rights) SyscallError!Handle {
    const result = Syscall.invoke(.cap_copy, .{
        handle,
        @as(usize, @as(u16, @bitCast(new_rights))),
    });
    return @intCast(try Syscall.decode(result));
}

/// Move a capability to a new slot (copy with same rights, then delete the original).
///
/// Returns the new handle. The old handle is invalidated.
pub fn move(handle: Handle) SyscallError!Handle {
    const result = Syscall.invoke(.cap_move, .{handle});
    return @intCast(try Syscall.decode(result));
}

/// Delete a capability, releasing the kernel object if this was the last reference.
pub fn delete(handle: Handle) SyscallError!void {
    const result = Syscall.invoke(.cap_delete, .{handle});
    _ = try Syscall.decode(result);
}

pub const NotifyOp = enum(u64) {
    signal = 0,
    wait = 1,
    poll = 2,
};

/// Set bits on a Notify capability. Never blocks. Requires write rights.
pub fn notifySignal(handle: Handle, bits: u64) SyscallError!void {
    _ = try invoke(handle, @intFromEnum(NotifyOp.signal), @intCast(bits));
}

/// Block until at least one bit in `clear_mask` is set. Returns the bits received.
/// Requires read rights.
pub fn notifyWait(handle: Handle, clear_mask: u64) SyscallError!u64 {
    return try invoke(handle, @intFromEnum(NotifyOp.wait), @intCast(clear_mask));
}

/// Non-blocking check: returns matching pending bits (0 if none). Requires read rights.
pub fn notifyPoll(handle: Handle, clear_mask: u64) SyscallError!u64 {
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
pub fn endpointSend(handle: Handle, msg: *const Message) SyscallError!void {
    _ = try invoke(handle, @intFromEnum(EndpointOp.send), @intFromPtr(msg));
}

/// Block until a sender arrives and copy the message into `msg`.
/// Requires read rights.
pub fn endpointRecv(handle: Handle, msg: *Message) SyscallError!void {
    _ = try invoke(handle, @intFromEnum(EndpointOp.recv), @intFromPtr(msg));
}

/// Synchronous call: send `msg` and block until a reply is written back.
/// The reply overwrites `msg` in place. Requires write rights.
pub fn endpointCall(handle: Handle, msg: *Message) SyscallError!void {
    _ = try invoke(handle, @intFromEnum(EndpointOp.call), @intFromPtr(msg));
}

/// Reply to the pending call-mode sender. `msg` is the reply payload.
/// Requires write rights.
pub fn endpointReply(handle: Handle, msg: *const Message) SyscallError!void {
    _ = try invoke(handle, @intFromEnum(EndpointOp.reply), @intFromPtr(msg));
}

/// Atomically reply to the current pending sender, then block for the next message.
/// `msg` in: reply payload; `msg` out: next incoming message. Requires read+write rights.
pub fn endpointReplyRecv(handle: Handle, msg: *Message) SyscallError!void {
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
pub fn endpointRecvCall(handle: Handle, msg: *Message) SyscallError!RecvCallResult {
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
pub fn replyCapSend(handle: Handle, msg: *const Message) SyscallError!void {
    _ = try invoke(handle, @intFromEnum(ReplyOp.send), @intFromPtr(msg));
}

/// Kernel object types that can be created via `cap_create`.
pub const CreateType = enum(u8) {
    notify = 2,
    endpoint = 3,
};

/// Create a new kernel capability object and return a handle to it.
/// The caller gets a slot with full rights (read + write + grant).
pub fn create(object_type: CreateType) SyscallError!Handle {
    const result = Syscall.invoke(.cap_create, .{@intFromEnum(object_type)});
    return @intCast(try Syscall.decode(result));
}

pub const FrameOp = enum(u64) {
    clone = 0,
    phys_addr = 1,
};

/// Clone a frame capability (new handle to the same physical page).
/// Requires grant rights.
pub fn frameClone(handle: Handle) SyscallError!Handle {
    return @intCast(try invoke(handle, @intFromEnum(FrameOp.clone), 0));
}

/// Return the physical base address of the frame.
/// Requires read rights.
pub fn framePhysAddr(handle: Handle) SyscallError!usize {
    return try invoke(handle, @intFromEnum(FrameOp.phys_addr), 0);
}
