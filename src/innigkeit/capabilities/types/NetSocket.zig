//! A network socket capability: a UDP datagram socket, or a TCP listener or
//! connection.
//!
//! The socket tables in `network/` stay the single place where protocol state
//! lives; this object is the unforgeable handle to one table slot. Its
//! address is the slot's `network.socket.Owner`, so every table operation
//! made through it is checked against the table's own owner record, and a slot
//! that was closed (by `shutdown`, a peer reset, or reuse) can never be reached
//! through a stale handle. Because the slot id never reaches userspace, a
//! process can only touch sockets it holds a capability for, and capability
//! rights, copy, transfer and revocation apply to sockets like to any other
//! object (docs/security-audit.md F4).
//!
//! Lifetime: the last `unref` closes everything this object owns (its slot
//! and, for a listener, connections that arrived but were never accepted).
//! `shutdown` closes the slot early and wakes blocked receivers while other
//! holders still keep the (now dead) object alive.
const NetSocket = @This();

const innigkeit = @import("innigkeit");
const std = @import("std");

const socket = innigkeit.network.socket;

pub const Kind = enum(u8) { udp, tcp };

/// Revocation generation counter (see `Notify.generation`).
generation: std.atomic.Value(u32) = .init(0),
refcount: std.atomic.Value(usize) = .init(1),
kind: Kind,
/// Slot in the table `kind` selects. Set once, before the object is
/// published to a capability table; afterwards read-only.
id: u8 = 0,
/// False for a shell created ahead of a table slot (`createShell`) that never
/// received one, so `destroy` has nothing to close for `id`.
has_slot: bool = false,

/// Allocate an object that does not own a table slot yet. Callers that need the
/// slot's owner identity before opening it (every open does) create the shell
/// first, then call `open*`/`adopt*`.
pub fn createShell(kind: Kind) error{OutOfMemory}!*NetSocket {
    const self = try innigkeit.memory.heap.allocator.create(NetSocket);
    self.* = .{ .kind = kind };
    return self;
}

pub fn ref(self: *NetSocket) void {
    _ = self.refcount.fetchAdd(1, .acq_rel);
}

pub fn unref(self: *NetSocket) void {
    if (self.refcount.fetchSub(1, .acq_rel) != 1) return;
    self.shutdown();
    // Connections that arrived on a listener but were never accepted still
    // carry this object as their owner; nothing else can ever close them.
    socket.closeAllOwnedBy(self.owner());
    innigkeit.memory.heap.allocator.destroy(self);
}

/// The identity every table operation through this object is checked against.
pub fn owner(self: *const NetSocket) socket.Owner {
    return .of(self);
}

/// Close the socket now, waking any task blocked on it. Idempotent, and a no-op
/// for a slot that is already gone.
pub fn shutdown(self: *NetSocket) void {
    if (!self.has_slot) return;
    switch (self.kind) {
        .udp => socket.closeSocket(self.owner(), self.id),
        .tcp => socket.closeTcp(self.owner(), self.id),
    }
}

// ---- opening ---------------------------------------------------------------

pub fn openUdp(self: *NetSocket, port: u16) error{OutOfMemory}!void {
    std.debug.assert(self.kind == .udp and !self.has_slot);
    self.id = socket.openSocket(self.owner(), port) orelse return error.OutOfMemory;
    self.has_slot = true;
}

pub fn openTcpListener(self: *NetSocket, port: u16) error{OutOfMemory}!void {
    std.debug.assert(self.kind == .tcp and !self.has_slot);
    self.id = socket.openTcpListener(self.owner(), port) orelse return error.OutOfMemory;
    self.has_slot = true;
}

/// Start connecting and block until ESTABLISHED. On failure the object has no
/// slot (it was closed again) and the caller just drops it.
pub fn connectTcp(self: *NetSocket, src_port: u16, dst_ip: [4]u8, dst_port: u16) error{ OutOfMemory, ConnectFailed }!void {
    std.debug.assert(self.kind == .tcp and !self.has_slot);
    self.id = socket.openTcpConnect(self.owner(), src_port, dst_ip, dst_port) orelse return error.OutOfMemory;
    self.has_slot = true;
    if (!socket.tcpWaitConnected(self.owner(), self.id)) {
        self.shutdown();
        self.has_slot = false;
        return error.ConnectFailed;
    }
}

/// Block until a connection arrives on this listener and move it into `child`,
/// a fresh `.tcp` shell. Null if the listener is closed (also while waiting)
/// or `child` could not take over the connection.
pub fn accept(self: *NetSocket, child: *NetSocket) bool {
    std.debug.assert(self.kind == .tcp and child.kind == .tcp and !child.has_slot);
    const child_id = socket.tcpAccept(self.owner(), self.id) orelse return false;
    if (!socket.tcpReown(self.owner(), child.owner(), child_id)) return false;
    child.id = child_id;
    child.has_slot = true;
    return true;
}

// ---- UDP -------------------------------------------------------------------

pub fn sendUdp(self: *NetSocket, dst_ip: [4]u8, dst_port: u16, data: []const u8) bool {
    return socket.sendUdp(self.owner(), self.id, dst_ip, dst_port, data);
}

/// Null when no datagram is queued, or the socket is closed.
pub fn recvUdp(self: *NetSocket, buf: []u8, from: *socket.RecvFrom) ?u16 {
    return socket.recvUdp(self.owner(), self.id, buf, from);
}

/// Blocks. Null when the socket is closed (also while waiting).
pub fn recvUdpBlocking(self: *NetSocket, buf: []u8, from: *socket.RecvFrom) ?u16 {
    return socket.recvUdpBlocking(self.owner(), self.id, buf, from);
}

// ---- TCP -------------------------------------------------------------------

pub fn sendTcp(self: *NetSocket, data: []const u8) usize {
    return socket.tcpSend(self.owner(), self.id, data);
}

/// Zero when nothing is buffered, or the socket is closed.
pub fn recvTcp(self: *NetSocket, buf: []u8) u16 {
    return socket.tcpRecv(self.owner(), self.id, buf);
}

// ---- capability-table glue -------------------------------------------------

const CapabilityTable = @import("../CapabilityTable.zig");
const Rights = @import("../Rights.zig").Rights;

pub const FromSlotError = error{
    /// The slot holds a different kind of capability.
    WrongType,
    /// The slot holds a socket, but of the other protocol.
    WrongKind,
    /// The slot's rights do not include everything `needed` asks for.
    MissingRights,
};

/// Interpret a looked-up slot as a socket of `kind` that grants at least
/// `needed`. Does not touch reference counts: the caller already holds the
/// reference `getAndRefLocked` took.
pub fn fromSlot(info: CapabilityTable.SlotInfo, kind: Kind, needed: Rights) FromSlotError!*NetSocket {
    if (info.cap_type != .net_socket) return error.WrongType;
    const self: *NetSocket = @ptrCast(@alignCast(info.ptr));
    if (self.kind != kind) return error.WrongKind;
    const have: u16 = @bitCast(info.rights);
    const want: u16 = @bitCast(needed);
    if (have & want != want) return error.MissingRights;
    return self;
}

test "fromSlot: wrong capability type, wrong protocol and missing rights are rejected" {
    const udp = try createShell(.udp);
    defer udp.unref();

    const info: CapabilityTable.SlotInfo = .{ .cap_type = .net_socket, .ptr = udp, .rights = .{ .read = true } };
    try std.testing.expectEqual(udp, try fromSlot(info, .udp, .read_only));
    try std.testing.expectError(error.WrongKind, fromSlot(info, .tcp, .read_only));
    try std.testing.expectError(error.MissingRights, fromSlot(info, .udp, .write_only));
    try std.testing.expectError(error.MissingRights, fromSlot(info, .udp, .{ .read = true, .write = true }));

    const not_a_socket: CapabilityTable.SlotInfo = .{ .cap_type = .notify, .ptr = udp, .rights = .all };
    try std.testing.expectError(error.WrongType, fromSlot(not_a_socket, .udp, .{}));
}

test "NetSocket: handles are isolated from each other" {
    const a = try createShell(.udp);
    defer a.unref();
    try a.openUdp(40010);
    const b = try createShell(.udp);
    defer b.unref();
    try b.openUdp(40011);

    var buf: [8]u8 = undefined;
    var from: socket.RecvFrom = .{ .ip = @splat(0), .port = 0 };

    socket.deliverUdp(.{ 10, 0, 0, 1 }, 7, 40010, "a-only");
    try std.testing.expectEqual(@as(?u16, null), b.recvUdp(&buf, &from));

    // Shutting b down does not disturb a.
    b.shutdown();
    try std.testing.expectEqual(@as(?u16, 6), a.recvUdp(&buf, &from));
    try std.testing.expectEqualStrings("a-only", buf[0..6]);
}

test "NetSocket: shutdown is idempotent and the last unref frees the slot" {
    const first = try createShell(.udp);
    try first.openUdp(40012);
    const id = first.id;
    first.ref();
    first.shutdown();
    first.shutdown();
    first.unref();
    first.unref(); // last reference: destroys the object

    // The slot is free again for the next socket.
    const second = try createShell(.udp);
    defer second.unref();
    try second.openUdp(40013);
    try std.testing.expectEqual(id, second.id);
}
