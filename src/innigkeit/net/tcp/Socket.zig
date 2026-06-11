//! Supports up to TCP_MAX concurrent connections. All state is protected by
//! a single TicketSpinLock that is never held across yields or blocking waits.
//!
//! Limitations of this initial implementation:
//!  - No retransmission (QEMU virtual network is lossless).
//!  - Fixed receive window (RCV_WND bytes); no congestion control.
//!  - No TCP options on outgoing segments beyond SYN MSS.
//!  - TIME_WAIT shortened to 0 (connection slots are recycled immediately).

const std = @import("std");
const innigkeit = @import("innigkeit");
const eth = @import("../ethernet.zig");
const ip4 = @import("../ipv4.zig");
const seg_mod = @import("Segment.zig");
const Segment = seg_mod.Segment;
const Flags = seg_mod.Flags;

const log = innigkeit.debug.log.scoped(.net_tcp);

pub const TCP_MAX: usize = 8;
const RCV_WND: u16 = 8192;
const MSS: u16 = 1460;

/// TCP connection state machine states.
pub const State = enum {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    last_ack,
    time_wait,
};

const RX_BUF_SIZE: usize = 8192;

pub const Socket = struct {
    state: State = .closed,
    in_use: bool = false,
    is_listener: bool = false,

    /// Local port.
    local_port: u16 = 0,
    /// Remote IP and port (zero for listeners waiting for a connection).
    remote_ip: [4]u8 = .{0} ** 4,
    remote_port: u16 = 0,

    /// Send sequence numbers.
    snd_una: u32 = 0, // oldest unacknowledged
    snd_nxt: u32 = 0, // next to send

    /// Receive sequence numbers.
    rcv_nxt: u32 = 0, // next expected from remote

    /// Receive ring buffer.
    rx_buf: [RX_BUF_SIZE]u8 = undefined,
    rx_head: u16 = 0,
    rx_tail: u16 = 0,

    /// Set when the remote has sent FIN (all data has been received).
    recv_fin: bool = false,

    /// For listeners: index of a newly accepted socket (-1 = none).
    accept_slot: i8 = -1,

    fn rxAvail(self: *const Socket) u16 {
        return self.rx_tail -% self.rx_head;
    }

    fn rxPush(self: *Socket, data: []const u8) void {
        for (data) |b| {
            const next = self.rx_tail +% 1;
            if (next == self.rx_head) break; // full
            self.rx_buf[self.rx_tail % RX_BUF_SIZE] = b;
            self.rx_tail +%= 1;
        }
    }

    fn rxPop(self: *Socket, buf: []u8) u16 {
        var n: u16 = 0;
        while (n < buf.len and self.rx_head != self.rx_tail) : (n += 1) {
            buf[n] = self.rx_buf[self.rx_head % RX_BUF_SIZE];
            self.rx_head +%= 1;
        }
        return n;
    }
};

var sockets: [TCP_MAX]Socket = [_]Socket{.{}} ** TCP_MAX;
var lock: innigkeit.sync.TicketSpinLock = .{};

fn send(
    sock: *Socket,
    flags: Flags,
    payload: []const u8,
) void {
    const our_mac = innigkeit.drivers.virtio.net.getMac() orelse return;
    const our_ip_ptr = innigkeit.drivers.virtio.net.getIp() orelse return;
    const our_ip = our_ip_ptr.*;

    const hdr_len: usize = if (flags.syn) 24 else 20;
    const total = eth.HEADER_LEN + ip4.HEADER_LEN + hdr_len + payload.len;
    var frame_buf: [eth.HEADER_LEN + ip4.HEADER_LEN + 24 + 1460]u8 = undefined;
    if (total > frame_buf.len) return;

    // Resolve destination MAC (from ARP cache: caller ensures it's populated).
    const dst_mac = innigkeit.net.socket.arpLookup(sock.remote_ip) orelse return;

    eth.writeHeader(&frame_buf, &dst_mac, our_mac, .ipv4);

    const ip_payload_len = hdr_len + payload.len;
    const ip_id = innigkeit.drivers.virtio.net.nextIpId();
    ip4.writeHeader(frame_buf[eth.HEADER_LEN..], ip_id, .tcp, &our_ip, &sock.remote_ip, ip_payload_len);

    const tcp_buf = frame_buf[eth.HEADER_LEN + ip4.HEADER_LEN ..][0 .. hdr_len + payload.len];
    if (flags.syn) {
        seg_mod.writeHeaderWithMss(tcp_buf[0..24], sock.local_port, sock.remote_port, sock.snd_nxt, sock.rcv_nxt, flags, RCV_WND, MSS);
    } else {
        seg_mod.writeHeader(tcp_buf[0..20], sock.local_port, sock.remote_port, sock.snd_nxt, sock.rcv_nxt, flags, RCV_WND);
    }
    if (payload.len > 0) @memcpy(tcp_buf[hdr_len..][0..payload.len], payload);
    seg_mod.fillChecksum(tcp_buf, &our_ip, &sock.remote_ip);

    _ = innigkeit.drivers.virtio.net.send(frame_buf[0..total]);

    // Advance snd_nxt for data-carrying / sequence-consuming segments.
    if (flags.syn or flags.fin) sock.snd_nxt +%= 1;
    sock.snd_nxt +%= @as(u32, @intCast(payload.len));
}

/// Locate the socket slot matching (local_port, remote_ip, remote_port).
/// Returns the listener slot as a fallback if dst_port matches.
fn findSocket(dst_port: u16, src_ip: [4]u8, src_port: u16) ?usize {
    var listener: ?usize = null;
    for (&sockets, 0..) |*s, i| {
        if (!s.in_use) continue;
        if (s.local_port != dst_port) continue;
        if (s.is_listener) {
            listener = i;
            continue;
        }
        if (std.mem.eql(u8, &s.remote_ip, &src_ip) and s.remote_port == src_port)
            return i;
    }
    return listener;
}

/// Find a free socket slot.
fn allocSlot() ?usize {
    for (&sockets, 0..) |*s, i| {
        if (!s.in_use) return i;
    }
    return null;
}

/// Open a TCP listening socket on `port`.  Returns slot id or null.
pub fn openListener(port: u16) ?u8 {
    lock.lock();
    defer lock.unlock();
    const i = allocSlot() orelse return null;
    sockets[i] = .{
        .in_use = true,
        .is_listener = true,
        .state = .listen,
        .local_port = port,
    };
    return @intCast(i);
}

/// Initiate an outbound connection to `dst_ip:dst_port` from `src_port`.
/// Returns the socket id. The connection completes asynchronously; poll
/// with `isConnected` before sending.
pub fn openConnect(src_port: u16, dst_ip: [4]u8, dst_port: u16) ?u8 {
    const our_mac = innigkeit.drivers.virtio.net.getMac() orelse return null;
    const our_ip_ptr = innigkeit.drivers.virtio.net.getIp() orelse return null;
    const our_ip = our_ip_ptr.*;
    _ = our_mac;
    _ = our_ip;

    lock.lock();
    defer lock.unlock();
    const i = allocSlot() orelse return null;
    const isn: u32 = @truncate(innigkeit.time.init.getUptimeMs() *% 0x9e3779b1);
    sockets[i] = .{
        .in_use = true,
        .state = .syn_sent,
        .local_port = src_port,
        .remote_ip = dst_ip,
        .remote_port = dst_port,
        .snd_una = isn,
        .snd_nxt = isn,
    };
    send(&sockets[i], .{ .syn = true }, &.{});
    return @intCast(i);
}

/// Block until the socket reaches ESTABLISHED (or CLOSED on error).
/// Yields the CPU in a loop.
pub fn waitConnected(id: u8) bool {
    var tries: usize = 0;
    while (tries < 2000) : (tries += 1) {
        lock.lock();
        const st = if (id < TCP_MAX and sockets[id].in_use) sockets[id].state else .closed;
        lock.unlock();
        switch (st) {
            .established => return true,
            .closed => return false,
            else => {},
        }
        const h: innigkeit.Task.Scheduler.Handle = .get();
        h.yield();
        h.unlock();
    }
    return false;
}

/// Block until an inbound connection arrives on listener `id`.
/// Returns the new socket id (with state = established) or null on timeout.
pub fn accept(id: u8) ?u8 {
    var tries: usize = 0;
    while (tries < 2000) : (tries += 1) {
        lock.lock();
        if (id < TCP_MAX and sockets[id].in_use and sockets[id].accept_slot >= 0) {
            const slot: u8 = @intCast(sockets[id].accept_slot);
            sockets[id].accept_slot = -1;
            lock.unlock();
            return slot;
        }
        lock.unlock();
        const h: innigkeit.Task.Scheduler.Handle = .get();
        h.yield();
        h.unlock();
    }
    return null;
}

/// Send data on an established socket. Returns bytes sent (may be less than
/// `data.len` if data exceeds MSS; caller should loop).
pub fn sendData(id: u8, data: []const u8) usize {
    lock.lock();
    defer lock.unlock();
    if (id >= TCP_MAX or !sockets[id].in_use) return 0;
    if (sockets[id].state != .established) return 0;
    const chunk_len = @min(data.len, MSS);
    send(&sockets[id], .{ .ack = true, .psh = true }, data[0..chunk_len]);
    return chunk_len;
}

/// Non-blocking receive. Returns bytes read (0 = no data yet).
pub fn recvData(id: u8, buf: []u8) u16 {
    lock.lock();
    defer lock.unlock();
    if (id >= TCP_MAX or !sockets[id].in_use) return 0;
    return sockets[id].rxPop(buf);
}

/// Initiate graceful close.
pub fn closeSocket(id: u8) void {
    lock.lock();
    defer lock.unlock();
    if (id >= TCP_MAX or !sockets[id].in_use) return;
    const s = &sockets[id];
    switch (s.state) {
        .established, .close_wait => {
            const new_state: State = if (s.state == .established) .fin_wait_1 else .last_ack;
            s.state = new_state;
            send(s, .{ .ack = true, .fin = true }, &.{});
        },
        else => {},
    }
    s.in_use = false;
    s.state = .closed;
}

/// Called from the network poller with a TCP payload (no IP header).
/// `src_ip` / `dst_ip` are needed for checksum and to identify the connection.
pub fn handleSegment(src_ip: [4]u8, dst_ip: [4]u8, data: []const u8) void {
    _ = dst_ip; // we always accept frames addressed to us

    const incoming = seg_mod.parse(data) orelse return;

    lock.lock();
    defer lock.unlock();

    const slot = findSocket(incoming.dst_port, src_ip, incoming.src_port) orelse return;
    const s = &sockets[slot];

    switch (s.state) {
        .listen => handleListen(s, slot, src_ip, &incoming),
        .syn_sent => handleSynSent(s, &incoming),
        .syn_received => handleSynReceived(s, &incoming),
        .established => handleEstablished(s, &incoming),
        .fin_wait_1, .fin_wait_2 => handleFinWait(s, &incoming),
        .close_wait, .last_ack => handleLastAck(s, &incoming),
        else => {},
    }
}

fn handleListen(listener: *Socket, listener_slot: usize, src_ip: [4]u8, incoming: *const Segment) void {
    if (!incoming.flags.syn or incoming.flags.ack) return;

    const child_slot = allocSlot() orelse return;
    const isn: u32 = @truncate(innigkeit.time.init.getUptimeMs() *% 0x9e3779b1);
    sockets[child_slot] = .{
        .in_use = true,
        .state = .syn_received,
        .local_port = listener.local_port,
        .remote_ip = src_ip,
        .remote_port = incoming.src_port,
        .snd_una = isn,
        .snd_nxt = isn,
        .rcv_nxt = incoming.seq +% 1,
    };

    // Send SYN-ACK
    send(&sockets[child_slot], .{ .syn = true, .ack = true }, &.{});
    _ = listener_slot;
}

fn handleSynSent(s: *Socket, incoming: *const Segment) void {
    if (!incoming.flags.syn) return;
    s.rcv_nxt = incoming.seq +% 1;
    if (incoming.flags.ack) {
        // SYN-ACK: complete the handshake.
        s.snd_una = incoming.ack;
        s.state = .established;
        send(s, .{ .ack = true }, &.{});
    } else {
        // Simultaneous open: not supported; reset.
        send(s, .{ .rst = true }, &.{});
        s.state = .closed;
        s.in_use = false;
    }
}

fn handleSynReceived(s: *Socket, incoming: *const Segment) void {
    if (incoming.flags.rst) {
        s.state = .closed;
        s.in_use = false;
        return;
    }
    if (!incoming.flags.ack) return;
    if (incoming.ack != s.snd_nxt) return;
    s.snd_una = incoming.ack;
    s.state = .established;

    // Notify listener that a child socket is ready.
    for (&sockets) |*ls| {
        if (ls.is_listener and ls.state == .listen and ls.local_port == s.local_port) {
            const idx = (@intFromPtr(s) - @intFromPtr(&sockets)) / @sizeOf(Socket);
            std.debug.assert(idx < TCP_MAX); // `s` always lives in `sockets`
            ls.accept_slot = @intCast(idx);
            break;
        }
    }
}

fn handleEstablished(s: *Socket, incoming: *const Segment) void {
    if (incoming.flags.rst) {
        s.state = .closed;
        s.in_use = false;
        return;
    }
    if (!incoming.flags.ack) return;
    s.snd_una = incoming.ack;

    if (incoming.payload.len > 0) {
        s.rxPush(incoming.payload);
        s.rcv_nxt +%= @intCast(incoming.payload.len);
        send(s, .{ .ack = true }, &.{});
    }

    if (incoming.flags.fin) {
        s.rcv_nxt +%= 1;
        s.recv_fin = true;
        s.state = .close_wait;
        send(s, .{ .ack = true }, &.{});
    }
}

fn handleFinWait(s: *Socket, incoming: *const Segment) void {
    if (incoming.flags.ack) s.snd_una = incoming.ack;
    if (s.state == .fin_wait_1 and incoming.flags.ack and incoming.ack == s.snd_nxt) {
        s.state = .fin_wait_2;
    }
    if (incoming.flags.fin) {
        s.rcv_nxt +%= 1;
        send(s, .{ .ack = true }, &.{});
        s.state = .closed;
        s.in_use = false;
    }
}

fn handleLastAck(s: *Socket, incoming: *const Segment) void {
    if (incoming.flags.ack and incoming.ack == s.snd_nxt) {
        s.state = .closed;
        s.in_use = false;
    }
}

/// Expose the ARP lookup needed by send().
pub const arpLookupFn = *const fn ([4]u8) ?[6]u8;
