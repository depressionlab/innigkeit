//! Ethernet II framing.

const std = @import("std");

pub const MAC_LEN: usize = 6;
pub const HEADER_LEN: usize = 14;

pub const EtherType = enum(u16) {
    ipv4 = 0x0800,
    arp = 0x0806,
    ipv6 = 0x86DD,
    _,
};

pub const Header = extern struct {
    dst: [MAC_LEN]u8,
    src: [MAC_LEN]u8,
    ethertype: u16, // big-endian
};

/// Parse an Ethernet frame. Returns the header and payload slice, or null if too short.
pub fn parse(frame: []const u8) ?struct { hdr: *const Header, payload: []const u8 } {
    if (frame.len < HEADER_LEN) return null;
    return .{
        .hdr = @ptrCast(frame[0..HEADER_LEN]),
        .payload = frame[HEADER_LEN..],
    };
}

/// Write an Ethernet header at `buf[0..14]`.
pub fn writeHeader(buf: []u8, dst: *const [MAC_LEN]u8, src: *const [MAC_LEN]u8, etype: EtherType) void {
    @memcpy(buf[0..6], dst);
    @memcpy(buf[6..12], src);
    std.mem.writeInt(u16, buf[12..14], @intFromEnum(etype), .big);
}

/// Broadcast MAC address.
pub const BROADCAST: [MAC_LEN]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

const testing = @import("std").testing;

test "ethernet: parse rejects short frame" {
    const frame = [_]u8{0x00} ** 10;
    try testing.expectEqual(@as(?@TypeOf(parse(&frame).?), null), parse(&frame));
}

test "ethernet: writeHeader and parse roundtrip" {
    const dst = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    const src = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    var buf: [HEADER_LEN + 4]u8 = undefined;
    @memset(buf[HEADER_LEN..], 0xAB);
    writeHeader(&buf, &dst, &src, .ipv4);

    const result = parse(&buf) orelse return error.ParseFailed;
    try testing.expectEqualSlices(u8, &dst, &result.hdr.dst);
    try testing.expectEqualSlices(u8, &src, &result.hdr.src);
    const etype = std.mem.readInt(u16, std.mem.asBytes(&result.hdr.ethertype), .big);
    try testing.expectEqual(@as(u16, 0x0800), etype);
    try testing.expectEqual(@as(usize, 4), result.payload.len);
}
