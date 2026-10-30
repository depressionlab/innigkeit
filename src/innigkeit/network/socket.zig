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

pub const Owner = @import("owner.zig").Owner;

const log = innigkeit.debug.log.scoped(.net_socket);
const wallclock = innigkeit.time.wallclock;

const SOCKET_MAX: usize = 16;
const ARP_CACHE_MAX: usize = 16;
const RX_RING: usize = 8;
pub const MAX_PAYLOAD: usize = 1472; // 1500 - 20 (IP) - 8 (UDP)

const ArpEntry = struct {
    ip: [4]u8 = @splat(0),
    mac: [6]u8 = @splat(0),
    valid: bool = false,
};

pub const RxFrame = struct {
    from_ip: [4]u8 = @splat(0),
    from_port: u16 = 0,
    len: u16 = 0,
    data: [MAX_PAYLOAD]u8 = undefined,
};

const Socket = struct {
    in_use: bool = false,
    owner: Owner = .kernel,
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
    dst_ip: [4]u8 = @splat(0),
    id: u16 = 0,
    seq: u16 = 0,
    send_ms: u64 = 0,
    reply_ms: u64 = 0,
    received: bool = false,
};

var sockets: [SOCKET_MAX]Socket = @splat(.{});
var arp_cache: [ARP_CACHE_MAX]ArpEntry = @splat(.{});
var ping_state: PingState = .{};
var lock: innigkeit.sync.TicketSpinLock = .{};

/// Open a UDP socket bound to `port`, owned by `owner`. Returns the socket id
/// (0–15) or null if all slots are taken.
pub fn openSocket(owner: Owner, port: u16) ?u8 {
    lock.lock();
    defer lock.unlock();
    for (&sockets, 0..) |*s, i| {
        if (!s.in_use) {
            s.* = .{ .in_use = true, .owner = owner, .port = port };
            return @intCast(i);
        }
    }
    return null;
}

/// True if `id` is an open UDP socket owned by `owner`. Caller holds `lock`.
fn ownedLocked(owner: Owner, id: u8) bool {
    return id < SOCKET_MAX and sockets[id].in_use and sockets[id].owner == owner;
}

/// Close every socket (UDP and TCP) `owner` still has open. Run when a
/// process is torn down so its sockets neither leak nor outlive the identity
/// that `Owner.of` derives from the process's address.
pub fn closeAllOwnedBy(owner: Owner) void {
    {
        lock.lock();
        defer lock.unlock();
        for (&sockets) |*s| {
            if (!s.in_use or s.owner != owner) continue;
            s.in_use = false;
            while (s.waiters.pop(&lock)) |task|
                task.wakeFromBlocked();
        }
    }
    tcp_sock.closeAllOwnedBy(owner);
}

/// Close the socket with `id`. No-op if the id is out of range, not open, or
/// not owned by `owner`. Any task blocked in `recvUdpBlocking` on this socket
/// is woken and observes `in_use == false` (recv then fails with null).
pub fn closeSocket(owner: Owner, id: u8) void {
    lock.lock();
    defer lock.unlock();
    if (!ownedLocked(owner, id)) return;
    const s = &sockets[id];
    s.in_use = false;
    while (s.waiters.pop(&lock)) |task|
        task.wakeFromBlocked();
}

/// Send a UDP datagram. Resolves the target IP via ARP (blocking, wallclock-
/// bounded by `arp_timeout_ns`). Returns false on error (no NIC, ARP
/// timeout, send failure).
pub fn sendUdp(
    owner: Owner,
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
    if (!ownedLocked(owner, sock_id)) {
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

pub fn recvUdp(owner: Owner, sock_id: u8, buf: []u8, from: *RecvFrom) ?u16 {
    lock.lock();
    defer lock.unlock();

    if (!ownedLocked(owner, sock_id)) return null;
    const s = &sockets[sock_id];
    if (s.rx_head == s.rx_tail) return null;
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
pub fn recvUdpBlocking(owner: Owner, sock_id: u8, buf: []u8, from: *RecvFrom) ?u16 {
    lock.lock();
    while (true) {
        // Re-checked after every wakeup: the slot may have been closed and
        // reopened by someone else while this task slept.
        if (!ownedLocked(owner, sock_id)) {
            lock.unlock();
            return null;
        }
        const s = &sockets[sock_id];
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
    const our_ip = innigkeit.drivers.virtio.net.getIp() orelse return;
    if (!ip4.isForUs(pkt.dst, our_ip.*)) return;

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

pub fn openTcpListener(owner: Owner, port: u16) ?u8 {
    return tcp_sock.openListener(owner, port);
}

pub fn openTcpConnect(owner: Owner, src_port: u16, dst_ip: [4]u8, dst_port: u16) ?u8 {
    return tcp_sock.openConnect(owner, src_port, dst_ip, dst_port);
}

pub fn tcpWaitConnected(owner: Owner, id: u8) bool {
    return tcp_sock.waitConnected(owner, id);
}

/// Blocks until an inbound connection is established on the listener; returns
/// the new socket id, or null if the listener id is invalid or closed.
pub fn tcpAccept(owner: Owner, listener_id: u8) ?u8 {
    return tcp_sock.accept(owner, listener_id);
}

pub fn tcpReown(from: Owner, to: Owner, id: u8) bool {
    return tcp_sock.reown(from, to, id);
}

pub fn tcpSend(owner: Owner, id: u8, data: []const u8) usize {
    return tcp_sock.sendData(owner, id, data);
}

/// Non-blocking TCP receive (returns 0 when no data is buffered). `net_tcp_recv`
/// copies through a kernel bounce buffer (see `handlers/network.zig`), so
/// this stays non-blocking because no caller needs a blocking variant yet,
/// not for user-memory-safety reasons.
pub fn tcpRecv(owner: Owner, id: u8, buf: []u8) u16 {
    return tcp_sock.recvData(owner, id, buf);
}

pub fn closeTcp(owner: Owner, id: u8) void {
    return tcp_sock.closeSocket(owner, id);
}

/// Bound on how long `resolveArpWithRetry` waits for an ARP reply.
const arp_timeout_ns: u64 = 2 * std.time.ns_per_s;

/// Resolve dst_ip -> MAC. Sends an ARP request if not cached; polls (yielding
/// between checks, so the net-poll task can process incoming frames) until
/// either the reply arrives or `arp_timeout_ns` elapses.
fn resolveArpWithRetry(dst_ip: [4]u8, our_mac: *const [6]u8, our_ip: [4]u8) ?[6]u8 {
    if (lookupArpCache(dst_ip)) |m| return m;

    // Send ARP request.
    var req: [eth.HEADER_LEN + arp_pkt.PACKET_LEN]u8 = undefined;
    arp_pkt.buildRequest(&req, our_mac, &our_ip, &dst_ip);
    _ = innigkeit.drivers.virtio.net.send(&req);

    const start = wallclock.read();
    while (@backingInt(wallclock.elapsed(start, wallclock.read())) < arp_timeout_ns) {
        if (lookupArpCache(dst_ip)) |m| return m;
        const h: innigkeit.Task.Scheduler.Handle = .get();
        h.yield();
        h.unlock();
    }
    return null;
}

test "udp socket: delivered datagram is received without blocking" {
    const port: u16 = 47123; // arbitrary high port, unused elsewhere
    const id = openSocket(.kernel, port) orelse return error.NoSocketSlot;
    defer closeSocket(.kernel, id);

    const src_ip: [4]u8 = .{ 10, 0, 2, 2 };

    // Inject two synthetic datagrams via the delivery function (the same
    // path handleFrame uses for real RX traffic).
    deliverUdp(src_ip, 5555, port, "hello");
    deliverUdp(src_ip, 5556, port, "world!");

    var buf: [MAX_PAYLOAD]u8 = undefined;
    var from: RecvFrom = .{ .ip = @splat(0), .port = 0 };

    // Blocking receive must return immediately: a datagram is already queued,
    // so the fast path never reaches the wait queue.
    const n1 = recvUdpBlocking(.kernel, id, &buf, &from) orelse return error.NoDatagram;
    try std.testing.expectEqual(@as(u16, 5), n1);
    try std.testing.expectEqualSlices(u8, "hello", buf[0..n1]);
    try std.testing.expectEqualSlices(u8, &src_ip, &from.ip);
    try std.testing.expectEqual(@as(u16, 5555), from.port);

    // Non-blocking receive drains the second datagram in FIFO order.
    const n2 = recvUdp(.kernel, id, &buf, &from) orelse return error.NoDatagram;
    try std.testing.expectEqual(@as(u16, 6), n2);
    try std.testing.expectEqualSlices(u8, "world!", buf[0..n2]);
    try std.testing.expectEqual(@as(u16, 5556), from.port);
}

test "udp socket: empty socket would-block (non-blocking returns null)" {
    const port: u16 = 47124;
    const id = openSocket(.kernel, port) orelse return error.NoSocketSlot;
    defer closeSocket(.kernel, id);

    var buf: [16]u8 = undefined;
    var from: RecvFrom = .{ .ip = @splat(0), .port = 0 };
    try std.testing.expectEqual(@as(?u16, null), recvUdp(.kernel, id, &buf, &from));
}

test "udp socket: blocking recv on a closed socket returns null immediately" {
    const port: u16 = 47125;
    const id = openSocket(.kernel, port) orelse return error.NoSocketSlot;
    closeSocket(.kernel, id);

    var buf: [16]u8 = undefined;
    var from: RecvFrom = .{ .ip = @splat(0), .port = 0 };
    try std.testing.expectEqual(@as(?u16, null), recvUdpBlocking(.kernel, id, &buf, &from));
    // Out-of-range ids fail without touching the table.
    try std.testing.expectEqual(@as(?u16, null), recvUdpBlocking(.kernel, @intCast(SOCKET_MAX), &buf, &from));
}

test "tcp accept: closed or invalid listener returns null immediately" {
    const lid = openTcpListener(.kernel, 47126) orelse return error.NoSocketSlot;
    closeTcp(.kernel, lid);
    // The slot is no longer in use, so blocking accept must bail out at once.
    try std.testing.expectEqual(@as(?u8, null), tcpAccept(.kernel, lid));
}

test "UDP sockets: only the opening owner can use or close them" {
    const alice: Owner = .of(&sockets[0]);
    const bob: Owner = .of(&sockets[1]);

    const id = openSocket(alice, 40001) orelse return error.SocketOpenFailed;
    // Closed explicitly below on the success path; closeAllOwnedBy is the net for failures.
    defer closeAllOwnedBy(alice);

    var from: RecvFrom = .{ .ip = @splat(0), .port = 0 };
    var buf: [8]u8 = undefined;

    // A datagram queued for alice is invisible to bob and to the kernel identity.
    deliverUdp(.{ 10, 0, 0, 1 }, 7, 40001, "hi");
    try std.testing.expectEqual(@as(?u16, null), recvUdp(bob, id, &buf, &from));
    try std.testing.expectEqual(@as(?u16, null), recvUdp(.kernel, id, &buf, &from));
    try std.testing.expect(!sendUdp(bob, id, .{ 10, 0, 0, 1 }, 7, "x"));

    // bob closing it is a no-op: alice still receives her datagram.
    closeSocket(bob, id);
    closeSocket(.kernel, id);
    try std.testing.expectEqual(@as(?u16, 2), recvUdp(alice, id, &buf, &from));
    try std.testing.expectEqualStrings("hi", buf[0..2]);

    // A closed id is dead for everyone, including its former owner.
    closeSocket(alice, id);
    try std.testing.expectEqual(@as(?u16, null), recvUdp(alice, id, &buf, &from));
}

test "UDP sockets: closeAllOwnedBy closes only that owner's sockets" {
    const alice: Owner = .of(&sockets[0]);
    const bob: Owner = .of(&sockets[1]);

    const a = openSocket(alice, 40002) orelse return error.SocketOpenFailed;
    const b = openSocket(bob, 40003) orelse return error.SocketOpenFailed;
    defer closeAllOwnedBy(bob);

    closeAllOwnedBy(alice);

    deliverUdp(.{ 10, 0, 0, 1 }, 7, 40002, "gone");
    deliverUdp(.{ 10, 0, 0, 1 }, 7, 40003, "kept");
    var from: RecvFrom = .{ .ip = @splat(0), .port = 0 };
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?u16, null), recvUdp(alice, a, &buf, &from));
    try std.testing.expectEqual(@as(?u16, 4), recvUdp(bob, b, &buf, &from));
}

test "TCP listeners: only the opening owner can accept on or close them" {
    const alice: Owner = .of(&sockets[0]);
    const bob: Owner = .of(&sockets[1]);

    const id = tcp_sock.openListener(alice, 40004) orelse return error.SocketOpenFailed;
    defer tcp_sock.closeAllOwnedBy(alice);

    // bob's accept sees "no such listener" (null) instead of blocking on alice's.
    try std.testing.expectEqual(@as(?u8, null), tcp_sock.accept(bob, id));
    try std.testing.expectEqual(@as(?u8, null), tcp_sock.accept(.kernel, id));

    // bob closing it has no effect: alice's listener is still open ...
    tcp_sock.closeSocket(bob, id);
    try std.testing.expect(tcp_sock.ownedBy(alice, id));
    // ... until alice closes it.
    tcp_sock.closeSocket(alice, id);
    try std.testing.expect(!tcp_sock.ownedBy(alice, id));
}
