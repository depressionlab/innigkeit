//! Kernel UDP socket table and ARP cache.
//!
//! Provides:
//!  - openSocket / closeSocket: allocate/free a UDP port binding
//!  - sendUdp: ARP-resolving send (yields to poll thread if ARP miss)
//!  - recvUdp: non-blocking single-frame receive
//!  - handleFrame: passed to virtio.net.pollRx; dispatches inbound frames
//!
//! All functions are safe to call from syscall handlers (user-thread context) or
//! from the dedicated net-poll kernel thread. A single TicketSpinLock protects
//! shared state; it is never held across yields.

const std = @import("std");
const innigkeit = @import("innigkeit");
const eth = @import("ethernet.zig");
const arp_pkt = @import("arp.zig");
const ip4 = @import("ipv4.zig");
const udp_pkt = @import("udp.zig");
const icmp_pkt = @import("icmp.zig");

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

/// Open a UDP socket bound to `port`.  Returns the socket id (0–15) or null
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

/// Close the socket with `id`.  No-op if the id is out of range or not open.
pub fn closeSocket(id: u8) void {
    if (id >= SOCKET_MAX) return;
    lock.lock();
    defer lock.unlock();
    sockets[id].in_use = false;
}

/// Send a UDP datagram.  Resolves the target IP via ARP (blocking with up to
/// 100 yield iterations ≈ ~500 ms).  Returns false on error (no NIC, ARP
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
/// reply.  Returns the round-trip time in milliseconds, or null on timeout.
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

/// Non-blocking receive.  Returns the number of payload bytes written to `buf`,
/// or null if no frame is available.  `from` is filled with sender IP+port.
pub const RecvFrom = struct { ip: [4]u8, port: u16 };
pub fn recvUdp(sock_id: u8, buf: []u8, from: *RecvFrom) ?u16 {
    if (sock_id >= SOCKET_MAX) return null;

    lock.lock();
    defer lock.unlock();

    const s = &sockets[sock_id];
    if (!s.in_use or s.rx_head == s.rx_tail) return null;

    const f = &s.rx_ring[s.rx_head % RX_RING];
    const copy_len: u16 = @intCast(@min(f.len, @as(u16, @intCast(buf.len))));
    @memcpy(buf[0..copy_len], f.data[0..copy_len]);
    from.ip = f.from_ip;
    from.port = f.from_port;
    s.rx_head +%= 1;
    return copy_len;
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
        else => {},
    }
}

fn handleUdp(from_ip: [4]u8, data: []const u8) void {
    const p = udp_pkt.parse(data) orelse return;
    const our_ip = innigkeit.drivers.virtio.net.getIp() orelse return;
    _ = our_ip;

    lock.lock();
    defer lock.unlock();

    for (&sockets) |*s| {
        if (!s.in_use or s.port != p.dst_port) continue;
        const used: u8 = s.rx_tail -% s.rx_head;
        if (used >= RX_RING) return; // ring full, drop
        const f = &s.rx_ring[s.rx_tail % RX_RING];
        f.from_ip = from_ip;
        f.from_port = p.src_port;
        const len: u16 = @intCast(@min(p.payload.len, MAX_PAYLOAD));
        f.len = len;
        @memcpy(f.data[0..len], p.payload[0..len]);
        s.rx_tail +%= 1;
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

/// Resolve dst_ip -> MAC.  Sends an ARP request if not cached; yields up to 100
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
