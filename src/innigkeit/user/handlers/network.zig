//! Handlers for the UDP networking syscalls.
//!
//! Syscall numbers and ABI:
//!   41  net_set_ip(ip: u32) -> 0
//!         ip is packed big-endian IPv4 (192.168.1.10 = 0xC0A8010A).
//!   42  net_get_mac(buf_ptr: usize) -> 0|ENODEV
//!         Writes 6 bytes (MAC address) to buf_ptr.
//!   43  net_udp_open(port: u16) -> sock_id|ENOMEM|EADDRINUSE
//!         Returns a socket id in 0..15.
//!   44  net_udp_send(sock_id: u32, dst_ip: u32, dst_port: u32,
//!                    buf_ptr: usize, buf_len: usize) -> 0|error
//!   45  net_udp_recv(sock_id: u32, from_ptr: usize,
//!                    buf_ptr: usize, buf_len: usize) -> bytes|EAGAIN|error
//!         from_ptr -> NetFrom (8 bytes: ip[4] + port[2] + pad[2]).
//!         BLOCKS until a datagram arrives (no timeout). Returns EAGAIN only
//!         if the socket id is invalid or the socket is closed (including
//!         while blocked). A non-blocking mode (flags argument) is future
//!         work; the current 4-argument layout is preserved.
//!   46  net_udp_close(sock_id: u32) -> 0

const innigkeit = @import("innigkeit");
const std = @import("std");
const socket = innigkeit.network.socket;

const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");
const validate = @import("../validate.zig");

/// ABI struct written to the from_ptr in net_udp_recv.
const NetFrom = extern struct {
    ip: [4]u8 = .{0} ** 4,
    port: u16 = 0,
    _pad: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(NetFrom) == 8);
    std.debug.assert(@alignOf(NetFrom) == 2);
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
    const id = socket.openSocket(port) orelse
        return Error.Syscall.OutOfMemory;
    return id;
}

pub fn netUdpSend(context: Context) Error.Syscall!usize {
    const sock_id = context.arg(.one);
    const dst_ip_u32 = context.arg(.two);
    const dst_port_raw = context.arg(.three);
    const buf_ptr = context.arg(.four);
    const buf_len = context.arg(.five);
    const id: u8 = @intCast(sock_id & 0xFF);
    const dst_port: u16 = @truncate(dst_port_raw);

    const ip_be: u32 = @truncate(dst_ip_u32);
    const dst_ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, ip_be));

    if (buf_len > socket.MAX_PAYLOAD) return Error.Syscall.InvalidArgument;
    var bounce: [socket.MAX_PAYLOAD]u8 = undefined;
    try validate.copyFromUser(bounce[0..buf_len], buf_ptr);

    const ok = socket.sendUdp(id, dst_ip, dst_port, bounce[0..buf_len]);
    return if (ok) 0 else Error.Syscall.NoDevice;
}

pub fn netUdpRecv(context: Context) Error.Syscall!usize {
    const sock_id = context.arg(.one);
    const from_ptr = context.arg(.two);
    const buf_ptr = context.arg(.three);
    const buf_len = context.arg(.four);
    const id: u8 = @intCast(sock_id & 0xFF);

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
    var from: socket.RecvFrom = .{ .ip = .{0} ** 4, .port = 0 };
    const bytes = socket.recvUdpBlocking(id, bounce[0..recv_len], &from) orelse
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
    const sock_id = context.arg(.one);
    socket.closeSocket(@intCast(sock_id & 0xFF));
    return 0;
}

/// Non-blocking variant of `netUdpRecv` (syscall 58, net_udp_recv_nb):
/// same arguments and return encoding, but returns EWOULDBLOCK immediately
/// when no datagram is queued. Used by userspace timeout polls.
pub fn netUdpRecvNb(context: Context) Error.Syscall!usize {
    const sock_id = context.arg(.one);
    const from_ptr = context.arg(.two);
    const buf_ptr = context.arg(.three);
    const buf_len = context.arg(.four);
    const id: u8 = @intCast(sock_id & 0xFF);

    if (!validate.userBuffer(from_ptr, @sizeOf(NetFrom))) return Error.Syscall.BadAddress;
    if (!validate.userBuffer(buf_ptr, buf_len)) return Error.Syscall.BadAddress;

    var bounce: [socket.MAX_PAYLOAD]u8 = undefined;
    const recv_len = @min(buf_len, socket.MAX_PAYLOAD);
    var from: socket.RecvFrom = .{ .ip = .{0} ** 4, .port = 0 };
    const bytes = socket.recvUdp(id, bounce[0..recv_len], &from) orelse
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
    return socket.openTcpListener(port) orelse Error.Syscall.OutOfMemory;
}

/// net_tcp_accept(listener_id) -> sock_id | WouldBlock
pub fn netTcpAccept(context: Context) Error.Syscall!usize {
    const lid: u8 = @truncate(context.arg(.one));
    return socket.tcpAccept(lid) orelse Error.Syscall.WouldBlock;
}

/// net_tcp_connect(dst_ip, dst_port, src_port) -> sock_id : blocks until the
/// connection is ESTABLISHED (or fails).
pub fn netTcpConnect(context: Context) Error.Syscall!usize {
    const dst_ip_raw = context.arg32(.one);
    const dst_port: u16 = @truncate(context.arg(.two));
    const src_port: u16 = @truncate(context.arg(.three));
    const dst_ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, dst_ip_raw));
    const id = socket.openTcpConnect(src_port, dst_ip, dst_port) orelse
        return Error.Syscall.OutOfMemory;
    if (!socket.tcpWaitConnected(id)) {
        socket.closeTcp(id);
        return Error.Syscall.NoDevice;
    }
    return id;
}

/// net_tcp_send(sock_id, buf_ptr, buf_len) -> bytes_sent (at most one MSS).
pub fn netTcpSend(context: Context) Error.Syscall!usize {
    const sock_id: u8 = @truncate(context.arg(.one));
    const buf_ptr = context.arg(.two);
    const buf_len = context.arg(.three);
    // tcpSend transmits at most one MSS and touches the buffer under a spinlock,
    // so copy that much through a fault-safe kernel bounce buffer.
    if (!validate.userBuffer(buf_ptr, buf_len))
        return Error.Syscall.BadAddress;
    var send_buffer: [1460]u8 = undefined; // one TCP MSS
    const to_send = @min(buf_len, send_buffer.len);
    try validate.copyFromUser(send_buffer[0..to_send], buf_ptr);
    return socket.tcpSend(sock_id, send_buffer[0..to_send]);
}

/// net_tcp_recv(sock_id, buf_ptr, buf_len) -> bytes | WouldBlock (one MSS/call).
pub fn netTcpRecv(context: Context) Error.Syscall!usize {
    const sock_id: u8 = @truncate(context.arg(.one));
    const buf_ptr = context.arg(.two);
    const buf_len = context.arg(.three);
    if (!validate.userBuffer(buf_ptr, buf_len))
        return Error.Syscall.BadAddress;
    var recv_buffer: [1460]u8 = undefined; // one TCP MSS
    const recv_capacity = @min(buf_len, recv_buffer.len);
    const n = socket.tcpRecv(sock_id, recv_buffer[0..recv_capacity]);
    if (n == 0) return Error.Syscall.WouldBlock;
    try validate.copyToUser(buf_ptr, recv_buffer[0..n]);
    return n;
}

/// net_tcp_close(sock_id) -> 0
pub fn netTcpClose(context: Context) Error.Syscall!usize {
    const sock_id: u8 = @truncate(context.arg(.one));
    socket.closeTcp(sock_id);
    return 0;
}
