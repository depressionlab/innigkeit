//! Handlers for the UDP networking syscalls.
//!
//! Syscall numbers and ABI:
//!   41  net_set_ip(ip: u32) -> 0
//!         ip is packed big-endian IPv4 (192.168.1.10 = 0xC0A8010A).
//!   42  net_get_mac(buf_ptr: usize) -> 0|ENODEV
//!         Writes 6 bytes (MAC address) to buf_ptr.
//!   43  net_udp_open(port: u16) -> handle|ENOMEM|EADDRINUSE
//!         Returns a `net_socket` capability handle (full rights). Sockets are
//!         ordinary capabilities: every call below takes such a handle, needs
//!         `write` to send/close-for-everyone and `read` to receive, and a
//!         handle that is not a socket of the right protocol reads as BadHandle.
//!   44  net_udp_send(handle: u32, dst_ip: u32, dst_port: u32,
//!                    buf_ptr: usize, buf_len: usize) -> 0|error
//!   45  net_udp_recv(handle: u32, from_ptr: usize,
//!                    buf_ptr: usize, buf_len: usize) -> bytes|EAGAIN|error
//!         from_ptr -> NetFrom (8 bytes: ip[4] + port[2] + pad[2]).
//!         BLOCKS until a datagram arrives (no timeout). Returns EAGAIN only
//!         if the socket is closed (including while blocked). A non-blocking mode (flags argument) is future
//!         work; the current 4-argument layout is preserved.
//!   46  net_udp_close(handle: u32) -> 0

const innigkeit = @import("innigkeit");
const std = @import("std");
const socket = innigkeit.network.socket;

const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");
const validate = @import("../validate.zig");

const NetSocket = innigkeit.capabilities.NetSocket;
const CapabilityTable = innigkeit.capabilities.CapabilityTable;
const Rights = innigkeit.capabilities.Rights;

/// ABI struct written to the from_ptr in net_udp_recv.
const NetFrom = extern struct {
    ip: [4]u8 = @splat(0),
    port: u16 = 0,
    _pad: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(NetFrom) == 8);
    std.debug.assert(@alignOf(NetFrom) == 2);
}

/// Resolve `handle` to a socket of `kind` granting `needed`. The returned
/// object carries a reference the caller must drop with `unref`, which keeps
/// it alive across blocking operations even if the handle is closed meanwhile.
fn lookup(context: Context, handle: u32, kind: NetSocket.Kind, needed: Rights) Error.Syscall!*NetSocket {
    const cap_table = context.process().cap_table;
    cap_table.lock.lock();
    const info = cap_table.getAndRefLocked(handle) orelse {
        cap_table.lock.unlock();
        return Error.Syscall.BadHandle;
    };
    cap_table.lock.unlock();
    return NetSocket.fromSlot(info, kind, needed) catch |err| {
        @branchHint(.cold);
        CapabilityTable.unrefObject(info.cap_type, info.ptr);
        return switch (err) {
            error.WrongType, error.WrongKind => Error.Syscall.BadHandle,
            error.MissingRights => Error.Syscall.PermissionDenied,
        };
    };
}

/// Move the creation reference of `sock` into the caller's table. On failure
/// the socket is released (closing its slot) and OutOfMemory is returned.
fn publish(context: Context, sock: *NetSocket) Error.Syscall!usize {
    const cap_table = context.process().cap_table;
    cap_table.lock.lock();
    defer cap_table.lock.unlock();
    const idx = cap_table.insertLocked(.net_socket, sock, .all) catch {
        sock.unref();
        return Error.Syscall.OutOfMemory;
    };
    return idx;
}

/// Close the caller's handle. With `write` rights the socket is also shut down
/// for every other holder (waking blocked receivers); without, only this
/// handle goes away.
fn closeHandle(context: Context, handle: u32, kind: NetSocket.Kind) usize {
    const cap_table = context.process().cap_table;
    cap_table.lock.lock();
    const info = cap_table.getAndRefLocked(handle) orelse {
        cap_table.lock.unlock();
        return 0;
    };
    cap_table.lock.unlock();
    defer CapabilityTable.unrefObject(info.cap_type, info.ptr);

    const sock = NetSocket.fromSlot(info, kind, .{}) catch return 0;
    if (info.rights.write) sock.shutdown();

    cap_table.lock.lock();
    defer cap_table.lock.unlock();
    cap_table.removeLocked(handle) catch {};
    return 0;
}

pub fn netSetIp(context: Context) Error.Syscall!usize {
    const ip_be = context.arg32(.one);
    const ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, ip_be));
    innigkeit.drivers.virtio.net.setIp(ip);
    return 0;
}

pub fn netGetMac(context: Context) Error.Syscall!usize {
    const buf_ptr = context.arg(.one);
    const mac = innigkeit.drivers.virtio.net.getMac() orelse
        return Error.Syscall.NoDevice;
    try validate.copyToUser(buf_ptr, mac[0..6]);
    return 0;
}

pub fn netUdpOpen(context: Context) Error.Syscall!usize {
    const port_raw = context.arg(.one);
    const port: u16 = @truncate(port_raw);
    const sock = NetSocket.createShell(.udp) catch return Error.Syscall.OutOfMemory;
    sock.openUdp(port) catch {
        sock.unref();
        return Error.Syscall.OutOfMemory;
    };
    return publish(context, sock);
}

pub fn netUdpSend(context: Context) Error.Syscall!usize {
    const sock = try lookup(context, context.arg32(.one), .udp, .write_only);
    defer sock.unref();
    const dst_ip_u32 = context.arg(.two);
    const dst_port_raw = context.arg(.three);
    const buf_ptr = context.arg(.four);
    const buf_len = context.arg(.five);
    const dst_port: u16 = @truncate(dst_port_raw);

    const ip_be: u32 = @truncate(dst_ip_u32);
    const dst_ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, ip_be));

    if (buf_len > socket.MAX_PAYLOAD) return Error.Syscall.InvalidArgument;
    var bounce: [socket.MAX_PAYLOAD]u8 = undefined;
    try validate.copyFromUser(bounce[0..buf_len], buf_ptr);

    const ok = sock.sendUdp(dst_ip, dst_port, bounce[0..buf_len]);
    return if (ok) 0 else Error.Syscall.NoDevice;
}

pub fn netUdpRecv(context: Context) Error.Syscall!usize {
    const sock = try lookup(context, context.arg32(.one), .udp, .read_only);
    defer sock.unref();
    const from_ptr = context.arg(.two);
    const buf_ptr = context.arg(.three);
    const buf_len = context.arg(.four);

    // Validate both destinations up front so a bad buffer faults before the
    // task blocks or a datagram is consumed from the socket.
    if (!validate.userBuffer(from_ptr, @sizeOf(NetFrom))) return Error.Syscall.BadAddress;
    if (!validate.userBuffer(buf_ptr, buf_len)) return Error.Syscall.BadAddress;

    // Block until a datagram arrives, dequeuing into a kernel bounce buffer.
    // No UserAccess window is held here: the user copies happen strictly
    // after the (potentially blocking) receive, and copyToUser/writeUser
    // re-validate, so a mapping torn down while blocked yields EFAULT.
    var bounce: [socket.MAX_PAYLOAD]u8 = undefined;
    const recv_len = @min(buf_len, socket.MAX_PAYLOAD);
    var from: socket.RecvFrom = .{ .ip = @splat(0), .port = 0 };
    const bytes = sock.recvUdpBlocking(bounce[0..recv_len], &from) orelse
        return Error.Syscall.WouldBlock; // invalid id or socket closed

    try validate.copyToUser(buf_ptr, bounce[0..bytes]);
    try validate.writeUser(from_ptr, NetFrom{
        .ip = from.ip,
        .port = from.port,
        ._pad = 0,
    });

    return bytes;
}

pub fn netUdpClose(context: Context) Error.Syscall!usize {
    return closeHandle(context, context.arg32(.one), .udp);
}

/// Non-blocking variant of `netUdpRecv` (syscall 58, net_udp_recv_nb):
/// same arguments and return encoding, but returns EWOULDBLOCK immediately
/// when no datagram is queued. Used by userspace timeout polls.
pub fn netUdpRecvNb(context: Context) Error.Syscall!usize {
    const sock = try lookup(context, context.arg32(.one), .udp, .read_only);
    defer sock.unref();
    const from_ptr = context.arg(.two);
    const buf_ptr = context.arg(.three);
    const buf_len = context.arg(.four);

    if (!validate.userBuffer(from_ptr, @sizeOf(NetFrom))) return Error.Syscall.BadAddress;
    if (!validate.userBuffer(buf_ptr, buf_len)) return Error.Syscall.BadAddress;

    var bounce: [socket.MAX_PAYLOAD]u8 = undefined;
    const recv_len = @min(buf_len, socket.MAX_PAYLOAD);
    var from: socket.RecvFrom = .{ .ip = @splat(0), .port = 0 };
    const bytes = sock.recvUdp(bounce[0..recv_len], &from) orelse
        return Error.Syscall.WouldBlock;

    try validate.copyToUser(buf_ptr, bounce[0..bytes]);
    try validate.writeUser(from_ptr, NetFrom{
        .ip = from.ip,
        .port = from.port,
        ._pad = 0,
    });

    return bytes;
}

pub fn netPing(context: Context) Error.Syscall!usize {
    const ip_be = context.arg32(.one);
    const timeout_ms = context.arg64(.two);
    const dst_ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, ip_be));
    const rtt = socket.ping(dst_ip, timeout_ms) orelse
        return Error.Syscall.NoDevice;
    return rtt;
}

/// net_tcp_listen(port) -> listener_id
pub fn netTcpListen(context: Context) Error.Syscall!usize {
    const port: u16 = @truncate(context.arg(.one));
    const sock = NetSocket.createShell(.tcp) catch return Error.Syscall.OutOfMemory;
    sock.openTcpListener(port) catch {
        sock.unref();
        return Error.Syscall.OutOfMemory;
    };
    return publish(context, sock);
}

/// net_tcp_accept(listener) -> handle | WouldBlock
pub fn netTcpAccept(context: Context) Error.Syscall!usize {
    const listener = try lookup(context, context.arg32(.one), .tcp, .read_only);
    defer listener.unref();
    const child = NetSocket.createShell(.tcp) catch return Error.Syscall.OutOfMemory;
    if (!listener.accept(child)) {
        child.unref();
        return Error.Syscall.WouldBlock;
    }
    return publish(context, child);
}

/// net_tcp_connect(dst_ip, dst_port, src_port) -> handle : blocks until the
/// connection is ESTABLISHED (or fails).
pub fn netTcpConnect(context: Context) Error.Syscall!usize {
    const dst_ip_raw = context.arg32(.one);
    const dst_port: u16 = @truncate(context.arg(.two));
    const src_port: u16 = @truncate(context.arg(.three));
    const dst_ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, dst_ip_raw));
    const sock = NetSocket.createShell(.tcp) catch return Error.Syscall.OutOfMemory;
    sock.connectTcp(src_port, dst_ip, dst_port) catch |err| {
        sock.unref();
        return switch (err) {
            error.OutOfMemory => Error.Syscall.OutOfMemory,
            error.ConnectFailed => Error.Syscall.NoDevice,
        };
    };
    return publish(context, sock);
}

/// net_tcp_send(handle, buf_ptr, buf_len) -> bytes_sent (at most one MSS).
pub fn netTcpSend(context: Context) Error.Syscall!usize {
    const sock = try lookup(context, context.arg32(.one), .tcp, .write_only);
    defer sock.unref();
    const buf_ptr = context.arg(.two);
    const buf_len = context.arg(.three);
    // tcpSend transmits at most one MSS and touches the buffer under a spinlock,
    // so copy that much through a fault-safe kernel bounce buffer.
    if (!validate.userBuffer(buf_ptr, buf_len))
        return Error.Syscall.BadAddress;
    var send_buffer: [1460]u8 = undefined; // one TCP MSS
    const to_send = @min(buf_len, send_buffer.len);
    try validate.copyFromUser(send_buffer[0..to_send], buf_ptr);
    return sock.sendTcp(send_buffer[0..to_send]);
}

/// net_tcp_recv(handle, buf_ptr, buf_len) -> bytes | WouldBlock (one MSS/call).
pub fn netTcpRecv(context: Context) Error.Syscall!usize {
    const sock = try lookup(context, context.arg32(.one), .tcp, .read_only);
    defer sock.unref();
    const buf_ptr = context.arg(.two);
    const buf_len = context.arg(.three);
    if (!validate.userBuffer(buf_ptr, buf_len))
        return Error.Syscall.BadAddress;
    var recv_buffer: [1460]u8 = undefined; // one TCP MSS
    const recv_capacity = @min(buf_len, recv_buffer.len);
    const n = sock.recvTcp(recv_buffer[0..recv_capacity]);
    if (n == 0) return Error.Syscall.WouldBlock;
    try validate.copyToUser(buf_ptr, recv_buffer[0..n]);
    return n;
}

/// net_tcp_close(handle) -> 0
pub fn netTcpClose(context: Context) Error.Syscall!usize {
    return closeHandle(context, context.arg32(.one), .tcp);
}
