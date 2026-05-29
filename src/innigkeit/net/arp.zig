//! ARP (Address Resolution Protocol) for IPv4 over Ethernet.

const std = @import("std");
const eth = @import("ethernet.zig");

pub const PACKET_LEN: usize = 28; // fixed for IPv4/Ethernet ARP

pub const Op = enum(u16) {
    request = 1,
    reply = 2,
};

/// ARP packet for IPv4 / Ethernet (fixed size).
pub const Packet = extern struct {
    hw_type: u16, // big-endian, always 1 (Ethernet)
    proto_type: u16, // big-endian, always 0x0800 (IPv4)
    hw_size: u8, // always 6
    proto_size: u8, // always 4
    op: u16, // big-endian
    sender_mac: [6]u8,
    sender_ip: [4]u8,
    target_mac: [6]u8,
    target_ip: [4]u8,
};

pub fn buildRequest(
    out: []u8,
    our_mac: *const [6]u8,
    our_ip: *const [4]u8,
    target_ip: *const [4]u8,
) void {
    std.debug.assert(out.len >= eth.HEADER_LEN + PACKET_LEN);
    eth.writeHeader(out[0..14], &eth.BROADCAST, our_mac, .arp);
    const p: *Packet = @ptrCast(@alignCast(out[eth.HEADER_LEN..]));
    std.mem.writeInt(u16, std.mem.asBytes(&p.hw_type), 1, .big);
    std.mem.writeInt(u16, std.mem.asBytes(&p.proto_type), 0x0800, .big);
    p.hw_size = 6;
    p.proto_size = 4;
    std.mem.writeInt(u16, std.mem.asBytes(&p.op), @intFromEnum(Op.request), .big);
    @memcpy(&p.sender_mac, our_mac);
    @memcpy(&p.sender_ip, our_ip);
    @memset(&p.target_mac, 0);
    @memcpy(&p.target_ip, target_ip);
}

pub fn buildReply(
    out: []u8,
    our_mac: *const [6]u8,
    our_ip: *const [4]u8,
    req_mac: *const [6]u8,
    req_ip: *const [4]u8,
) void {
    std.debug.assert(out.len >= eth.HEADER_LEN + PACKET_LEN);
    eth.writeHeader(out[0..14], req_mac, our_mac, .arp);
    const p: *Packet = @ptrCast(@alignCast(out[eth.HEADER_LEN..]));
    std.mem.writeInt(u16, std.mem.asBytes(&p.hw_type), 1, .big);
    std.mem.writeInt(u16, std.mem.asBytes(&p.proto_type), 0x0800, .big);
    p.hw_size = 6;
    p.proto_size = 4;
    std.mem.writeInt(u16, std.mem.asBytes(&p.op), @intFromEnum(Op.reply), .big);
    @memcpy(&p.sender_mac, our_mac);
    @memcpy(&p.sender_ip, our_ip);
    @memcpy(&p.target_mac, req_mac);
    @memcpy(&p.target_ip, req_ip);
}

test "arp: buildRequest fields are correct" {
    const our_mac = [_]u8{ 0x52, 0x54, 0x00, 0x01, 0x02, 0x03 };
    const our_ip = [_]u8{ 192, 168, 1, 10 };
    const tgt_ip = [_]u8{ 192, 168, 1, 1 };

    var buf: [eth.HEADER_LEN + PACKET_LEN]u8 = undefined;
    buildRequest(&buf, &our_mac, &our_ip, &tgt_ip);

    // Ethernet dst must be broadcast.
    try std.testing.expectEqualSlices(u8, &eth.BROADCAST, buf[0..6]);
    // Ethernet src must be our_mac.
    try std.testing.expectEqualSlices(u8, &our_mac, buf[6..12]);
    // EtherType 0x0806.
    try std.testing.expectEqual(@as(u16, 0x0806), std.mem.readInt(u16, buf[12..14], .big));

    const p: *const Packet = @ptrCast(@alignCast(buf[eth.HEADER_LEN..]));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, std.mem.asBytes(&p.op), .big));
    try std.testing.expectEqualSlices(u8, &our_ip, &p.sender_ip);
    try std.testing.expectEqualSlices(u8, &tgt_ip, &p.target_ip);
}

test "arp: buildReply fields are correct" {
    const our_mac = [_]u8{ 0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC };
    const our_ip = [_]u8{ 10, 0, 0, 1 };
    const req_mac = [_]u8{ 0x52, 0x54, 0x00, 0x11, 0x22, 0x33 };
    const req_ip = [_]u8{ 10, 0, 0, 2 };

    var buf: [eth.HEADER_LEN + PACKET_LEN]u8 = undefined;
    buildReply(&buf, &our_mac, &our_ip, &req_mac, &req_ip);

    // Ethernet dst must be requester's mac.
    try std.testing.expectEqualSlices(u8, &req_mac, buf[0..6]);
    const p: *const Packet = @ptrCast(@alignCast(buf[eth.HEADER_LEN..]));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, std.mem.asBytes(&p.op), .big));
    try std.testing.expectEqualSlices(u8, &our_mac, &p.sender_mac);
    try std.testing.expectEqualSlices(u8, &req_mac, &p.target_mac);
}
