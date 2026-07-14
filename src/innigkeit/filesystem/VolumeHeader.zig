//! Multi-keyslot volume header codec.
//!
//! A plaintext sector-0 header that carries the volume key wrapped several ways,
//! one per *keyslot*, so any single unlock method recovers the same AES-XTS
//! volume key:
//!   - slot type `tpm_pcr`: TPM-sealed to the boot PCR policy (primary)
//!   - slot type `passphrase`: Argon2id passphrase (FileVault-style recovery)
//!   - (reserved) `hw_token`: future YubiKey/FIDO2 slot
//!
//! Std-only and generic over slot *bytes*, so the freestanding kernel and a
//! host/userspace recovery tool share one on-disk format. The kernel fills the
//! TPM slot (it owns `SealedObject`); the recovery tool fills the passphrase
//! slot (it owns Argon2id + an allocator/Io). Neither needs the other's crypto.
//!
//! Wire format (little-endian):
//! ```
//!   magic[8]="INNIKVOL" || version(u32) || slot_count(u32) || reserved[16] ||
//!   slot_count × ( type(u32) || len(u32) || payload[len] )
//! ```

const std = @import("std");

pub const magic = "INNIKVOL".*;
pub const version: u32 = 2;
pub const header_start = 8 + 4 + 4 + 16; // magic || version || count || reserved = 32
pub const max_slots = 8;

pub const SlotType = enum(u32) {
    empty = 0,
    tpm_pcr = 1,
    passphrase = 2,
    hw_token = 3,
    _,
};

pub const Slot = struct {
    type: SlotType,
    /// Payload bytes (borrowed from the caller's buffer on parse).
    bytes: []const u8,
};

pub const Error = error{ BadHeader, TooManySlots, TooLarge };

pub const Header = struct {
    slots: [max_slots]Slot = undefined,
    count: usize = 0,

    /// Bytes of the first slot of type `t`, or null.
    pub fn find(self: *const Header, t: SlotType) ?[]const u8 {
        for (self.slots[0..self.count]) |s| {
            if (s.type == t) return s.bytes;
        }
        return null;
    }
};

/// Parse a header out of `buf` (the header sector). Returned slot byte-slices
/// borrow from `buf`.
pub fn parse(buf: []const u8) Error!Header {
    if (buf.len < header_start) return Error.BadHeader;
    if (!std.mem.eql(u8, buf[0..8], &magic)) return Error.BadHeader;
    if (readU32(buf, 8) != version) return Error.BadHeader;
    const count = readU32(buf, 12);
    if (count > max_slots) return Error.TooManySlots;

    var header: Header = .{ .count = count };
    var off: usize = header_start;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (off + 8 > buf.len) return Error.BadHeader;
        const t: SlotType = @enumFromInt(readU32(buf, off));
        const len = readU32(buf, off + 4);
        off += 8;
        if (off + len > buf.len) return Error.BadHeader;
        header.slots[i] = .{ .type = t, .bytes = buf[off..][0..len] };
        off += len;
    }
    return header;
}

/// Serialize `slots` into `buf` (zero-filled first). Fails if it doesn't fit.
pub fn write(buf: []u8, slots: []const Slot) Error!void {
    if (slots.len > max_slots) return Error.TooManySlots;
    var need: usize = header_start;
    for (slots) |s| need += 8 + s.bytes.len;
    if (need > buf.len) return Error.TooLarge;

    @memset(buf, 0);
    @memcpy(buf[0..8], &magic);
    writeU32(buf, 8, version);
    writeU32(buf, 12, @intCast(slots.len));
    // buf[16..32] reserved (zero).

    var off: usize = header_start;
    for (slots) |s| {
        writeU32(buf, off, @intFromEnum(s.type));
        writeU32(buf, off + 4, @intCast(s.bytes.len));
        off += 8;
        @memcpy(buf[off..][0..s.bytes.len], s.bytes);
        off += s.bytes.len;
    }
}

fn readU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn writeU32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

test "volume header: write then parse round-trips multiple slots" {
    var buf: [512]u8 = undefined;
    const tpm_payload = [_]u8{0xAB} ** 40;
    const pass_payload = [_]u8{0xCD} ** 132;
    try write(&buf, &.{
        .{ .type = .tpm_pcr, .bytes = &tpm_payload },
        .{ .type = .passphrase, .bytes = &pass_payload },
    });

    const h = try parse(&buf);
    try std.testing.expectEqual(@as(usize, 2), h.count);
    try std.testing.expect(std.mem.eql(u8, &tpm_payload, h.find(.tpm_pcr).?));
    try std.testing.expect(std.mem.eql(u8, &pass_payload, h.find(.passphrase).?));
    try std.testing.expect(h.find(.hw_token) == null);
}

test "volume header: rejects bad magic / version / overflow" {
    var buf: [512]u8 = undefined;
    try write(&buf, &.{.{ .type = .tpm_pcr, .bytes = &[_]u8{1} ** 8 }});

    var bad = buf;
    bad[0] ^= 0xFF;
    try std.testing.expectError(Error.BadHeader, parse(&bad));

    bad = buf;
    std.mem.writeInt(u32, bad[8..12], 999, .little);
    try std.testing.expectError(Error.BadHeader, parse(&bad));

    // A slot claiming to extend past the buffer is rejected.
    bad = buf;
    std.mem.writeInt(u32, bad[header_start + 4 ..][0..4], 1000, .little);
    try std.testing.expectError(Error.BadHeader, parse(&bad));
}

test "volume header: write fails when slots exceed the sector" {
    var buf: [64]u8 = undefined;
    const big = [_]u8{0} ** 100;
    try std.testing.expectError(Error.TooLarge, write(&buf, &.{.{ .type = .passphrase, .bytes = &big }}));
}

test "fuzz: VolumeHeader.parse never panics and every slot stays within bounds" {
    try std.testing.fuzz({}, fuzzParse, .{});
}

fn fuzzParse(context: void, smith: *std.testing.Smith) !void {
    _ = context;

    var buf: [512]u8 = undefined;
    const len = smith.value(u9); // 0..511, covers a real 512-byte sector minus one
    const input = buf[0..len];
    smith.bytes(input);

    const header = parse(input) catch return;

    // Every returned slot must borrow strictly from `input` so a slot
    // pointing outside it would mean the offset/length arithmetic in
    // parse() let something escape the buffer it's supposed to be bounded
    // by.
    const input_start = @intFromPtr(input.ptr);
    const input_end = input_start + input.len;
    for (header.slots[0..header.count]) |slot| {
        const slot_start = @intFromPtr(slot.bytes.ptr);
        const slot_end = slot_start + slot.bytes.len;
        try std.testing.expect(slot_start >= input_start and slot_end <= input_end);
    }
}
