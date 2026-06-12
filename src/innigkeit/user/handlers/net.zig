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

const std = @import("std");
const innigkeit = @import("innigkeit");
const validate = @import("../validate.zig");
const socket = innigkeit.net.socket;

const validateUserBuffer = validate.validateUserBuffer;

inline fn errCode(code: i64) usize {
    return @bitCast(code);
}

const e = struct {
    const EPERM: i64 = -1;
    const ENODEV: i64 = -19;
    const ENOMEM: i64 = -12;
    const EFAULT: i64 = -14;
    const EINVAL: i64 = -22;
    const EWOULDBLOCK: i64 = -11;
    const ENOSPC: i64 = -28;
};

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

pub fn syscallNetSetIp(ip_u32: usize) usize {
    const ip_be: u32 = @truncate(ip_u32);
    const ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, ip_be));
    innigkeit.drivers.virtio.net.setIp(ip);
    return 0;
}

pub fn syscallNetGetMac(buf_ptr: usize, current_task: innigkeit.Task.Current) usize {
    _ = current_task;
    const mac = innigkeit.drivers.virtio.net.getMac() orelse return errCode(e.ENODEV);
    validate.copyToUser(buf_ptr, mac[0..6]) catch return errCode(e.EFAULT);
    return 0;
}

pub fn syscallNetUdpOpen(port_raw: usize) usize {
    const port: u16 = @truncate(port_raw);
    const id = socket.openSocket(port) orelse return errCode(e.ENOMEM);
    return id;
}

pub fn syscallNetUdpSend(
    sock_id: usize,
    dst_ip_u32: usize,
    dst_port_raw: usize,
    buf_ptr: usize,
    buf_len: usize,
    current_task: innigkeit.Task.Current,
) usize {
    _ = current_task;
    const id: u8 = @intCast(sock_id & 0xFF);
    const dst_port: u16 = @truncate(dst_port_raw);

    const ip_be: u32 = @truncate(dst_ip_u32);
    const dst_ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, ip_be));

    if (buf_len > socket.MAX_PAYLOAD) return errCode(e.EINVAL);
    var bounce: [socket.MAX_PAYLOAD]u8 = undefined;
    validate.copyFromUser(bounce[0..buf_len], buf_ptr) catch return errCode(e.EFAULT);

    const ok = socket.sendUdp(id, dst_ip, dst_port, bounce[0..buf_len]);
    return if (ok) 0 else errCode(e.ENODEV);
}

pub fn syscallNetUdpRecv(
    sock_id: usize,
    from_ptr: usize,
    buf_ptr: usize,
    buf_len: usize,
    current_task: innigkeit.Task.Current,
) usize {
    _ = current_task;
    const id: u8 = @intCast(sock_id & 0xFF);

    // Validate both destinations up front so a bad buffer faults before the
    // task blocks or a datagram is consumed from the socket.
    if (!validateUserBuffer(from_ptr, @sizeOf(NetFrom))) return errCode(e.EFAULT);
    if (!validateUserBuffer(buf_ptr, buf_len)) return errCode(e.EFAULT);

    // Block until a datagram arrives, dequeuing into a kernel bounce buffer.
    // No UserAccess window is held here: the user copies happen strictly
    // after the (potentially blocking) receive, and copyToUser/writeUser
    // re-validate, so a mapping torn down while blocked yields EFAULT.
    var bounce: [socket.MAX_PAYLOAD]u8 = undefined;
    const recv_len = @min(buf_len, socket.MAX_PAYLOAD);
    var from: socket.RecvFrom = .{ .ip = .{0} ** 4, .port = 0 };
    const bytes = socket.recvUdpBlocking(id, bounce[0..recv_len], &from) orelse
        return errCode(e.EWOULDBLOCK); // invalid id or socket closed

    validate.copyToUser(buf_ptr, bounce[0..bytes]) catch
        return errCode(e.EFAULT);
    validate.writeUser(from_ptr, NetFrom{
        .ip = from.ip,
        .port = from.port,
        ._pad = 0,
    }) catch return errCode(e.EFAULT);

    return bytes;
}

pub fn syscallNetUdpClose(sock_id: usize) usize {
    socket.closeSocket(@intCast(sock_id & 0xFF));
    return 0;
}

/// Non-blocking variant of `syscallNetUdpRecv` (syscall 58, net_udp_recv_nb):
/// same arguments and return encoding, but returns EWOULDBLOCK immediately
/// when no datagram is queued. Used by userspace timeout polls.
pub fn syscallNetUdpRecvNb(
    sock_id: usize,
    from_ptr: usize,
    buf_ptr: usize,
    buf_len: usize,
) usize {
    const id: u8 = @intCast(sock_id & 0xFF);

    if (!validateUserBuffer(from_ptr, @sizeOf(NetFrom))) return errCode(e.EFAULT);
    if (!validateUserBuffer(buf_ptr, buf_len)) return errCode(e.EFAULT);

    var bounce: [socket.MAX_PAYLOAD]u8 = undefined;
    const recv_len = @min(buf_len, socket.MAX_PAYLOAD);
    var from: socket.RecvFrom = .{ .ip = .{0} ** 4, .port = 0 };
    const bytes = socket.recvUdp(id, bounce[0..recv_len], &from) orelse
        return errCode(e.EWOULDBLOCK);

    validate.copyToUser(buf_ptr, bounce[0..bytes]) catch
        return errCode(e.EFAULT);
    validate.writeUser(from_ptr, NetFrom{
        .ip = from.ip,
        .port = from.port,
        ._pad = 0,
    }) catch return errCode(e.EFAULT);

    return bytes;
}

pub fn syscallNetPing(dst_ip_u32: usize, timeout_ms_raw: usize) usize {
    const ip_be: u32 = @truncate(dst_ip_u32);
    const dst_ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, ip_be));
    const timeout_ms: u64 = @intCast(timeout_ms_raw);
    const rtt = socket.ping(dst_ip, timeout_ms) orelse return errCode(e.ENODEV);
    return rtt;
}
