//! Userspace UDP networking library.
//!
//! ## Usage:
//! ```zig
//! // Configure the NIC (once at startup).
//! innigkeit.net.setIp(.{ 192, 168, 1, 10 });
//!
//! // Open a UDP socket.
//! var sock = try innigkeit.net.UdpSocket.open(5000);
//! defer sock.close();
//!
//! // Send a datagram.
//! try sock.send(.{ 192, 168, 1, 1 }, 5001, "hello");
//!
//! // Receive (blocking loop with sleep).
//! var buf: [1472]u8 = undefined;
//! var from: innigkeit.net.From = undefined;
//! while (true) {
//!     const n = sock.recv(&from, &buf) catch {
//!         innigkeit.sleep(5 * std.time.ns_per_ms);
//!         continue;
//!     };
//!     // process buf[0..n]
//! }
//! ```

const std = @import("std");
const innigkeit = @import("innigkeit");
const Syscall = innigkeit.Syscall;

/// IPv4 address as 4 bytes, MSB first (standard network order).
pub const Ip4 = [4]u8;

/// Sender address filled by recv().
pub const From = extern struct {
    ip: Ip4 = .{0} ** 4,
    port: u16 = 0,
    _pad: u16 = 0,
};

/// Set the NIC's IPv4 address.
/// Call once at startup before any send/recv.
pub fn setIp(ip: Ip4) void {
    const ip_u32: u32 = std.mem.readInt(u32, &ip, .big);
    _ = Syscall.invoke(.net_set_ip, .{@as(usize, ip_u32)});
}

/// Read the NIC's MAC address. Returns null if no NIC is present.
pub fn getMac() ?[6]u8 {
    var mac: [6]u8 = undefined;
    const r = Syscall.invoke(.net_get_mac, .{@intFromPtr(&mac)});
    if (r < 0) return null;
    return mac;
}

/// Send one ICMP echo request and return the RTT in ms.
/// Returns `error.NoDevice` on timeout or if no NIC is present.
pub fn ping(dst_ip: Ip4, timeout_ms: u32) Syscall.Error!u64 {
    const ip_u32: u32 = std.mem.readInt(u32, &dst_ip, .big);
    const r = Syscall.invoke(.net_ping, .{ @as(usize, ip_u32), @as(usize, timeout_ms) });
    return Syscall.decode(r);
}

/// A bound UDP socket.
pub const UdpSocket = struct {
    id: u32,

    /// Open a UDP socket bound to `port`.
    pub fn open(port: u16) Syscall.Error!UdpSocket {
        const r = Syscall.invoke(.net_udp_open, .{@as(usize, port)});
        const id = try Syscall.decode(r);
        return .{ .id = @intCast(id) };
    }

    /// Send `data` to `dst_ip:dst_port`.
    pub fn send(self: UdpSocket, dst_ip: Ip4, dst_port: u16, data: []const u8) Syscall.Error!void {
        const ip_u32: u32 = std.mem.readInt(u32, &dst_ip, .big);
        const r = Syscall.invoke(.net_udp_send, .{
            @as(usize, self.id),
            @as(usize, ip_u32),
            @as(usize, dst_port),
            @intFromPtr(data.ptr),
            data.len,
        });
        _ = try Syscall.decode(r);
    }

    /// Blocking receive. Fills `from` and `buf[0..n]`; blocks until a
    /// datagram arrives. Returns `error.WouldBlock` only if the socket is
    /// invalid or closed.
    pub fn recv(self: UdpSocket, from: *From, buf: []u8) Syscall.Error!usize {
        const r = Syscall.invoke(.net_udp_recv, .{
            @as(usize, self.id),
            @intFromPtr(from),
            @intFromPtr(buf.ptr),
            buf.len,
        });
        return Syscall.decode(r);
    }

    /// Non-blocking receive. Fills `from` and `buf[0..n]`.
    /// Returns `error.WouldBlock` immediately if no data is available.
    pub fn recvNonblocking(self: UdpSocket, from: *From, buf: []u8) Syscall.Error!usize {
        const r = Syscall.invoke(.net_udp_recv_nb, .{
            @as(usize, self.id),
            @intFromPtr(from),
            @intFromPtr(buf.ptr),
            buf.len,
        });
        return Syscall.decode(r);
    }

    /// Receive with nanosecond timeout.
    /// Polls non-blocking and sleeps 5 ms between polls; returns
    /// `error.WouldBlock` on timeout.
    pub fn recvTimeout(self: UdpSocket, from: *From, buf: []u8, timeout_ns: u64) Syscall.Error!usize {
        const deadline = innigkeit.Syscall.decode(
            innigkeit.Syscall.invoke(.uptime_ms, .{}),
        ) catch 0;
        const deadline_ms = deadline + timeout_ns / std.time.ns_per_ms;
        while (true) {
            const r = self.recvNonblocking(from, buf);
            if (r != error.WouldBlock) return r;
            const now = innigkeit.Syscall.decode(
                innigkeit.Syscall.invoke(.uptime_ms, .{}),
            ) catch 0;
            if (now >= deadline_ms) return error.WouldBlock;
            innigkeit.sleep(5 * std.time.ns_per_ms);
        }
    }

    /// Close the socket.
    pub fn close(self: UdpSocket) void {
        _ = Syscall.invoke(.net_udp_close, .{@as(usize, self.id)});
    }
};

/// A bound TCP socket.
pub const TcpSocket = struct {
    id: u32,

    /// Open a TCP listening socket on `port`.
    pub fn listen(port: u16) Syscall.Error!TcpSocket {
        const r = Syscall.invoke(.net_tcp_listen, .{@as(usize, port)});
        const id = try Syscall.decode(r);
        return .{ .id = @intCast(id) };
    }

    /// Block until an inbound connection arrives on this listener.
    /// Returns `error.WouldBlock` if the kernel-side wait period expires.
    pub fn accept(self: TcpSocket) Syscall.Error!TcpSocket {
        const r = Syscall.invoke(.net_tcp_accept, .{@as(usize, self.id)});
        const id = try Syscall.decode(r);
        return .{ .id = @intCast(id) };
    }

    /// Initiate an outbound TCP connection to `dst_ip:dst_port` from `src_port`.
    /// Blocks until the three-way handshake completes.
    pub fn connect(src_port: u16, dst_ip: Ip4, dst_port: u16) Syscall.Error!TcpSocket {
        const ip_u32: u32 = std.mem.readInt(u32, &dst_ip, .big);
        const r = Syscall.invoke(.net_tcp_connect, .{
            @as(usize, ip_u32),
            @as(usize, dst_port),
            @as(usize, src_port),
        });
        const id = try Syscall.decode(r);
        return .{ .id = @intCast(id) };
    }

    /// Send `data`. Returns bytes sent (may be less than `data.len` if data
    /// exceeds the MSS; caller should loop until all data is sent).
    pub fn send(self: TcpSocket, data: []const u8) Syscall.Error!usize {
        const r = Syscall.invoke(.net_tcp_send, .{
            @as(usize, self.id),
            @intFromPtr(data.ptr),
            data.len,
        });
        return Syscall.decode(r);
    }

    /// Send all of `data`, looping until complete.
    pub fn sendAll(self: TcpSocket, data: []const u8) Syscall.Error!void {
        var sent: usize = 0;
        while (sent < data.len) {
            sent += try self.send(data[sent..]);
        }
    }

    /// Non-blocking receive. Returns `error.WouldBlock` if no data is available.
    pub fn recv(self: TcpSocket, buf: []u8) Syscall.Error!usize {
        const r = Syscall.invoke(.net_tcp_recv, .{
            @as(usize, self.id),
            @intFromPtr(buf.ptr),
            buf.len,
        });
        return Syscall.decode(r);
    }

    /// Blocking receive with nanosecond timeout.
    /// Returns `error.WouldBlock` on timeout.
    pub fn recvTimeout(self: TcpSocket, buf: []u8, timeout_ns: u64) Syscall.Error!usize {
        const deadline = innigkeit.Syscall.decode(
            innigkeit.Syscall.invoke(.uptime_ms, .{}),
        ) catch 0;
        const deadline_ms = deadline + timeout_ns / std.time.ns_per_ms;
        while (true) {
            const r = self.recv(buf);
            if (r != error.WouldBlock) return r;
            const now = innigkeit.Syscall.decode(
                innigkeit.Syscall.invoke(.uptime_ms, .{}),
            ) catch 0;
            if (now >= deadline_ms) return error.WouldBlock;
            innigkeit.sleep(5 * std.time.ns_per_ms);
        }
    }

    /// Close the socket.
    pub fn close(self: TcpSocket) void {
        _ = Syscall.invoke(.net_tcp_close, .{@as(usize, self.id)});
    }
};
