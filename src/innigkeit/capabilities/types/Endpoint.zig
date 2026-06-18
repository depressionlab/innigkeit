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

/// Revocation generation counter. See `Notify.generation` for semantics.
generation: std.atomic.Value(u32) = .init(0),
refcount: std.atomic.Value(usize) = .init(1),
lock: innigkeit.sync.TicketSpinLock = .{},

/// Queue of tasks blocked trying to send (waiting for a receiver).
send_queue: innigkeit.sync.WaitQueue = .{},
/// Queue of tasks blocked waiting to receive.
recv_queue: innigkeit.sync.WaitQueue = .{},
/// Queue of call-mode senders blocked waiting for a reply.
/// Each parked task stores its outgoing message in task.ipc_message.
call_queue: innigkeit.sync.WaitQueue = .{},

/// Scratch space used to hand a message from sender to receiver.
/// Protected by `lock`. Only valid while a handoff is in progress.
pending_msg: Message = .{},
/// Non-null while a call-mode sender is parked waiting for its reply.
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
    self.lock.lock();
    // Wake every parked task with an empty message so none stay blocked forever
    // on memory that is about to be freed. Callers treat tag==0 as "endpoint
    // destroyed" and should return an error to their caller.
    if (self.pending_sender) |s| {
        self.pending_sender = null;
        s.ipc_message = .{};
        s.wakeFromBlocked();
    }
    while (self.call_queue.popFirst()) |s| {
        s.ipc_message = .{};
        s.wakeFromBlocked();
    }
    while (self.send_queue.popFirst()) |s| {
        s.ipc_message = .{};
        s.wakeFromBlocked();
    }
    while (self.recv_queue.popFirst()) |r| {
        self.pending_msg = .{};
        r.wakeFromBlocked();
    }
    self.lock.unlock();
    innigkeit.mem.heap.allocator.destroy(self);
}

fn transferCaps(msg: *Message, sender_task: *innigkeit.Task, receiver_task: *innigkeit.Task) void {
    innigkeit.capabilities.CapabilityTable.transferCaps(msg, sender_task, receiver_task);
}

/// Send a message and block until the receiver calls recv().
///
/// The sender is unblocked only after the message has been picked up.
/// This ensures the sender knows the message was delivered.
pub fn send(self: *Endpoint, msg: Message) void {
    const current_task: innigkeit.Task.Current = .get();
    current_task.task.ipc_message = msg;

    self.lock.lock();

    // If a receiver is already waiting, hand off via pending_msg and wake it.
    if (self.recv_queue.popFirst()) |r| {
        var transferred = msg;
        transferCaps(&transferred, current_task.task, r);
        self.pending_msg = transferred;
        self.lock.unlock();
        r.wakeFromBlocked();
        return;
    }

    // No receiver yet, so we park ourselves on the send queue. recv() reads ipc_message.
    self.send_queue.wait(&self.lock);
}

/// Block until a message arrives, then return it.
///
/// Prefers call-mode senders over fire-and-forget senders.
/// When a call-mode sender is dequeued, `pending_sender` is set and the sender
/// remains parked; the caller should eventually call `reply` or `replyRecv`.
pub fn recv(self: *Endpoint) Message {
    const current_task: innigkeit.Task.Current = .get();
    self.lock.lock();

    // Prefer call-mode senders (they are waiting for a reply).
    if (self.call_queue.popFirst()) |caller| {
        var msg = caller.ipc_message;
        transferCaps(&msg, caller, current_task.task);
        self.pending_msg = msg;
        self.pending_sender = caller;
        self.lock.unlock();
        // caller stays parked, they will be woken by reply/replyRecv.
        return msg;
    }

    // Fall back to fire-and-forget senders.
    if (self.send_queue.popFirst()) |s| {
        var msg = s.ipc_message;
        transferCaps(&msg, s, current_task.task);
        self.lock.unlock();
        s.wakeFromBlocked();
        return msg;
    }

    // No sender yet, park on the recv queue.
    // The sender that wakes us will have written pending_msg
    // (with transferred caps) before calling wakeFromBlocked.
    self.recv_queue.wait(&self.lock);
    self.lock.lock();
    const msg = self.pending_msg;
    // If a call()-mode sender woke us, pending_sender is set. Since recv() has
    // no way to return a Reply cap to the caller, wake the sender with an empty
    // reply to prevent it from blocking forever (M-2 / H-1 fix).
    if (self.pending_sender) |s| {
        self.pending_sender = null;
        s.ipc_message = .{};
        s.wakeFromBlocked();
    }
    self.lock.unlock();
    return msg;
}

/// Synchronous send: block until a receiver picks up the message AND sends a reply.
///
/// The caller parks in `call_queue`. When a receiver calls `recv`, it finds this
/// task, reads `task.ipc_message`, sets `pending_sender`, and leaves the caller
/// parked. The receiver must subsequently call `reply` or `replyRecv` to unblock
/// the caller. The reply message is placed in `task.ipc_message` and then read
/// after the task unblocks.
pub fn call(self: *Endpoint, msg: Message) Message {
    const current_task: innigkeit.Task.Current = .get();
    current_task.task.ipc_message = msg;

    self.lock.lock();

    if (self.recv_queue.popFirst()) |receiver| {
        // Receiver is already waiting. Transfer caps and set up reply handoff.
        var transferred = msg;
        transferCaps(&transferred, current_task.task, receiver);
        self.pending_msg = transferred;
        self.pending_sender = current_task.task;
        receiver.wakeFromBlocked();
        // Park directly via the scheduler (not call_queue) so the node is clean.
        parkAndUnlock(&self.lock);
        return current_task.task.ipc_message;
    }

    // No receiver yet; park in call_queue so a future recv() can find us.
    self.call_queue.wait(&self.lock);
    return current_task.task.ipc_message;
}

/// Block the current task and unlock `spinlock` atomically via the scheduler's
/// deferred-action mechanism. Mirrors what WaitQueue.wait() does internally,
/// but without appending to any queue (used when the task is tracked via
/// pending_sender instead).
fn parkAndUnlock(spinlock: *innigkeit.sync.TicketSpinLock) void {
    var scheduler_handle = innigkeit.Task.Scheduler.Handle.get();
    defer scheduler_handle.unlock();
    scheduler_handle.block(.{
        .action = struct {
            fn action(old_task: *innigkeit.Task, arg: usize) void {
                const lock: *innigkeit.sync.TicketSpinLock = @ptrFromInt(arg);
                old_task.state = .blocked;
                old_task.spinlocks_held -= 1;
                _ = old_task.interrupt_disable_count.fetchSub(1, .acq_rel);
                lock.unsafeUnlock();
            }
        }.action,
        .arg = @intFromPtr(spinlock),
    });
}

/// Send a reply to the pending call-mode sender, then unblock them.
///
/// Must only be called after `recv` returned a message from a call-mode sender
/// (i.e. `pending_sender != null`). Asserts this is the case.
pub fn reply(self: *Endpoint, msg: Message) error{NoPendingSender}!void {
    const current_task: innigkeit.Task.Current = .get();
    self.lock.lock();
    const sender = self.pending_sender orelse {
        self.lock.unlock();
        return error.NoPendingSender;
    };
    self.pending_sender = null;
    var transferred = msg;
    transferCaps(&transferred, current_task.task, sender);
    sender.ipc_message = transferred;
    // wakeFromBlocked takes the scheduler lock (not self.lock), safe to call here.
    sender.wakeFromBlocked();
    self.lock.unlock();
}

/// Atomically reply to the pending call-mode sender, then immediately block
/// waiting for the next incoming message.
///
/// This is the hot-path for server tasks: one call handles the previous request
/// and re-arms for the next without releasing the server's timeslice.
pub fn replyRecv(self: *Endpoint, reply_msg: Message) Message {
    const current_task: innigkeit.Task.Current = .get();
    self.lock.lock();

    // Reply to the pending sender (if any), transferring caps from server to caller.
    if (self.pending_sender) |sender| {
        self.pending_sender = null;
        var transferred = reply_msg;
        transferCaps(&transferred, current_task.task, sender);
        sender.ipc_message = transferred;
        sender.wakeFromBlocked();
    }

    // Now behave exactly like recv().
    if (self.call_queue.popFirst()) |caller| {
        var msg = caller.ipc_message;
        transferCaps(&msg, caller, current_task.task);
        self.pending_msg = msg;
        self.pending_sender = caller;
        self.lock.unlock();
        return msg;
    }

    if (self.send_queue.popFirst()) |s| {
        var msg = s.ipc_message;
        transferCaps(&msg, s, current_task.task);
        self.lock.unlock();
        s.wakeFromBlocked();
        return msg;
    }

    self.recv_queue.wait(&self.lock);
    self.lock.lock();
    const msg = self.pending_msg;
    self.lock.unlock();
    return msg;
}

/// Result of a recvCall: the received message plus a pointer to the task that
/// sent it via `call`. `sender` is null for fire-and-forget senders.
pub const RecvCallResult = struct {
    msg: Message,
    /// Non-null when the sender used `call` and is waiting for a reply.
    /// The caller is responsible for creating a Reply capability for this task.
    /// This field is intentionally NOT stored in pending_sender: responsibility
    /// is transferred to the Reply cap, so the Endpoint is clean for re-use.
    sender: ?*innigkeit.Task,
};

/// Like `recv`, but hands off call-mode sender ownership to the caller instead
/// of storing it in `pending_sender`.
///
/// This is the preferred path when the receiver wants a Reply capability: the
/// returned `sender` pointer is wrapped in a Reply cap, allowing correct cleanup
/// if the receiver dies before calling reply.
pub fn recvCall(self: *Endpoint) RecvCallResult {
    const current_task: innigkeit.Task.Current = .get();
    self.lock.lock();

    if (self.call_queue.popFirst()) |caller| {
        var msg = caller.ipc_message;
        transferCaps(&msg, caller, current_task.task);
        // Do NOT set pending_sender: ownership goes to the Reply cap.
        self.lock.unlock();
        return .{ .msg = msg, .sender = caller };
    }

    if (self.send_queue.popFirst()) |s| {
        var msg = s.ipc_message;
        transferCaps(&msg, s, current_task.task);
        self.lock.unlock();
        s.wakeFromBlocked();
        return .{ .msg = msg, .sender = null };
    }

    self.recv_queue.wait(&self.lock);
    self.lock.lock();
    const msg = self.pending_msg;
    // If a call()-mode sender woke us (via call()'s recv_queue fast path), take
    // ownership of pending_sender and return it so the caller can create a Reply cap.
    // Without this, pending_sender would be left non-null and a future replyRecv()
    // would deliver its reply to the wrong task (H-1 fix).
    const sender = self.pending_sender;
    self.pending_sender = null;
    self.lock.unlock();
    return .{ .msg = msg, .sender = sender };
}

/// cap_invoke operations for Endpoint.
pub const Op = enum(u64) {
    /// Fire-and-forget send; block until reciver calls recv.
    send = 0,
    /// Block until any sender arrives; returns message in words.
    /// rax = 0 on success (use recv_call to get a Reply capability for call-mode senders).
    recv = 1,
    /// Synchronous call; blocks until receiver replies. Returns reply in words.
    call = 2,
    /// Reply to the pending call-mode sender. words[0..5] = reply payload.
    reply = 3,
    /// Atomically reply to pending sender then block for the next message.
    reply_recv = 4,
    /// Like recv, but returns a Reply capability handle in rax for call-mode senders.
    /// rax = reply_handle (>= 0) for call-mode; rax = invalid_handle for fire-and-forget.
    recv_call = 5,
};

const testing = @import("std").testing;

test "endpoint: reply with no pending call-mode sender returns NoPendingSender" {
    const ep = try Endpoint.create();
    defer ep.unref();
    try testing.expectError(error.NoPendingSender, ep.reply(.{}));
}

test "endpoint: generation starts at zero" {
    const ep = try Endpoint.create();
    defer ep.unref();
    try testing.expectEqual(@as(u32, 0), ep.generation.load(.acquire));
}
