//! Wire format for Innigkeit code-signing blobs (.codesig sidecar files).
//!
//! Fixed 144-byte structure, all fields little-endian.
//!
//! Layout:
//!   magic        [8]u8   "IKSIG\x01\x00\x00"
//!   key_id       u32     key slot (0 = default embedded key)
//!   flags        u32     reserved, must be 0
//!   elf_hash     [32]u8  Blake3 hash of the full ELF binary
//!   entitlements u64     packed Entitlements struct
//!   _pad         [24]u8  reserved, must be 0
//!   signature    [64]u8  Ed25519 over (elf_hash || entitlements_le || key_id_le)

const std = @import("std");
const Manifest = @import("Manifest.zig");

pub const magic: [8]u8 = "IKSIG\x01\x00\x00".*;

pub const SigBlob = extern struct {
    magic: [8]u8,
    key_id: u32,
    flags: u32,
    elf_hash: [32]u8,
    entitlements_raw: u64,
    _pad: [24]u8,
    signature: [64]u8,

    pub const size: usize = 144;

    comptime {
        std.debug.assert(@sizeOf(SigBlob) == size);
        std.debug.assert(@offsetOf(SigBlob, "magic") == 0);
        std.debug.assert(@offsetOf(SigBlob, "key_id") == 8);
        std.debug.assert(@offsetOf(SigBlob, "flags") == 12);
        std.debug.assert(@offsetOf(SigBlob, "elf_hash") == 16);
        std.debug.assert(@offsetOf(SigBlob, "entitlements_raw") == 48);
        std.debug.assert(@offsetOf(SigBlob, "_pad") == 56);
        std.debug.assert(@offsetOf(SigBlob, "signature") == 80);
    }

    pub fn entitlements(self: *const SigBlob) Manifest.Entitlements {
        return @bitCast(self.entitlements_raw);
    }

    /// Build the 44-byte message that Ed25519 signs/verifies.
    /// message = elf_hash(32) || entitlements_le64(8) || key_id_le32(4)
    pub fn signedMessage(self: *const SigBlob) [44]u8 {
        var msg: [44]u8 = undefined;
        @memcpy(msg[0..32], &self.elf_hash);
        std.mem.writeInt(u64, msg[32..40], self.entitlements_raw, .little);
        std.mem.writeInt(u32, msg[40..44], self.key_id, .little);
        return msg;
    }

    /// Parse a SigBlob from a raw byte slice. Returns error on invalid size,
    /// wrong magic, or non-zero reserved fields.
    pub fn parse(data: []const u8) error{ BadSize, BadMagic, BadFlags, BadPad }!SigBlob {
        if (data.len != size) return error.BadSize;

        var blob: SigBlob = undefined;
        @memcpy(std.mem.asBytes(&blob), data[0..size]);

        if (!std.mem.eql(u8, &blob.magic, &magic)) return error.BadMagic;
        if (blob.flags != 0) return error.BadFlags;
        for (blob._pad) |b| if (b != 0) return error.BadPad;

        return blob;
    }
};

test "sig_blob: size and layout" {
    try std.testing.expectEqual(@as(usize, 144), SigBlob.size);
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(SigBlob));
}

test "sig_blob: signed_message covers expected fields" {
    var blob: SigBlob = std.mem.zeroes(SigBlob);
    blob.elf_hash = [_]u8{0xAB} ** 32;
    blob.entitlements_raw = 0x0102030405060708;
    blob.key_id = 0xDEADBEEF;

    const msg = blob.signedMessage();
    try std.testing.expectEqualSlices(u8, &blob.elf_hash, msg[0..32]);
    try std.testing.expectEqual(blob.entitlements_raw, std.mem.readInt(u64, msg[32..40], .little));
    try std.testing.expectEqual(blob.key_id, std.mem.readInt(u32, msg[40..44], .little));
}

test "sig_blob: parse rejects wrong size" {
    const buf = [_]u8{0} ** 10;
    try std.testing.expectError(error.BadSize, SigBlob.parse(&buf));
}

test "sig_blob: parse rejects wrong magic" {
    var buf = [_]u8{0} ** SigBlob.size;
    try std.testing.expectError(error.BadMagic, SigBlob.parse(&buf));
}
