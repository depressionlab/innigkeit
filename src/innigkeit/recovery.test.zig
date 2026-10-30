//! End-to-end at-rest recovery flow: the multi-keyslot volume header
//! carrying a TPM slot AND an Argon2id passphrase slot lets a holder of the
//! passphrase recover the exact AES-XTS volume key with no TPM.

const PassphraseKeyslot = @import("crypto/PassphraseKeyslot.zig");
const std = @import("std");
const VolumeHeader = @import("filesystem/VolumeHeader.zig");

test "recovery: passphrase slot in the volume header round-trips the key" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const key = @as([PassphraseKeyslot.key_length]u8, @splat(0x9E));

    // Wrap the volume key under a passphrase; lay it into the header next to an
    // (opaque) TPM slot, exactly as a recovery tool would augment a disk that
    // the kernel provisioned with only a TPM slot.
    const salt = @as([PassphraseKeyslot.salt_length]u8, @splat(0x01));
    const nonce = @as([24]u8, @splat(0x02));
    const params: PassphraseKeyslot.Params = .{ .t_cost = 1, .m_cost_kib = 8, .lanes = 1 };
    const slot = try PassphraseKeyslot.wrap(alloc, io, key, "recover me", salt, nonce, params);

    var sector: [512]u8 = undefined;
    try VolumeHeader.write(&sector, &.{
        .{ .type = .tpm_pcr, .bytes = &@as([48]u8, @splat(0xAA)) },
        .{ .type = .passphrase, .bytes = &slot },
    });

    // Fresh parse (cold, as recovery would), find the passphrase slot, unwrap.
    const h = try VolumeHeader.parse(&sector);
    const found = h.find(.passphrase).?;
    try std.testing.expectEqual(@as(usize, PassphraseKeyslot.slot_length), found.len);
    const recovered = try PassphraseKeyslot.unwrap(alloc, io, found[0..PassphraseKeyslot.slot_length].*, "recover me");
    try std.testing.expectEqualSlices(u8, &key, &recovered);

    // Wrong passphrase must fail, and the TPM slot is preserved untouched.
    try std.testing.expectError(
        error.WrongPassphrase,
        PassphraseKeyslot.unwrap(alloc, io, found[0..PassphraseKeyslot.slot_length].*, "wrong"),
    );
    try std.testing.expect(std.mem.eql(u8, &@as([48]u8, @splat(0xAA)), h.find(.tpm_pcr).?));
}
