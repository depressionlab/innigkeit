//! A synchronous IPC endpoint.
//!
//! A rendezvous channel: the sender blocks until a receiver is ready, and the
//! receiver blocks until a sender arrives. Messages are copied through a small
//! kernel buffer.
//!
//! No shared memory is required.
//!
//! TODO: seL4-style Reply token for zero-overhead call+replyRecv.
const Endpoint = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");
const Message = @import("../Message.zig").Message;

refcount: std.atomic.Value(usize) = .init(1),
lock: innigkeit.sync.TicketSpinLock = .{},

/// Queue of tasks blocked trying to send (waiting for a receiver).
send_queue: innigkeit.sync.WaitQueue = .{},
/// Queue of tasks blocked waiting to receive.
recv_queue: innigkeit.sync.WaitQueue = .{},

/// Scratch space used to hand a message from sender to receiver.
/// Protected by `lock`. Only valid while a handoff is in progress.
pending_msg: Message = .{},
/// Non-null while a sender is parked waiting for its reply.
/// Protected by `lock`.
pending_sender: ?*innigkeit.Task = null,

pub fn create() error{OutOfMemory}!*Endpoint {
    const self = innigkeit.mem.heap.allocator.create(Endpoint) catch return error.OutOfMemory;
    self.* = .{};
    return self;
}

pub fn ref(self: *Endpoint) void {
    _ = self.refcount.fetchAdd(1, .acq_rel);
}

pub fn unref(self: *Endpoint) void {
    if (self.refcount.fetchSub(1, .acq_rel) != 1) return;
    innigkeit.mem.heap.allocator.destroy(self);
}

/// Send a message and block until the receiver calls recv().
///
/// The sender is unblocked only after the message has been picked up.
/// This ensures the sender knows the message was delivered.
pub fn send(self: *Endpoint, msg: Message) void {
    self.lock.lock();
    self.pending_msg = msg;

    // If a receiver is already waiting, wake it and we're done.
    const receiver = self.recv_queue.popFirst();
    if (receiver) |r| {
        self.lock.unlock();
        r.wakeFromBlocked();
        return;
    }

    // No receiver yet, so we park ourselves on the send queue.
    self.send_queue.wait(&self.lock);
    // When we wake up, the receiver has copied pending_msg.
}

/// Block until a message arrives, then return it.
pub fn recv(self: *Endpoint) Message {
    self.lock.lock();

    // If a sender is already waiting, wake it and take the message.
    const sender = self.send_queue.popFirst();
    if (sender) |s| {
        const msg = self.pending_msg;
        self.lock.unlock();
        s.wakeFromBlocked();
        return msg;
    }

    // No sender yet, so we park on the recv queue.
    self.recv_queue.wait(&self.lock);
    // When we wake up, pending_msg was set by the sender.
    self.lock.lock();
    const msg = self.pending_msg;
    self.lock.unlock();
    return msg;
}

/// cap_invoke operations for Endpoint.
pub const Op = enum(u64) {
    /// Send: words[0..5] = payload; blocks until receiver calls recv.
    send = 0,
    /// Recv: blocks until a sender calls send; returns message in words.
    recv = 1,
};
