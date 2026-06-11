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
    buf[9] = @intFromEnum(proto);
    std.mem.writeInt(u16, buf[10..12], 0, .big); // checksum placeholder
    @memcpy(buf[12..16], src);
    @memcpy(buf[16..20], dst);
    // Fill checksum
    const csum = checksum(buf[0..HEADER_LEN]);
    std.mem.writeInt(u16, buf[10..12], csum, .big);
}

test "ipv4: checksum of all-zeros is all-ones" {
    const data = [_]u8{0} ** 20;
    try std.testing.expectEqual(@as(u16, 0xFFFF), checksum(&data));
}

test "ipv4: checksum of RFC 791 example header" {
    // IP header with checksum field zeroed; verify result matches expected.
    var hdr: [20]u8 = .{
        0x45, 0x00, 0x00, 0x3c, 0x1c, 0x46, 0x40, 0x00,
        0x40, 0x06, 0x00, 0x00, // checksum = 0
        0xac, 0x10, 0x0a, 0x63,
        0xac, 0x10, 0x0a, 0x0c,
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
    const short = [_]u8{0x45} ** 10;
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
        .proto = @enumFromInt(data[9]),
        .payload = data[ihl..total],
    };
}
