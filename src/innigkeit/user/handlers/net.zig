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
//!         Returns EAGAIN if no data is available.
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
    const mac = innigkeit.drivers.virtio.net.getMac() orelse return errCode(e.ENODEV);
    if (!validateUserBuffer(buf_ptr, 6)) return errCode(e.EFAULT);
    current_task.incrementEnableAccessToUserMemory();
    const dst: [*]u8 = @ptrFromInt(buf_ptr);
    @memcpy(dst[0..6], mac);
    current_task.decrementEnableAccessToUserMemory();
    return 0;
}

pub fn syscallNetUdpOpen(port_raw: usize) usize {
    const port: u16 = @truncate(port_raw);
    const id = socket.openSocket(port) orelse return errCode(e.ENOMEM);
    return id;
}

pub fn syscallNetUdpSend(sock_id: usize, dst_ip_u32: usize, dst_port_raw: usize, buf_ptr: usize, buf_len: usize, current_task: innigkeit.Task.Current) usize {
    const id: u8 = @intCast(sock_id & 0xFF);
    const dst_port: u16 = @truncate(dst_port_raw);

    const ip_be: u32 = @truncate(dst_ip_u32);
    const dst_ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, ip_be));

    if (buf_len > socket.MAX_PAYLOAD) return errCode(e.EINVAL);
    if (!validateUserBuffer(buf_ptr, buf_len)) return errCode(e.EFAULT);

    var bounce: [socket.MAX_PAYLOAD]u8 = undefined;
    current_task.incrementEnableAccessToUserMemory();
    @memcpy(bounce[0..buf_len], @as([*]const u8, @ptrFromInt(buf_ptr))[0..buf_len]);
    current_task.decrementEnableAccessToUserMemory();

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
    const id: u8 = @intCast(sock_id & 0xFF);

    if (!validateUserBuffer(from_ptr, @sizeOf(NetFrom))) return errCode(e.EFAULT);
    if (!validateUserBuffer(buf_ptr, buf_len)) return errCode(e.EFAULT);

    var bounce: [socket.MAX_PAYLOAD]u8 = undefined;
    const recv_len = @min(buf_len, socket.MAX_PAYLOAD);
    var from: socket.RecvFrom = .{ .ip = .{0} ** 4, .port = 0 };
    const bytes = socket.recvUdp(id, bounce[0..recv_len], &from) orelse return errCode(e.EWOULDBLOCK);

    current_task.incrementEnableAccessToUserMemory();
    @memcpy(@as([*]u8, @ptrFromInt(buf_ptr))[0..bytes], bounce[0..bytes]);
    const nf: *NetFrom = @ptrFromInt(from_ptr);
    nf.ip = from.ip;
    nf.port = from.port;
    nf._pad = 0;
    current_task.decrementEnableAccessToUserMemory();

    return bytes;
}

pub fn syscallNetUdpClose(sock_id: usize) usize {
    socket.closeSocket(@intCast(sock_id & 0xFF));
    return 0;
}

pub fn syscallNetPing(dst_ip_u32: usize, timeout_ms_raw: usize) usize {
    const ip_be: u32 = @truncate(dst_ip_u32);
    const dst_ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, ip_be));
    const timeout_ms: u64 = @intCast(timeout_ms_raw);
    const rtt = socket.ping(dst_ip, timeout_ms) orelse return errCode(e.ENODEV);
    return rtt;
}
