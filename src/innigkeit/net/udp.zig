//! UDP datagram construction and parsing.

const std = @import("std");
const eth = @import("ethernet.zig");
const ipv4 = @import("ipv4.zig");

pub const HEADER_LEN: usize = 8;

/// Parse a UDP datagram.
pub fn parse(data: []const u8) ?struct {
    src_port: u16,
    dst_port: u16,
    payload: []const u8,
} {
    if (data.len < HEADER_LEN) return null;
    const length = std.mem.readInt(u16, data[4..6], .big);
    if (data.len < length) return null;
    return .{
        .src_port = std.mem.readInt(u16, data[0..2], .big),
        .dst_port = std.mem.readInt(u16, data[2..4], .big),
        .payload = data[HEADER_LEN..@min(data.len, length)],
    };
}

/// Build a UDP datagram wrapped in Ethernet + IPv4 into `out`.
/// Returns bytes written, or 0 if `out` is too small.
pub fn buildPacket(
    out: []u8,
    our_mac: *const [6]u8,
    dst_mac: *const [6]u8,
    our_ip: *const [4]u8,
    dst_ip: *const [4]u8,
    src_port: u16,
    dst_port: u16,
    payload: []const u8,
    ip_id: u16,
) usize {
    const total = eth.HEADER_LEN + ipv4.HEADER_LEN + HEADER_LEN + payload.len;
    if (out.len < total) return 0;

    eth.writeHeader(out[0..14], dst_mac, our_mac, .ipv4);

    const ip_buf = out[eth.HEADER_LEN..];
    ipv4.writeHeader(ip_buf[0..20], ip_id, .udp, our_ip, dst_ip, HEADER_LEN + payload.len);

    const udp = ip_buf[ipv4.HEADER_LEN..];
    std.mem.writeInt(u16, udp[0..2], src_port, .big);
    std.mem.writeInt(u16, udp[2..4], dst_port, .big);
    const udp_len: u16 = @intCast(HEADER_LEN + payload.len);
    std.mem.writeInt(u16, udp[4..6], udp_len, .big);
    std.mem.writeInt(u16, udp[6..8], 0, .big); // checksum (optional for IPv4)
    @memcpy(udp[8..][0..payload.len], payload);

    return total;
}

test "udp: parse rejects short datagram" {
    const short = [_]u8{0x00} ** 4;
    try std.testing.expectEqual(@as(?@TypeOf(parse(&short).?), null), parse(&short));
}

test "udp: buildPacket then parse roundtrip" {
    const our_mac = [_]u8{ 0x52, 0x54, 0x00, 0x01, 0x02, 0x03 };
    const dst_mac = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const our_ip = [_]u8{ 192, 168, 1, 10 };
    const dst_ip = [_]u8{ 192, 168, 1, 255 };
    const payload = "hello UDP";

    const total = eth.HEADER_LEN + ipv4.HEADER_LEN + HEADER_LEN + payload.len;
    var buf: [total]u8 = undefined;
    const written = buildPacket(&buf, &our_mac, &dst_mac, &our_ip, &dst_ip, 1234, 5678, payload, 42);
    try std.testing.expectEqual(total, written);

    // Parse out the UDP layer (skip Ethernet + IPv4 headers).
    const udp_data = buf[eth.HEADER_LEN + ipv4.HEADER_LEN ..];
    const pkt = parse(udp_data) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u16, 1234), pkt.src_port);
    try std.testing.expectEqual(@as(u16, 5678), pkt.dst_port);
    try std.testing.expectEqualSlices(u8, payload, pkt.payload);
}
