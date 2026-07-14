//! Transparent AES-XTS block-device layer.
//!
//! Wraps a backing block device and encrypts/decrypts every sector with
//! `crypto/xts.zig`, keyed by an unsealed volume key, using the sector's LBA as
//! the XTS tweak. Plaintext never touches the backing store; ciphertext is
//! length-preserving so sector addressing is unchanged.
//!
//! Generic over the backing store so the encryption logic is exercised on the
//! host (`zig build test_native`) against a RAM disk; the kernel instantiates it
//! with a virtio-blk backing. The `comptime Backing` type must provide:
//!   - `pub fn readSectors(self, lba: u64, buf: []u8, count: u32) !void`
//!   - `pub fn writeSectors(self, lba: u64, buf: []const u8, count: u32) !void`

const std = @import("std");
const xts = @import("xts.zig");

/// Standard 512-byte sector. XTS needs a 16-byte multiple; 512 qualifies.
pub const sector_size = 512;

/// AES-XTS-256 encrypted block device over `Backing`. The key is 64 bytes
/// (32-byte data key || 32-byte tweak key).
pub fn EncryptedBlockDevice(comptime Backing: type) type {
    const Cipher = xts.Xts(std.crypto.core.aes.Aes256);
    return struct {
        const Self = @This();

        pub const key_length = Cipher.key_length;

        backing: Backing,
        cipher: Cipher,

        pub fn init(backing: Backing, key: [key_length]u8) Self {
            return .{ .backing = backing, .cipher = Cipher.init(key) };
        }

        /// Read `count` sectors at `lba` and decrypt them in place.
        pub fn readSectors(self: *Self, lba: u64, buf: []u8, count: u32) !void {
            std.debug.assert(buf.len >= @as(usize, count) * sector_size);
            try self.backing.readSectors(lba, buf, count);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const sector = buf[@as(usize, i) * sector_size ..][0..sector_size];
                self.cipher.decryptSector(sector, lba + i);
            }
        }

        /// Encrypt `count` plaintext sectors and write them at `lba`. The
        /// caller's buffer is not modified; ciphertext is staged one sector at a
        /// time so no large scratch allocation is needed.
        pub fn writeSectors(self: *Self, lba: u64, plaintext: []const u8, count: u32) !void {
            std.debug.assert(plaintext.len >= @as(usize, count) * sector_size);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                var ciphertext: [sector_size]u8 = undefined;
                @memcpy(&ciphertext, plaintext[@as(usize, i) * sector_size ..][0..sector_size]);
                self.cipher.encryptSector(&ciphertext, lba + i);
                try self.backing.writeSectors(lba + i, &ciphertext, 1);
            }
        }
    };
}

const TestDisk = struct {
    sectors: [16][sector_size]u8 = std.mem.zeroes([16][sector_size]u8),

    fn readSectors(self: *TestDisk, lba: u64, buf: []u8, count: u32) !void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            @memcpy(buf[@as(usize, i) * sector_size ..][0..sector_size], &self.sectors[@intCast(lba + i)]);
        }
    }
    fn writeSectors(self: *TestDisk, lba: u64, buf: []const u8, count: u32) !void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            @memcpy(&self.sectors[@intCast(lba + i)], buf[@as(usize, i) * sector_size ..][0..sector_size]);
        }
    }
};

test "encrypted block device: multi-sector write/read round-trips" {
    var disk = TestDisk{};
    var dev = EncryptedBlockDevice(*TestDisk).init(&disk, [_]u8{0x42} ** 64);

    var plain: [3 * sector_size]u8 = undefined;
    for (&plain, 0..) |*b, i| b.* = @truncate(i *% 3 +% 7);

    try dev.writeSectors(5, &plain, 3);

    var read_back: [3 * sector_size]u8 = undefined;
    try dev.readSectors(5, &read_back, 3);
    try std.testing.expect(std.mem.eql(u8, &plain, &read_back));
}

test "encrypted block device: backing store holds ciphertext, not plaintext" {
    var disk = TestDisk{};
    var dev = EncryptedBlockDevice(*TestDisk).init(&disk, [_]u8{0x42} ** 64);

    const plain = [_]u8{0xAB} ** sector_size;
    try dev.writeSectors(2, &plain, 1);

    // The raw sector on the backing device must not be the plaintext.
    try std.testing.expect(!std.mem.eql(u8, &plain, &disk.sectors[2]));
}

test "encrypted block device: identical plaintext differs per sector (LBA tweak)" {
    var disk = TestDisk{};
    var dev = EncryptedBlockDevice(*TestDisk).init(&disk, [_]u8{0x42} ** 64);

    const plain = [_]u8{0} ** (2 * sector_size); // same content in both sectors
    try dev.writeSectors(8, &plain, 2);

    // Sector 8 and sector 9 hold the same plaintext but must differ on disk.
    try std.testing.expect(!std.mem.eql(u8, &disk.sectors[8], &disk.sectors[9]));
}
