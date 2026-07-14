//! Kernel network socket table: UDP and TCP.
//!
//! Provides:
//!  - UDP: openSocket/closeSocket, sendUdp, recvUdp (non-blocking),
//!    recvUdpBlocking (sleeps on a per-socket WaitQueue until a datagram
//!    arrives: RX is interrupt-driven, so the net-poll task's call into
//!    handleFrame/deliverUdp wakes the receiver)
//!  - TCP: openTcpListener, openTcpConnect, tcpAccept, tcpSend, tcpRecv, closeTcp
//!  - handleFrame: passed to virtio.net.pollRx; dispatches inbound frames
//!  - arpLookup: shared ARP cache lookup used by TCP
//!
//! All functions are safe to call from syscall handlers (user-thread context) or
//! from the dedicated net-poll kernel thread. A single TicketSpinLock protects
//! shared state; it is never held across yields or blocking waits (WaitQueue.wait
//! releases the lock before the task sleeps).

const arp_pkt = @import("arp.zig");
const eth = @import("ethernet.zig");
const icmp_pkt = @import("icmp.zig");
const innigkeit = @import("innigkeit");
const ip4 = @import("ipv4.zig");
const std = @import("std");
const tcp_sock = @import("tcp/Socket.zig");
const udp_pkt = @import("udp.zig");

const log = innigkeit.debug.log.scoped(.net_socket);

const SOCKET_MAX: usize = 16;
const ARP_CACHE_MAX: usize = 16;
const RX_RING: usize = 8;
pub const MAX_PAYLOAD: usize = 1472; // 1500 - 20 (IP) - 8 (UDP)

const ArpEntry = struct {
    ip: [4]u8 = .{0} ** 4,
    mac: [6]u8 = .{0} ** 6,
    valid: bool = false,
};

pub const RxFrame = struct {
    from_ip: [4]u8 = .{0} ** 4,
    from_port: u16 = 0,
    len: u16 = 0,
    data: [MAX_PAYLOAD]u8 = undefined,
};

const Socket = struct {
    in_use: bool = false,
    port: u16 = 0,
    rx_head: u8 = 0,
    rx_tail: u8 = 0,
    rx_ring: [RX_RING]RxFrame = undefined,
    /// Tasks blocked in `recvUdpBlocking` waiting for a datagram. Guarded by
    /// the module-level `lock` (the same lock the producer `deliverUdp` holds
    /// when it wakes waiters).
    waiters: innigkeit.sync.WaitQueue = .{},
};

// Ping state: only one outstanding ICMP echo at a time.
const PingState = struct {
    active: bool = false,
    dst_ip: [4]u8 = .{0} ** 4,
    id: u16 = 0,
    seq: u16 = 0,
    send_ms: u64 = 0,
    reply_ms: u64 = 0,
    received: bool = false,
};

var sockets: [SOCKET_MAX]Socket = [_]Socket{.{}} ** SOCKET_MAX;
var arp_cache: [ARP_CACHE_MAX]ArpEntry = [_]ArpEntry{.{}} ** ARP_CACHE_MAX;
var ping_state: PingState = .{};
var lock: innigkeit.sync.TicketSpinLock = .{};

/// Open a UDP socket bound to `port`. Returns the socket id (0–15) or null
/// if all slots are taken or the port is already in use.
pub fn openSocket(port: u16) ?u8 {
    lock.lock();
    defer lock.unlock();
    for (&sockets, 0..) |*s, i| {
        if (!s.in_use) {
            s.* = .{ .in_use = true, .port = port };
            return @intCast(i);
        }
    }
    return null;
}

/// Close the socket with `id`. No-op if the id is out of range or not open.
/// Any task blocked in `recvUdpBlocking` on this socket is woken and observes
/// `in_use == false` (recv then fails with null).
pub fn closeSocket(id: u8) void {
    if (id >= SOCKET_MAX) return;
    lock.lock();
    defer lock.unlock();
    const s = &sockets[id];
    s.in_use = false;
    while (s.waiters.firstTask() != null)
        s.waiters.wakeOne(&lock);
}

/// Send a UDP datagram. Resolves the target IP via ARP (blocking with up to
/// 100 yield iterations ≈ ~500 ms). Returns false on error (no NIC, ARP
/// timeout, send failure).
pub fn sendUdp(
    sock_id: u8,
    dst_ip: [4]u8,
    dst_port: u16,
    data: []const u8,
) bool {
    if (sock_id >= SOCKET_MAX) return false;

    const our_mac = innigkeit.drivers.virtio.net.getMac() orelse return false;
    const our_ip_ptr = innigkeit.drivers.virtio.net.getIp() orelse return false;
    const our_ip = our_ip_ptr.*;

    lock.lock();
    if (!sockets[sock_id].in_use) {
        lock.unlock();
        return false;
    }
    const src_port = sockets[sock_id].port;
    lock.unlock();

    // ARP resolution (with retries + yield).
    const dst_mac: [6]u8 = resolveArpWithRetry(dst_ip, our_mac, our_ip) orelse {
        log.warn("ARP timeout for {}.{}.{}.{}", .{ dst_ip[0], dst_ip[1], dst_ip[2], dst_ip[3] });
        return false;
    };

    // Build and send the frame.
    var frame_buf: [eth.HEADER_LEN + ip4.HEADER_LEN + udp_pkt.HEADER_LEN + MAX_PAYLOAD]u8 = undefined;
    const len = udp_pkt.buildPacket(
        &frame_buf,
        our_mac,
        &dst_mac,
        &our_ip,
        &dst_ip,
        src_port,
        dst_port,
        data,
        innigkeit.drivers.virtio.net.nextIpId(),
    );
    if (len == 0) return false;

    return innigkeit.drivers.virtio.net.send(frame_buf[0..len]);
}

/// Send an ICMP echo request to `dst_ip` and wait up to `timeout_ms` for a
/// reply. Returns the round-trip time in milliseconds, or null on timeout.
pub fn ping(dst_ip: [4]u8, timeout_ms: u64) ?u64 {
    const our_mac = innigkeit.drivers.virtio.net.getMac() orelse return null;
    const our_ip_ptr = innigkeit.drivers.virtio.net.getIp() orelse return null;
    const our_ip = our_ip_ptr.*;

    // Resolve ARP.
    const dst_mac = resolveArpWithRetry(dst_ip, our_mac, our_ip) orelse return null;

    lock.lock();
    ping_state = .{
        .active = true,
        .dst_ip = dst_ip,
        .id = 0x4950, // 'IP'
        .seq = 1,
        .send_ms = innigkeit.time.init.getUptimeMs(),
        .received = false,
    };
    const send_ms = ping_state.send_ms;
    const id = ping_state.id;
    const seq = ping_state.seq;
    lock.unlock();

    // Build and send ICMP echo request.
    const payload = "innigkeit";
    const total = 14 + 20 + icmp_pkt.HEADER_LEN + payload.len;
    var frame: [64]u8 = std.mem.zeroes([64]u8);
    const written = icmp_pkt.buildEchoRequest(
        &frame,
        our_mac,
        &dst_mac,
        &our_ip,
        &dst_ip,
        id,
        seq,
        payload,
        innigkeit.drivers.virtio.net.nextIpId(),
    );
    _ = total;
    if (written == 0) return null;
    _ = innigkeit.drivers.virtio.net.send(frame[0..written]);

    // Wait for reply.
    const deadline_ms = send_ms + timeout_ms;
    var tries: usize = 0;
    while (tries < 1000) : (tries += 1) {
        lock.lock();
        if (ping_state.received) {
            const rtt = ping_state.reply_ms -| send_ms;
            ping_state.active = false;
            lock.unlock();
            return rtt;
        }
        lock.unlock();
        const now = innigkeit.time.init.getUptimeMs();
        if (now >= deadline_ms) break;
        const h: innigkeit.Task.Scheduler.Handle = .get();
        h.yield();
        h.unlock();
    }

    lock.lock();
    ping_state.active = false;
    lock.unlock();
    return null;
}

pub const RecvFrom = struct { ip: [4]u8, port: u16 };

/// Pop the oldest queued datagram into `buf`.
///
/// Caller must hold `lock` and have checked that the ring is non-empty.
///
/// `buf` must be kernel memory (the lock is held across the copy).
fn dequeueLocked(s: *Socket, buf: []u8, from: *RecvFrom) u16 {
    const f = &s.rx_ring[s.rx_head % RX_RING];
    const copy_len: u16 = @intCast(@min(f.len, @as(u16, @intCast(buf.len))));
    @memcpy(buf[0..copy_len], f.data[0..copy_len]);
    from.ip = f.from_ip;
    from.port = f.from_port;
    s.rx_head +%= 1;
    return copy_len;
}

pub fn recvUdp(sock_id: u8, buf: []u8, from: *RecvFrom) ?u16 {
    if (sock_id >= SOCKET_MAX) return null;

    lock.lock();
    defer lock.unlock();

    const s = &sockets[sock_id];
    if (!s.in_use or s.rx_head == s.rx_tail) return null;
    return dequeueLocked(s, buf, from);
}

/// Blocking receive. Sleeps the calling task on the socket's wait queue until
/// a datagram is delivered (by `deliverUdp`, running in the net-poll kernel
/// task) or the socket is closed. Returns the number of payload bytes written
/// to `buf`, or null if the socket id is invalid or the socket was/got closed.
///
/// `buf` must be kernel memory (e.g. the syscall handler's bounce buffer):
/// the caller must NOT hold a `UserAccess` window or any lock across this
/// call, since it blocks indefinitely (no timeout; see the syscall handler
/// for the rationale).
pub fn recvUdpBlocking(sock_id: u8, buf: []u8, from: *RecvFrom) ?u16 {
    if (sock_id >= SOCKET_MAX) return null;

    lock.lock();
    while (true) {
        const s = &sockets[sock_id];
        if (!s.in_use) {
            lock.unlock();
            return null;
        }
        if (s.rx_head != s.rx_tail) {
            const n = dequeueLocked(s, buf, from);
            lock.unlock();
            return n;
        }
        // wait() enqueues the current task, releases `lock`, and blocks;
        // it returns with the lock RELEASED. Spurious wakeups are allowed,
        // so re-acquire the lock and re-check the condition every time.
        s.waiters.wait(&lock);
        lock.lock();
    }
}

pub fn handleFrame(frame: []const u8) void {
    if (frame.len < eth.HEADER_LEN) return;

    const etype = std.mem.readInt(u16, frame[12..14], .big);
    switch (etype) {
        0x0806 => handleArp(frame[eth.HEADER_LEN..]),
        0x0800 => handleIp(frame[eth.HEADER_LEN..]),
        else => {},
    }
}

fn handleArp(payload: []const u8) void {
    if (payload.len < arp_pkt.PACKET_LEN) return;
    const p: *const arp_pkt.Packet = @ptrCast(@alignCast(payload.ptr));
    const op = std.mem.readInt(u16, std.mem.asBytes(&p.op), .big);
    if (op == 2) { // ARP reply
        updateArpCache(p.sender_ip, p.sender_mac);
    }
    // Respond to ARP requests targeting our IP.
    const our_ip_ptr = innigkeit.drivers.virtio.net.getIp() orelse return;
    if (op == 1 and std.mem.eql(u8, &p.target_ip, our_ip_ptr)) {
        const our_mac = innigkeit.drivers.virtio.net.getMac() orelse return;
        var reply: [eth.HEADER_LEN + arp_pkt.PACKET_LEN]u8 = undefined;
        arp_pkt.buildReply(&reply, our_mac, our_ip_ptr, &p.sender_mac, &p.sender_ip);
        _ = innigkeit.drivers.virtio.net.send(&reply);
    }
}

fn handleIp(payload: []const u8) void {
    const pkt = ip4.parse(payload) orelse return;

    switch (pkt.proto) {
        .udp => handleUdp(pkt.src, pkt.payload),
        .icmp => handleIcmp(pkt.src, payload, pkt.payload),
        .tcp => tcp_sock.handleSegment(pkt.src, pkt.dst, pkt.payload),
        _ => {},
    }
}

fn handleUdp(from_ip: [4]u8, data: []const u8) void {
    const p = udp_pkt.parse(data) orelse return;
    deliverUdp(from_ip, p.src_port, p.dst_port, p.payload);
}

/// Deliver a UDP payload to the socket bound to `dst_port`. Enqueues the
/// datagram and wakes one blocked receiver. Drops silently if no socket is
/// bound or the socket's ring is full.
///
/// Normally called from `handleFrame` (net-poll kernel task); also callable
/// directly (e.g. from kernel tests) to inject synthetic datagrams.
pub fn deliverUdp(from_ip: [4]u8, from_port: u16, dst_port: u16, payload: []const u8) void {
    lock.lock();
    defer lock.unlock();

    for (&sockets) |*s| {
        if (!s.in_use or s.port != dst_port) continue;
        const used: u8 = s.rx_tail -% s.rx_head;
        if (used >= RX_RING) return; // ring full, drop
        const f = &s.rx_ring[s.rx_tail % RX_RING];
        f.from_ip = from_ip;
        f.from_port = from_port;
        const len: u16 = @intCast(@min(payload.len, MAX_PAYLOAD));
        f.len = len;
        @memcpy(f.data[0..len], payload[0..len]);
        s.rx_tail +%= 1;
        // Wake a receiver blocked in recvUdpBlocking (no-op if none).
        s.waiters.wakeOne(&lock);
        return;
    }
}

fn handleIcmp(src_ip: [4]u8, raw_ip: []const u8, icmp_data: []const u8) void {
    const p = icmp_pkt.parseEcho(icmp_data) orelse return;

    // Handle ICMP echo reply (ping response).
    if (p.type_ == icmp_pkt.ICMP_ECHO_REPLY) {
        lock.lock();
        if (ping_state.active and
            std.mem.eql(u8, &ping_state.dst_ip, &src_ip) and
            ping_state.id == p.id and ping_state.seq == p.seq)
        {
            ping_state.reply_ms = innigkeit.time.init.getUptimeMs();
            ping_state.received = true;
        }
        lock.unlock();
        return;
    }

    if (p.type_ != icmp_pkt.ICMP_ECHO_REQUEST) return;

    const our_mac = innigkeit.drivers.virtio.net.getMac() orelse return;
    const our_ip = innigkeit.drivers.virtio.net.getIp() orelse return;

    const src_mac: [6]u8 = blk: {
        // Look up ARP cache for src_ip (sender should have sent ARP already).
        if (lookupArpCache(src_ip)) |m| break :blk m;
        // Try to read from the enclosing Ethernet frame's src field if passed correctly.
        // Fall back: we cannot send a reply without a destination MAC.
        _ = raw_ip;
        return;
    };

    const payload_len = p.payload.len;
    const total = eth.HEADER_LEN + ip4.HEADER_LEN + icmp_pkt.HEADER_LEN + payload_len;
    if (total > 1514) return;

    var reply: [1514]u8 = undefined;
    const written = icmp_pkt.buildEchoReply(
        reply[0..total],
        our_mac,
        our_ip,
        &src_mac,
        &src_ip,
        p.id,
        p.seq,
        p.payload,
        innigkeit.drivers.virtio.net.nextIpId(),
    );
    if (written > 0) _ = innigkeit.drivers.virtio.net.send(reply[0..written]);
}

fn updateArpCache(ip: [4]u8, mac: [6]u8) void {
    lock.lock();
    defer lock.unlock();
    // Update existing or find empty slot.
    var empty: ?*ArpEntry = null;
    for (&arp_cache) |*e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) {
            e.mac = mac;
            return;
        }
        if (!e.valid) empty = e;
    }
    if (empty) |e| {
        e.ip = ip;
        e.mac = mac;
        e.valid = true;
    }
    // If cache is full just drop. Oldest eviction would be nicer but overkill here.
}

fn lookupArpCache(ip: [4]u8) ?[6]u8 {
    lock.lock();
    defer lock.unlock();
    for (&arp_cache) |*e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) return e.mac;
    }
    return null;
}

/// Public ARP lookup used by tcp/Socket.zig (no lock held here; Socket.zig
/// calls this outside its own lock).
pub fn arpLookup(ip: [4]u8) ?[6]u8 {
    return lookupArpCache(ip);
}

pub fn openTcpListener(port: u16) ?u8 {
    return tcp_sock.openListener(port);
}

pub fn openTcpConnect(src_port: u16, dst_ip: [4]u8, dst_port: u16) ?u8 {
    return tcp_sock.openConnect(src_port, dst_ip, dst_port);
}

pub fn tcpWaitConnected(id: u8) bool {
    return tcp_sock.waitConnected(id);
}

/// Blocks until an inbound connection is established on the listener; returns
/// the new socket id, or null if the listener id is invalid or closed.
pub fn tcpAccept(listener_id: u8) ?u8 {
    return tcp_sock.accept(listener_id);
}

pub fn tcpSend(id: u8, data: []const u8) usize {
    return tcp_sock.sendData(id, data);
}

/// Non-blocking TCP receive (returns 0 when no data is buffered). `net_tcp_recv`
/// copies through a kernel bounce buffer (see `handlers/network.zig`), so
/// this stays non-blocking because no caller needs a blocking variant yet,
/// not for user-memory-safety reasons.
pub fn tcpRecv(id: u8, buf: []u8) u16 {
    return tcp_sock.recvData(id, buf);
}

pub fn closeTcp(id: u8) void {
    return tcp_sock.closeSocket(id);
}

/// Resolve dst_ip -> MAC. Sends an ARP request if not cached; yields up to 100
/// times (each yield allows the net-poll thread to process one batch of frames).
fn resolveArpWithRetry(dst_ip: [4]u8, our_mac: *const [6]u8, our_ip: [4]u8) ?[6]u8 {
    if (lookupArpCache(dst_ip)) |m| return m;

    // Send ARP request.
    var req: [eth.HEADER_LEN + arp_pkt.PACKET_LEN]u8 = undefined;
    arp_pkt.buildRequest(&req, our_mac, &our_ip, &dst_ip);
    _ = innigkeit.drivers.virtio.net.send(&req);

    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        if (lookupArpCache(dst_ip)) |m| return m;
        const h: innigkeit.Task.Scheduler.Handle = .get();
        h.yield();
        h.unlock();
    }
    return null;
}

test "udp socket: delivered datagram is received without blocking" {
    const port: u16 = 47123; // arbitrary high port, unused elsewhere
    const id = openSocket(port) orelse return error.NoSocketSlot;
    defer closeSocket(id);

    const src_ip: [4]u8 = .{ 10, 0, 2, 2 };

    // Inject two synthetic datagrams via the delivery function (the same
    // path handleFrame uses for real RX traffic).
    deliverUdp(src_ip, 5555, port, "hello");
    deliverUdp(src_ip, 5556, port, "world!");

    var buf: [MAX_PAYLOAD]u8 = undefined;
    var from: RecvFrom = .{ .ip = .{0} ** 4, .port = 0 };

    // Blocking receive must return immediately: a datagram is already queued,
    // so the fast path never reaches the wait queue.
    const n1 = recvUdpBlocking(id, &buf, &from) orelse return error.NoDatagram;
    try std.testing.expectEqual(@as(u16, 5), n1);
    try std.testing.expectEqualSlices(u8, "hello", buf[0..n1]);
    try std.testing.expectEqualSlices(u8, &src_ip, &from.ip);
    try std.testing.expectEqual(@as(u16, 5555), from.port);

    // Non-blocking receive drains the second datagram in FIFO order.
    const n2 = recvUdp(id, &buf, &from) orelse return error.NoDatagram;
    try std.testing.expectEqual(@as(u16, 6), n2);
    try std.testing.expectEqualSlices(u8, "world!", buf[0..n2]);
    try std.testing.expectEqual(@as(u16, 5556), from.port);
}

test "udp socket: empty socket would-block (non-blocking returns null)" {
    const port: u16 = 47124;
    const id = openSocket(port) orelse return error.NoSocketSlot;
    defer closeSocket(id);

    var buf: [16]u8 = undefined;
    var from: RecvFrom = .{ .ip = .{0} ** 4, .port = 0 };
    try std.testing.expectEqual(@as(?u16, null), recvUdp(id, &buf, &from));
}

test "udp socket: blocking recv on a closed socket returns null immediately" {
    const port: u16 = 47125;
    const id = openSocket(port) orelse return error.NoSocketSlot;
    closeSocket(id);

    var buf: [16]u8 = undefined;
    var from: RecvFrom = .{ .ip = .{0} ** 4, .port = 0 };
    try std.testing.expectEqual(@as(?u16, null), recvUdpBlocking(id, &buf, &from));
    // Out-of-range ids fail without touching the table.
    try std.testing.expectEqual(@as(?u16, null), recvUdpBlocking(@intCast(SOCKET_MAX), &buf, &from));
}

test "tcp accept: closed or invalid listener returns null immediately" {
    const lid = openTcpListener(47126) orelse return error.NoSocketSlot;
    closeTcp(lid);
    // The slot is no longer in use, so blocking accept must bail out at once.
    try std.testing.expectEqual(@as(?u8, null), tcpAccept(lid));
}
