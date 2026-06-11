//! ELF signature verification: Blake3 + Ed25519.
//!
//! Called from the spawn handler before loading an ELF into a new process.
//! Returns the verified `Entitlements` on success, or an error code.

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
const Ed25519 = std.crypto.sign.Ed25519;
const SigBlob = @import("SigBlob.zig").SigBlob;
const Manifest = @import("Manifest.zig");
const keys = @import("keys.zig");

pub const VerifyError = error{
    /// No .codesig sidecar was found in initfs.
    NoSignature,
    /// The blob has wrong size, bad magic, or non-zero reserved fields.
    MalformedBlob,
    /// The Blake3 hash of the ELF does not match the hash in the blob.
    HashMismatch,
    /// No public key exists for the blob's key_id.
    UnknownKey,
    /// Ed25519 signature verification failed.
    SignatureMismatch,
};

/// Verify `sig_data` against `elf_data` and return the entitlements on success.
pub fn verify(elf_data: []const u8, sig_data: []const u8) VerifyError!Manifest.Entitlements {
    // 1. Parse the blob.
    const blob = SigBlob.parse(sig_data) catch return error.MalformedBlob;

    // 2. Blake3 the ELF and compare with the stored hash.
    var digest: [Blake3.digest_length]u8 = undefined;
    Blake3.hash(elf_data, &digest, .{});
    if (!std.crypto.timing_safe.eql([32]u8, digest, blob.elf_hash)) return error.HashMismatch;

    // 3. Resolve the public key.
    const pub_key_bytes = keys.getPublicKey(blob.key_id) orelse return error.UnknownKey;

    // 4. Verify Ed25519 signature over (elf_hash || entitlements_le || key_id_le).
    const msg = blob.signedMessage();
    const pub_key = Ed25519.PublicKey.fromBytes(pub_key_bytes) catch return error.UnknownKey;
    const sig = Ed25519.Signature.fromBytes(blob.signature);
    sig.verify(&msg, pub_key) catch return error.SignatureMismatch;

    return blob.entitlements();
}

test "verify: tampered signature is rejected" {
    // Use distinct bytes so the hash is non-trivial (not the hash of all-zero data).
    const elf = [_]u8{0xAB} ** 64;

    // Build a blob with the correct ELF hash but an all-zero (invalid) signature.
    var blob: SigBlob = std.mem.zeroes(SigBlob);
    @memcpy(&blob.magic, &@import("SigBlob.zig").magic);
    blob.entitlements_raw = @bitCast(Manifest.Entitlements{});
    blob.key_id = 0;
    Blake3.hash(&elf, &blob.elf_hash, .{});
    // blob.signature stays all-zero: cryptographically invalid.

    var sig_bytes: [SigBlob.size]u8 = undefined;
    @memcpy(&sig_bytes, std.mem.asBytes(&blob));

    // Hash passes, public key resolves; the zeroed signature must be rejected.
    try std.testing.expectError(error.SignatureMismatch, verify(&elf, &sig_bytes));
}

test "verify: tampered ELF is rejected" {
    // Build a minimal valid blob for a known ELF (all-zero 64 bytes).
    const elf = [_]u8{0} ** 64;

    // We can't sign without a private key in tests; instead verify that a
    // zeroed blob (wrong hash, wrong signature) returns HashMismatch.
    var blob: SigBlob = std.mem.zeroes(SigBlob);
    @memcpy(&blob.magic, &@import("SigBlob.zig").magic);
    blob.entitlements_raw = @bitCast(Manifest.Entitlements{});
    blob.key_id = 0;

    var sig_bytes: [SigBlob.size]u8 = undefined;
    @memcpy(&sig_bytes, std.mem.asBytes(&blob));

    const result = verify(&elf, &sig_bytes);
    // Hash is all-zero but real hash of 64-zero bytes is non-zero: mismatch.
    try std.testing.expectError(error.HashMismatch, result);
}
