//! IPv4 header construction and parsing.

const std = @import("std");

pub const HEADER_LEN: usize = 20; // minimum (no options)
pub const TTL_DEFAULT: u8 = 64;

pub const Protocol = enum(u8) {
    icmp = 1,
    tcp = 6,
    udp = 17,
    _,
};

/// Compute the one's-complement checksum of `data`.
pub fn checksum(data: []const u8) u16 {
    var acc: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        acc += @as(u32, std.mem.readInt(u16, data[i..][0..2], .big));
    }
    if (i < data.len) acc += @as(u32, data[i]) << 8;
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    return ~@as(u16, @truncate(acc));
}

/// Write a minimal IPv4 header at `buf[0..20]`.
/// `id` should be unique per datagram; `proto` is Protocol enum value.
pub fn writeHeader(
    buf: []u8,
    id: u16,
    proto: Protocol,
    src: *const [4]u8,
    dst: *const [4]u8,
    payload_len: usize,
) void {
    const total: u16 = @intCast(HEADER_LEN + payload_len);
    buf[0] = 0x45; // Version 4, IHL 5 (20 bytes)
    buf[1] = 0; // DSCP/ECN
    std.mem.writeInt(u16, buf[2..4], total, .big);
    std.mem.writeInt(u16, buf[4..6], id, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big); // flags / frag offset
    buf[8] = TTL_DEFAULT;
    buf[9] = @backingInt(proto);
    std.mem.writeInt(u16, buf[10..12], 0, .big); // checksum placeholder
    @memcpy(buf[12..16], src);
    @memcpy(buf[16..20], dst);
    // Fill checksum
    const csum = checksum(buf[0..HEADER_LEN]);
    std.mem.writeInt(u16, buf[10..12], csum, .big);
}

test "ipv4: checksum of all-zeros is all-ones" {
    const data = @as([20]u8, @splat(0));
    try std.testing.expectEqual(@as(u16, 0xFFFF), checksum(&data));
}

test "ipv4: checksum of RFC 791 example header" {
    // IP header with checksum field zeroed; verify result matches expected.
    var hdr: [20]u8 = .{
        0x45, 0x00, 0x00, 0x3C, 0x1C, 0x46, 0x40, 0x00,
        0x40, 0x06, 0x00, 0x00, // checksum = 0
        0xAC, 0x10, 0x0A, 0x63,
        0xAC, 0x10, 0x0A, 0x0C,
    };
    const csum = checksum(&hdr);
    // Write it back and verify the header now checksums to 0xFFFF (one's complement).
    std.mem.writeInt(u16, hdr[10..12], csum, .big);
    // Re-checking a header with its own checksum filled in should give 0 (after fold).
    var acc: u32 = 0;
    var i: usize = 0;
    while (i + 1 < hdr.len) : (i += 2)
        acc += @as(u32, std.mem.readInt(u16, hdr[i..][0..2], .big));
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    try std.testing.expectEqual(@as(u16, 0xFFFF), @as(u16, @truncate(acc)));
}

test "ipv4: parse rejects truncated packet" {
    const short = @as([10]u8, @splat(0x45));
    try std.testing.expectEqual(@as(?@TypeOf(parse(&short).?), null), parse(&short));
}

/// Parse the first 20 bytes of an IPv4 packet.
/// Returns null if packet is too short or has bad checksum.
pub fn parse(data: []const u8) ?struct {
    src: [4]u8,
    dst: [4]u8,
    proto: Protocol,
    payload: []const u8,
} {
    if (data.len < HEADER_LEN) return null;
    const ihl: usize = (data[0] & 0x0F) * 4;
    if (ihl < HEADER_LEN or data.len < ihl) return null;
    if (data[0] >> 4 != 4) return null; // not IPv4
    if (checksum(data[0..ihl]) != 0) return null; // bad header checksum
    const total = std.mem.readInt(u16, data[2..4], .big);
    if (total < ihl or data.len < total) return null;

    var src: [4]u8 = undefined;
    var dst: [4]u8 = undefined;
    @memcpy(&src, data[12..16]);
    @memcpy(&dst, data[16..20]);

    return .{
        .src = src,
        .dst = dst,
        .proto = @fromBackingInt(@intCast(data[9])),
        .payload = data[ihl..total],
    };
}

/// Whether a packet addressed to `dst` is meant for this host: its own unicast
/// address, the limited broadcast address, or a multicast group. Anything else
/// is traffic for someone else that reached the NIC (bridged or promiscuous
/// setups, a shared segment) and must not reach a socket or get an ICMP
/// echo reply.
///
/// An unconfigured host (`our_ip` is `0.0.0.0`) has no unicast address, so it
/// matches nothing unicast. Directed subnet broadcast (e.g. `x.y.z.255`) is
/// deliberately not accepted: the stack keeps no netmask to recognise it by.
pub fn isForUs(dst: [4]u8, our_ip: [4]u8) bool {
    const unconfigured: [4]u8 = .{ 0, 0, 0, 0 };
    if (!std.mem.eql(u8, &our_ip, &unconfigured) and std.mem.eql(u8, &dst, &our_ip)) return true;
    if (std.mem.eql(u8, &dst, &.{ 255, 255, 255, 255 })) return true;
    return dst[0] >> 4 == 0b1110; // 224.0.0.0/4
}

test "isForUs: own unicast, broadcast and multicast are accepted" {
    const ours: [4]u8 = .{ 10, 0, 2, 15 };
    try std.testing.expect(isForUs(ours, ours));
    try std.testing.expect(isForUs(.{ 255, 255, 255, 255 }, ours));
    try std.testing.expect(isForUs(.{ 224, 0, 0, 251 }, ours));
    try std.testing.expect(isForUs(.{ 239, 255, 255, 250 }, ours));
}

test "isForUs: traffic for other hosts is rejected" {
    const ours: [4]u8 = .{ 10, 0, 2, 15 };
    try std.testing.expect(!isForUs(.{ 10, 0, 2, 16 }, ours));
    try std.testing.expect(!isForUs(.{ 192, 168, 1, 1 }, ours));
    try std.testing.expect(!isForUs(.{ 10, 0, 2, 255 }, ours)); // directed broadcast: no netmask
    try std.testing.expect(!isForUs(.{ 223, 255, 255, 255 }, ours)); // just below multicast
    try std.testing.expect(!isForUs(.{ 240, 0, 0, 1 }, ours)); // just above multicast
}

test "isForUs: an unconfigured host matches no unicast address" {
    const unconfigured: [4]u8 = .{ 0, 0, 0, 0 };
    try std.testing.expect(!isForUs(unconfigured, unconfigured));
    try std.testing.expect(!isForUs(.{ 10, 0, 2, 15 }, unconfigured));
    try std.testing.expect(isForUs(.{ 255, 255, 255, 255 }, unconfigured));
}
