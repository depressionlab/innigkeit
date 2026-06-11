//! TCP segment header parsing and construction.
//!
//! This file is intentionally free of kernel imports so it can be compiled
//! and tested natively on the host without QEMU. The socket integration
//! layer (Socket.zig) owns the kernel-specific bits.

const std = @import("std");

pub const HEADER_MIN: usize = 20;

/// TCP control flags (bit positions in the flags byte).
pub const Flags = packed struct(u8) {
    fin: bool = false,
    syn: bool = false,
    rst: bool = false,
    psh: bool = false,
    ack: bool = false,
    urg: bool = false,
    ece: bool = false,
    cwr: bool = false,
};

/// A parsed TCP segment.
pub const Segment = struct {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: Flags,
    window: u16,
    checksum: u16,
    /// Slice into the original byte buffer, valid only while the buffer lives.
    payload: []const u8,
    /// MSS option value from SYN segments (0 = not present).
    mss: u16,
};

/// Parse a TCP segment from a raw byte slice.
/// Returns null if the data is too short or the data-offset field is invalid.
pub fn parse(data: []const u8) ?Segment {
    if (data.len < HEADER_MIN) return null;
    const data_offset: usize = (data[12] >> 4) * 4;
    if (data_offset < HEADER_MIN or data.len < data_offset) return null;

    const src_port = std.mem.readInt(u16, data[0..2], .big);
    const dst_port = std.mem.readInt(u16, data[2..4], .big);
    const seq = std.mem.readInt(u32, data[4..8], .big);
    const ack = std.mem.readInt(u32, data[8..12], .big);
    const flags: Flags = @bitCast(data[13]);
    const window = std.mem.readInt(u16, data[14..16], .big);
    const checksum = std.mem.readInt(u16, data[16..18], .big);

    // Scan TCP options for MSS (kind=2, length=4).
    var mss: u16 = 0;
    var opt = data[HEADER_MIN..data_offset];
    while (opt.len >= 2) {
        switch (opt[0]) {
            0 => break, // EOL
            1 => opt = opt[1..], // NOP
            else => |kind| {
                // Every multi-byte option declares its total length in its
                // second byte. A length below 2 cannot make progress and a
                // length past the remaining option space is truncated, so we
                // stop parsing on either (assuming a malformed packet).
                const len = opt[1];
                if (len < 2 or len > opt.len) break;
                if (kind == 2 and len == 4)
                    mss = std.mem.readInt(u16, opt[2..4], .big);
                opt = opt[len..];
            },
        }
    }

    return .{
        .src_port = src_port,
        .dst_port = dst_port,
        .seq = seq,
        .ack = ack,
        .flags = flags,
        .window = window,
        .checksum = checksum,
        .payload = data[data_offset..],
        .mss = mss,
    };
}

/// Write a TCP header into `buf[0..20]`.
///
/// The caller is responsible for filling in the checksum afterwards via
/// `fillChecksum`.
pub fn writeHeader(
    buf: []u8,
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: Flags,
    window: u16,
) void {
    std.debug.assert(buf.len >= HEADER_MIN);
    std.mem.writeInt(u16, buf[0..2], src_port, .big);
    std.mem.writeInt(u16, buf[2..4], dst_port, .big);
    std.mem.writeInt(u32, buf[4..8], seq, .big);
    std.mem.writeInt(u32, buf[8..12], ack, .big);
    buf[12] = 0x50; // data offset = 5 (20 bytes), reserved = 0
    buf[13] = @bitCast(flags);
    std.mem.writeInt(u16, buf[14..16], window, .big);
    std.mem.writeInt(u16, buf[16..18], 0, .big); // checksum placeholder
    std.mem.writeInt(u16, buf[18..20], 0, .big); // urgent pointer
}

/// Write a TCP header with a MSS option into `buf[0..24]`.
pub fn writeHeaderWithMss(
    buf: []u8,
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: Flags,
    window: u16,
    mss: u16,
) void {
    std.debug.assert(buf.len >= 24);
    std.mem.writeInt(u16, buf[0..2], src_port, .big);
    std.mem.writeInt(u16, buf[2..4], dst_port, .big);
    std.mem.writeInt(u32, buf[4..8], seq, .big);
    std.mem.writeInt(u32, buf[8..12], ack, .big);
    buf[12] = 0x60; // data offset = 6 (24 bytes)
    buf[13] = @bitCast(flags);
    std.mem.writeInt(u16, buf[14..16], window, .big);
    std.mem.writeInt(u16, buf[16..18], 0, .big); // checksum placeholder
    std.mem.writeInt(u16, buf[18..20], 0, .big); // urgent pointer
    // MSS option: kind=2, len=4, value
    buf[20] = 2;
    buf[21] = 4;
    std.mem.writeInt(u16, buf[22..24], mss, .big);
}

/// Compute and write the TCP checksum using the IPv4 pseudo-header.
/// `tcp_buf` must be the full TCP segment (header + payload).
pub fn fillChecksum(
    tcp_buf: []u8,
    src_ip: *const [4]u8,
    dst_ip: *const [4]u8,
) void {
    // Zero the checksum field first.
    std.mem.writeInt(u16, tcp_buf[16..18], 0, .big);
    const csum = pseudoChecksum(tcp_buf, src_ip, dst_ip);
    std.mem.writeInt(u16, tcp_buf[16..18], csum, .big);
}

/// Verify the TCP checksum. Returns true if valid.
pub fn verifyChecksum(
    tcp_buf: []const u8,
    src_ip: *const [4]u8,
    dst_ip: *const [4]u8,
) bool {
    return pseudoChecksum(tcp_buf, src_ip, dst_ip) == 0xFFFF or
        pseudoChecksum(tcp_buf, src_ip, dst_ip) == 0x0000;
}

fn pseudoChecksum(
    tcp_buf: []const u8,
    src_ip: *const [4]u8,
    dst_ip: *const [4]u8,
) u16 {
    var acc: u32 = 0;
    // Pseudo-header: src_ip (4), dst_ip (4), zero (1), proto=6 (1), tcp_len (2)
    acc += (@as(u32, src_ip[0]) << 8) | src_ip[1];
    acc += (@as(u32, src_ip[2]) << 8) | src_ip[3];
    acc += (@as(u32, dst_ip[0]) << 8) | dst_ip[1];
    acc += (@as(u32, dst_ip[2]) << 8) | dst_ip[3];
    acc += 6; // TCP protocol
    acc += @as(u32, @intCast(tcp_buf.len));
    // TCP data
    var i: usize = 0;
    while (i + 1 < tcp_buf.len) : (i += 2)
        acc += @as(u32, std.mem.readInt(u16, tcp_buf[i..][0..2], .big));
    if (i < tcp_buf.len) acc += @as(u32, tcp_buf[i]) << 8;
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    return ~@as(u16, @truncate(acc));
}

/// Wrapping sequence-number comparison: returns true if `a` is after `b`
/// in the 32-bit sequence space (i.e. SEQ_GT(a, b) in Linux terms).
pub fn seqGt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

/// Returns true if `a >= b` in the sequence space.
pub fn seqGe(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

test "tcp segment: parse rejects short input" {
    const short = [_]u8{0} ** 10;
    try std.testing.expectEqual(@as(?Segment, null), parse(&short));
}

test "tcp segment: parse SYN with no options" {
    var buf = [_]u8{0} ** 20;
    writeHeader(&buf, 1234, 80, 0xDEAD, 0, .{ .syn = true }, 65535);
    fillChecksum(&buf, &.{ 10, 0, 0, 1 }, &.{ 10, 0, 0, 2 });
    const seg = parse(&buf) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u16, 1234), seg.src_port);
    try std.testing.expectEqual(@as(u16, 80), seg.dst_port);
    try std.testing.expectEqual(@as(u32, 0xDEAD), seg.seq);
    try std.testing.expect(seg.flags.syn);
    try std.testing.expect(!seg.flags.ack);
    try std.testing.expectEqual(@as(usize, 0), seg.payload.len);
    try std.testing.expectEqual(@as(u16, 0), seg.mss);
}

test "tcp segment: parse SYN with MSS option" {
    var buf = [_]u8{0} ** 24;
    writeHeaderWithMss(&buf, 5000, 80, 1, 0, .{ .syn = true }, 8192, 1460);
    fillChecksum(&buf, &.{ 127, 0, 0, 1 }, &.{ 127, 0, 0, 2 });
    const seg = parse(&buf) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u16, 1460), seg.mss);
    try std.testing.expect(seg.flags.syn);
}

test "tcp segment: parse ACK with payload" {
    var buf = [_]u8{0} ** (20 + 5);
    writeHeader(buf[0..20], 9999, 22, 100, 200, .{ .ack = true, .psh = true }, 32768);
    buf[20..25].* = "hello".*;
    fillChecksum(&buf, &.{ 1, 2, 3, 4 }, &.{ 5, 6, 7, 8 });
    const seg = parse(&buf) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u32, 100), seg.seq);
    try std.testing.expectEqual(@as(u32, 200), seg.ack);
    try std.testing.expect(seg.flags.ack);
    try std.testing.expect(seg.flags.psh);
    try std.testing.expectEqualSlices(u8, "hello", seg.payload);
}

test "tcp segment: seqGt wraps correctly" {
    // 0xFFFFFFFF + 1 wraps to 0; 0 is after 0xFFFFFFFF
    try std.testing.expect(seqGt(0, 0xFFFFFFFF));
    try std.testing.expect(!seqGt(0xFFFFFFFF, 0));
    try std.testing.expect(!seqGt(42, 42));
    try std.testing.expect(seqGt(43, 42));
}

test "tcp segment: malformed options terminate parsing" {
    // SYN with data_offset=6 (4 option bytes): kind=2 (MSS) with a zero
    // length byte previously looped forever; parsing must terminate and
    // simply skip the malformed option.
    var buf = [_]u8{0} ** 24;
    writeHeader(buf[0..20], 1, 2, 0, 0, .{ .syn = true }, 512);
    buf[12] = 0x60; // data offset = 6 words (24 bytes)
    buf[20] = 2; // kind = MSS
    buf[21] = 0; // malformed length
    fillChecksum(&buf, &.{ 1, 2, 3, 4 }, &.{ 5, 6, 7, 8 });
    const seg = parse(&buf) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u16, 0), seg.mss);

    // Option whose declared length overruns the option space is ignored too.
    buf[21] = 40;
    fillChecksum(&buf, &.{ 1, 2, 3, 4 }, &.{ 5, 6, 7, 8 });
    const seg2 = parse(&buf) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u16, 0), seg2.mss);
}

test "tcp segment: parse rejects invalid data offset" {
    var buf = [_]u8{0} ** 20;
    writeHeader(&buf, 1, 2, 0, 0, .{ .syn = true }, 512);

    // Data offset below the 20-byte minimum (3 words = 12 bytes).
    buf[12] = 0x30;
    try std.testing.expectEqual(@as(?Segment, null), parse(&buf));

    // Data offset past the end of the buffer (7 words = 28 > 20 bytes).
    buf[12] = 0x70;
    try std.testing.expectEqual(@as(?Segment, null), parse(&buf));
}

test "tcp segment: MSS option after NOP padding ending at header end" {
    // data offset = 7 (28 bytes): four NOPs then an MSS option whose
    // declared length lands exactly on the header end (len == remaining).
    var buf = [_]u8{0} ** 28;
    writeHeader(buf[0..20], 4242, 443, 7, 0, .{ .syn = true }, 1024);
    buf[12] = 0x70;
    buf[20] = 1; // NOP
    buf[21] = 1; // NOP
    buf[22] = 1; // NOP
    buf[23] = 1; // NOP
    buf[24] = 2; // kind = MSS
    buf[25] = 4; // len = 4, consumes the rest of the option space exactly
    std.mem.writeInt(u16, buf[26..28], 1400, .big);
    fillChecksum(&buf, &.{ 10, 0, 0, 1 }, &.{ 10, 0, 0, 2 });

    const seg = parse(&buf) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u16, 1400), seg.mss);
    try std.testing.expectEqual(@as(usize, 0), seg.payload.len);
}
