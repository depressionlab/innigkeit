//! Passphrase-derived recovery keyslot.
//!
//! A LUKS2 / FileVault-style escape hatch: wrap the AES-XTS volume key under a
//! key derived from a passphrase with Argon2id (memory-hard) and seal it with
//! XChaCha20-Poly1305. Deliberately *TPM-independent* so a legitimate TPM clear
//! or firmware update does not destroy data so the accepted tradeoff is that a
//! strong passphrase can recover a stolen disk (standard recovery semantics).
//!
//! Argon2id (and its large scratch allocation) plus the AEAD want an allocator
//! and an `Io`, so this runs in a userspace / offline recovery tool or a host
//! build and never the early-boot kernel path. The slot bytes are stored opaquely
//! in the volume header; only the recovery tool derives from the passphrase.
//!
//! Slot wire format (fixed `slot_length` bytes, little-endian):
//!   salt[16] || t_cost(u32) || m_cost_kib(u32) || lanes(u32) ||
//!   nonce[24] || ciphertext[64] || tag[16]
//! The 28-byte prefix (salt || params) is the AEAD associated data, so tampering
//! with the KDF parameters or salt fails authentication.

const std = @import("std");
const argon2 = std.crypto.pwhash.argon2;
const KdfError = std.crypto.pwhash.KdfError;
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

/// AES-XTS-256 volume key length (32-byte data key + 32-byte tweak key).
pub const key_length = 64;
pub const salt_length = 16;

const params_offset = salt_length; // 16
const nonce_offset = params_offset + 12; // 28 (after 3×u32 params)
const ct_offset = nonce_offset + Aead.nonce_length; // 52
const tag_offset = ct_offset + key_length; // 116
/// Associated data = salt || params (everything before the nonce).
const ad_length = nonce_offset; // 28

pub const slot_length = tag_offset + Aead.tag_length; // 132

pub const Slot = [slot_length]u8;

/// Argon2id cost parameters. Defaults follow the OWASP recommendation for
/// interactive login (64 MiB, 3 iterations); a recovery tool may raise them.
pub const Params = struct {
    t_cost: u32 = 3,
    m_cost_kib: u32 = 64 * 1024, // 64 MiB
    lanes: u32 = 1,
};

pub const UnwrapError = error{WrongPassphrase} || KdfError;

fn deriveWrappingKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *[Aead.key_length]u8,
    passphrase: []const u8,
    salt: []const u8,
    params: Params,
) KdfError!void {
    try argon2.kdf(
        allocator,
        out,
        passphrase,
        salt,
        .{ .t = params.t_cost, .m = params.m_cost_kib, .p = @intCast(params.lanes) },
        .argon2id,
        io,
    );
}

/// Wrap `volume_key` under `passphrase`, returning the serialized slot. `salt`
/// and `nonce` must be fresh random values supplied by the caller (kept as
/// parameters so this stays entropy-source agnostic and deterministically
/// testable).
pub fn wrap(
    allocator: std.mem.Allocator,
    io: std.Io,
    volume_key: [key_length]u8,
    passphrase: []const u8,
    salt: [salt_length]u8,
    nonce: [Aead.nonce_length]u8,
    params: Params,
) KdfError!Slot {
    var wk: [Aead.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &wk);
    try deriveWrappingKey(allocator, io, &wk, passphrase, &salt, params);

    var slot: Slot = undefined;
    @memcpy(slot[0..salt_length], &salt);
    std.mem.writeInt(u32, slot[params_offset..][0..4], params.t_cost, .little);
    std.mem.writeInt(u32, slot[params_offset + 4 ..][0..4], params.m_cost_kib, .little);
    std.mem.writeInt(u32, slot[params_offset + 8 ..][0..4], params.lanes, .little);
    @memcpy(slot[nonce_offset..][0..Aead.nonce_length], &nonce);

    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(slot[ct_offset..][0..key_length], &tag, &volume_key, slot[0..ad_length], nonce, wk);
    @memcpy(slot[tag_offset..][0..Aead.tag_length], &tag);
    return slot;
}

/// Recover the volume key from `slot` using `passphrase`. Returns
/// `error.WrongPassphrase` when the passphrase is wrong or the slot is corrupt
/// (the AEAD tag, over ciphertext + salt/params, fails to verify).
pub fn unwrap(
    allocator: std.mem.Allocator,
    io: std.Io,
    slot: Slot,
    passphrase: []const u8,
) UnwrapError![key_length]u8 {
    const params: Params = .{
        .t_cost = std.mem.readInt(u32, slot[params_offset..][0..4], .little),
        .m_cost_kib = std.mem.readInt(u32, slot[params_offset + 4 ..][0..4], .little),
        .lanes = std.mem.readInt(u32, slot[params_offset + 8 ..][0..4], .little),
    };
    var wk: [Aead.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &wk);
    try deriveWrappingKey(allocator, io, &wk, passphrase, slot[0..salt_length], params);

    var nonce: [Aead.nonce_length]u8 = undefined;
    @memcpy(&nonce, slot[nonce_offset..][0..Aead.nonce_length]);
    var tag: [Aead.tag_length]u8 = undefined;
    @memcpy(&tag, slot[tag_offset..][0..Aead.tag_length]);

    var volume_key: [key_length]u8 = undefined;
    Aead.decrypt(
        &volume_key,
        slot[ct_offset..][0..key_length],
        tag,
        slot[0..ad_length],
        nonce,
        wk,
    ) catch return error.WrongPassphrase;
    return volume_key;
}

// Cheap Argon2id params for tests (memory-hard KDF at real cost would make the
// host suite slow); the wire format and AEAD path are identical.
const test_params: Params = .{ .t_cost = 1, .m_cost_kib = 8, .lanes = 1 };

test "passphrase keyslot: wrap/unwrap round-trips" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const key = [_]u8{0xA7} ** key_length;
    const salt = [_]u8{0x11} ** salt_length;
    const nonce = [_]u8{0x22} ** Aead.nonce_length;

    const slot = try wrap(alloc, io, key, "correct horse battery staple", salt, nonce, test_params);
    const got = try unwrap(alloc, io, slot, "correct horse battery staple");
    try std.testing.expectEqualSlices(u8, &key, &got);
}

test "passphrase keyslot: wrong passphrase is rejected" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const key = [_]u8{0x5C} ** key_length;
    const salt = [_]u8{0x33} ** salt_length;
    const nonce = [_]u8{0x44} ** Aead.nonce_length;

    const slot = try wrap(alloc, io, key, "the-right-one", salt, nonce, test_params);
    try std.testing.expectError(error.WrongPassphrase, unwrap(alloc, io, slot, "the-wrong-one"));
}

test "passphrase keyslot: tampering the params/salt (AD) fails auth" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const key = [_]u8{0x1F} ** key_length;
    const salt = [_]u8{0x55} ** salt_length;
    const nonce = [_]u8{0x66} ** Aead.nonce_length;

    var slot = try wrap(alloc, io, key, "passphrase", salt, nonce, test_params);
    slot[0] ^= 0xFF; // flip a salt byte (part of the AEAD associated data)
    try std.testing.expectError(error.WrongPassphrase, unwrap(alloc, io, slot, "passphrase"));
}
