//! Single-use reply capability.
//!
//! Created by the kernel when a call-mode IPC message arrives at an Endpoint
//! and the receiver asks for a Reply cap (via the `recv_call` operation). The
//! receiver (or a delegate it passes the cap to) invokes `send` exactly once to
//! unblock the waiting caller.
//!
//! Liveness guarantee: if the Reply cap is dropped without calling `send`, the
//! destructor wakes the blocked caller with an empty (all-zeros) message so it
//! is never stuck forever.
const Reply = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");
const Message = @import("../Message.zig").Message;

/// Revocation generation counter. See `Notify.generation` for semantics.
/// Revoking a Reply capability before it is delivered aborts the blocked
/// caller (unref's destructor delivers a zero message, prevented a
/// permanent stall).
generation: std.atomic.Value(u32) = .init(0),
refcount: std.atomic.Value(usize) = .init(1),

/// Pointer to the task waiting for a reply, or 0 if the reply was already sent.
/// Manipulated with compare-and-swap to ensure the reply is delivered at most once.
sender: std.atomic.Value(usize),

pub fn create(sender_task: *innigkeit.Task) error{OutOfMemory}!*Reply {
    const self = innigkeit.mem.heap.allocator.create(Reply) catch return error.OutOfMemory;
    self.* = .{
        .refcount = .init(1),
        .sender = .init(@intFromPtr(sender_task)),
    };
    return self;
}

pub fn ref(self: *Reply) void {
    _ = self.refcount.fetchAdd(1, .acq_rel);
}

pub fn unref(self: *Reply) void {
    if (self.refcount.fetchSub(1, .acq_rel) != 1) return;
    // Deliver a zero message to any still-waiting sender so it is never stuck.
    const ptr = self.sender.swap(0, .acq_rel);
    if (ptr != 0) {
        const task: *innigkeit.Task = @ptrFromInt(ptr);
        task.ipc_message = .{};
        task.wakeFromBlocked();
    }
    innigkeit.mem.heap.allocator.destroy(self);
}

/// Deliver `msg` to the waiting caller and unblock them.
///
/// Returns `error.AlreadyReplied` if the reply was already sent (or the Reply
/// cap was already dropped). This is safe to call from any thread.
pub fn send(self: *Reply, msg: Message) error{AlreadyReplied}!void {
    const ptr = self.sender.swap(0, .acq_rel);
    if (ptr == 0) return error.AlreadyReplied;
    const task: *innigkeit.Task = @ptrFromInt(ptr);
    task.ipc_message = msg;
    task.wakeFromBlocked();
}

/// cap_invoke operations for Reply.
pub const Op = enum(u64) {
    /// Send the reply and unblock the caller. Requires write rights.
    /// arg = *const Message (pointer to reply payload in user memory).
    send = 0,
};
