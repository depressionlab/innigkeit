//! ICMP v4 echo request / reply (ping).

const eth = @import("ethernet.zig");
const ipv4 = @import("ipv4.zig");
const std = @import("std");

pub const ICMP_ECHO_REQUEST: u8 = 8;
pub const ICMP_ECHO_REPLY: u8 = 0;
pub const HEADER_LEN: usize = 8;

/// Parse an ICMP packet.
pub fn parseEcho(data: []const u8) ?struct {
    type_: u8,
    id: u16,
    seq: u16,
    payload: []const u8,
} {
    if (data.len < HEADER_LEN) return null;
    return .{
        .type_ = data[0],
        .id = std.mem.readInt(u16, data[4..6], .big),
        .seq = std.mem.readInt(u16, data[6..8], .big),
        .payload = data[HEADER_LEN..],
    };
}

/// Build an ICMP echo request into `out`.
pub fn buildEchoRequest(
    out: []u8,
    our_mac: *const [6]u8,
    dst_mac: *const [6]u8,
    our_ip: *const [4]u8,
    dst_ip: *const [4]u8,
    id: u16,
    seq: u16,
    payload: []const u8,
    ip_id: u16,
) usize {
    const total = eth.HEADER_LEN + ipv4.HEADER_LEN + HEADER_LEN + payload.len;
    if (out.len < total) return 0;

    eth.writeHeader(out[0..14], dst_mac, our_mac, .ipv4);

    const ip_buf = out[eth.HEADER_LEN..];
    ipv4.writeHeader(ip_buf[0..20], ip_id, .icmp, our_ip, dst_ip, HEADER_LEN + payload.len);

    const icmp = ip_buf[ipv4.HEADER_LEN..];
    icmp[0] = ICMP_ECHO_REQUEST;
    icmp[1] = 0;
    std.mem.writeInt(u16, icmp[2..4], 0, .big);
    std.mem.writeInt(u16, icmp[4..6], id, .big);
    std.mem.writeInt(u16, icmp[6..8], seq, .big);
    @memcpy(icmp[8..][0..payload.len], payload);

    const icmp_len = HEADER_LEN + payload.len;
    const csum = ipv4.checksum(icmp[0..icmp_len]);
    std.mem.writeInt(u16, icmp[2..4], csum, .big);

    return total;
}

/// Build an ICMP echo reply into `out`.
/// `out` must have room for eth_header(14) + ip_header(20) + icmp_header(8) + payload.
pub fn buildEchoReply(
    out: []u8,
    our_mac: *const [6]u8,
    our_ip: *const [4]u8,
    req_mac: *const [6]u8,
    req_ip: *const [4]u8,
    id: u16,
    seq: u16,
    payload: []const u8,
    ip_id: u16,
) usize {
    const total = eth.HEADER_LEN + ipv4.HEADER_LEN + HEADER_LEN + payload.len;
    std.debug.assert(out.len >= total);

    eth.writeHeader(out[0..14], req_mac, our_mac, .ipv4);

    const ip_buf = out[eth.HEADER_LEN..];
    ipv4.writeHeader(ip_buf[0..20], ip_id, .icmp, our_ip, req_ip, HEADER_LEN + payload.len);

    const icmp = ip_buf[ipv4.HEADER_LEN..];
    icmp[0] = ICMP_ECHO_REPLY;
    icmp[1] = 0; // code
    std.mem.writeInt(u16, icmp[2..4], 0, .big); // checksum placeholder
    std.mem.writeInt(u16, icmp[4..6], id, .big);
    std.mem.writeInt(u16, icmp[6..8], seq, .big);
    @memcpy(icmp[8..][0..payload.len], payload);

    // ICMP checksum covers header + data.
    const icmp_len = HEADER_LEN + payload.len;
    const csum = ipv4.checksum(icmp[0..icmp_len]);
    std.mem.writeInt(u16, icmp[2..4], csum, .big);

    return total;
}

test "icmp: buildEchoReply sets type=REPLY and valid checksum" {
    const our_mac = [_]u8{ 0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC };
    const our_ip = [_]u8{ 192, 168, 1, 1 };
    const req_mac = [_]u8{ 0x52, 0x54, 0x00, 0x11, 0x22, 0x33 };
    const req_ip = [_]u8{ 192, 168, 1, 2 };
    const payload = "ping";
    const total = eth.HEADER_LEN + ipv4.HEADER_LEN + HEADER_LEN + payload.len;
    var buf: [total]u8 = undefined;

    const written = buildEchoReply(&buf, &our_mac, &our_ip, &req_mac, &req_ip, 0x1234, 7, payload, 1);
    try std.testing.expectEqual(total, written);

    const icmp = buf[eth.HEADER_LEN + ipv4.HEADER_LEN ..];
    try std.testing.expectEqual(@as(u8, ICMP_ECHO_REPLY), icmp[0]);
    try std.testing.expectEqual(@as(u8, 0), icmp[1]); // code must be 0

    // Re-sum the ICMP segment; with checksum filled in, one's-complement sum = 0xFFFF.
    const icmp_len = HEADER_LEN + payload.len;
    var acc: u32 = 0;
    var i: usize = 0;
    while (i + 1 < icmp_len) : (i += 2)
        acc += @as(u32, std.mem.readInt(u16, icmp[i..][0..2], .big));
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    try std.testing.expectEqual(@as(u32, 0xFFFF), acc);
}

test "icmp: parseEcho round-trips buildEchoReply" {
    const our_mac = [_]u8{0} ** 6;
    const our_ip = [_]u8{ 10, 0, 0, 1 };
    const req_mac = [_]u8{0} ** 6;
    const req_ip = [_]u8{ 10, 0, 0, 2 };
    const payload = "hello icmp";
    const total = eth.HEADER_LEN + ipv4.HEADER_LEN + HEADER_LEN + payload.len;
    var buf: [total]u8 = undefined;

    _ = buildEchoReply(&buf, &our_mac, &our_ip, &req_mac, &req_ip, 99, 5, payload, 0);

    const icmp_data = buf[eth.HEADER_LEN + ipv4.HEADER_LEN ..];
    const pkt = parseEcho(icmp_data) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u8, ICMP_ECHO_REPLY), pkt.type_);
    try std.testing.expectEqual(@as(u16, 99), pkt.id);
    try std.testing.expectEqual(@as(u16, 5), pkt.seq);
    try std.testing.expectEqualSlices(u8, payload, pkt.payload);
}

test "icmp: parseEcho rejects short packet" {
    const short = [_]u8{0x08} ** 4;
    try std.testing.expectEqual(@as(?@TypeOf(parseEcho(&short).?), null), parseEcho(&short));
}

test "fuzz: icmp.parseEcho never panics, and payload stays within bounds" {
    try std.testing.fuzz({}, fuzzParseEcho, .{});
}

fn fuzzParseEcho(context: void, smith: *std.testing.Smith) !void {
    _ = context;

    var buf: [256]u8 = undefined;
    const len = smith.value(u8);
    const data = buf[0..len];
    smith.bytes(data);

    const pkt = parseEcho(data) orelse return;

    const data_start = @intFromPtr(data.ptr);
    const data_end = data_start + data.len;
    const payload_start = @intFromPtr(pkt.payload.ptr);
    const payload_end = payload_start + pkt.payload.len;
    try std.testing.expect(payload_start >= data_start and payload_end <= data_end);
}
