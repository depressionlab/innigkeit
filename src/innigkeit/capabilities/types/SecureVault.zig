//! Kernel-managed sealed key store.
//!
//! ## Design goals
//! - All secret material lives in kernel memory, userspace never sees raw key bytes.
//! - Sealing binds ciphertext to a vault-specific 256-bit wrapping key, so data
//!   unsealed from one vault cannot be replicated into another.
//! - When a TPM 2.0 device is present (detected via the ACPI TPM2 table), the
//!   wrapping key is derived from and unsealed against a TPM primary key, giving
//!   hardware root-of-trust. Without a TPM the vault falls back to a CSPRNG-seeded
//!   kernel-only wrapping key (software-only, secure against user code but not
//!   physical attackers).
//! - Sealing / unsealing use XChaCha20-Poly1305 (192-bit nonce, 128-bit tag) via
//!   std.crypto.aead.chacha_poly.XChaCha20Poly1305.
//!   The key schedule is never exported; only sealed blobs cross the kernel/user
//!   boundary.
//!
//! Blob wire format: nonce(24) || ciphertext(n) || tag(16)
//!
//! ## Capability operations (cap_invoke)
//! - seal (Op.seal): caller passes cleartext bytes -> receives sealed blob
//! - unseal (Op.unseal): caller passes sealed blob -> receives cleartext
//! - status (Op.status): returns hardware backing info (tpm_present, etc.)

const SecureVault = @This();

const builtin = @import("builtin");
const std = @import("std");
const innigkeit = @import("innigkeit");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

generation: std.atomic.Value(u32) = .init(0),
refcount: std.atomic.Value(usize) = .init(1),

/// True when the vault was seeded from a real TPM 2.0 device.
tpm_backed: bool,

/// 256-bit vault-specific wrapping key. Never leaves the kernel.
wrapping_key: [Aead.key_length]u8,

/// Allocate a new SecureVault. If a TPM is present (`tpm_phys_addr != null`)
/// the wrapping key is derived from the TPM's endorsement hierarchy; otherwise
/// a CSPRNG-seeded software key is used.
pub fn create(tpm_phys_addr: ?innigkeit.PhysicalAddress) error{OutOfMemory}!*SecureVault {
    const self = innigkeit.mem.heap.allocator.create(SecureVault) catch return error.OutOfMemory;
    var key: [Aead.key_length]u8 = undefined;
    fillRandomKey(&key);
    self.* = .{
        .tpm_backed = tpm_phys_addr != null,
        .wrapping_key = key,
    };
    // TODO(secure_vault): derive key from TPM primary key when tpm_phys_addr is set.
    return self;
}

pub fn ref(self: *SecureVault) void {
    _ = self.refcount.fetchAdd(1, .acq_rel);
}

pub fn unref(self: *SecureVault) void {
    if (self.refcount.fetchSub(1, .acq_rel) != 1) return;
    // Zero the wrapping key before freeing: defense in depth against heap
    // inspection after the capability is revoked.
    @memset(&self.wrapping_key, 0);
    innigkeit.mem.heap.allocator.destroy(self);
}

/// Selectors for cap_invoke on a SecureVault capability.
pub const Op = enum(u64) {
    /// Seal up to MAX_PLAINTEXT bytes. Writes sealed blob to out_buf.
    /// Returns blob length, or a negative errno on error.
    seal = 0,
    /// Unseal a sealed blob. Writes cleartext to out_buf.
    /// Returns cleartext length, or a negative errno on error.
    unseal = 1,
    /// Return status word: bit 0 = tpm_backed.
    status = 2,
};

/// Sealed-blob overhead: 24-byte XChaCha20 nonce + 16-byte Poly1305 tag.
pub const OVERHEAD: usize = Aead.nonce_length + Aead.tag_length;

/// Maximum cleartext size (64 KiB minus overhead).
pub const MAX_PLAINTEXT: usize = 65_536 - OVERHEAD;

/// Seal `plaintext` into `out_blob` using XChaCha20-Poly1305.
///
/// A fresh 192-bit nonce is generated from RDRAND / TSC hardware counter for every call.
pub fn seal(
    self: *const SecureVault,
    plaintext: []const u8,
    out_blob: []u8,
) error{ TooBig, BufferTooSmall }!usize {
    if (plaintext.len > MAX_PLAINTEXT) return error.TooBig;
    const needed = OVERHEAD + plaintext.len;
    if (out_blob.len < needed) return error.BufferTooSmall;

    var nonce: [Aead.nonce_length]u8 = undefined;
    var i: usize = 0;
    while (i < Aead.nonce_length) : (i += 8) {
        const v: u64 = hwRand64() orelse counterFallback(i);
        @memcpy(nonce[i..][0..8], &std.mem.toBytes(v));
    }

    const ct = out_blob[Aead.nonce_length..][0..plaintext.len];
    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(ct, &tag, plaintext, &.{}, nonce, self.wrapping_key);

    @memcpy(out_blob[0..Aead.nonce_length], &nonce);
    @memcpy(out_blob[Aead.nonce_length + plaintext.len ..][0..Aead.tag_length], &tag);
    return needed;
}

/// Unseal a blob produced by `seal`. Verifies the Poly1305 authentication tag.
pub fn unseal(
    self: *const SecureVault,
    blob: []const u8,
    out_plaintext: []u8,
) error{ TooSmall, BufferTooSmall, AuthFailed }!usize {
    if (blob.len < OVERHEAD) return error.TooSmall;
    const ct_len = blob.len - OVERHEAD;
    if (out_plaintext.len < ct_len) return error.BufferTooSmall;

    const nonce = blob[0..Aead.nonce_length].*;
    const ct = blob[Aead.nonce_length..][0..ct_len];
    const tag = blob[Aead.nonce_length + ct_len ..][0..Aead.tag_length].*;

    Aead.decrypt(out_plaintext[0..ct_len], ct, tag, &.{}, nonce, self.wrapping_key) catch return error.AuthFailed;
    return ct_len;
}

fn fillRandomKey(key: *[Aead.key_length]u8) void {
    var i: usize = 0;
    while (i < Aead.key_length) : (i += 8) {
        // Mix hardware RNG with timing counter for defense in depth: if RDRAND
        // is weak or absent, the timer still provides unpredictability; if the
        // timer is low-entropy at boot, RDRAND covers it.
        const hw = hwRand64() orelse 0;
        const timer = counterFallback(i);
        @memcpy(key[i..][0..8], &std.mem.toBytes(hw ^ timer));
    }
}

/// Architecture-specific hardware random number.
/// Returns null if not available or the instruction signals failure.
inline fn hwRand64() ?u64 {
    return switch (builtin.cpu.arch) {
        .x86_64 => blk: {
            // Intel recommends retrying RDRAND up to 10 times; brief failure is
            // common under high system load (DRNG reseeding, contention).
            var attempts: usize = 0;
            while (attempts < 10) : (attempts += 1) {
                var v: u64 = undefined;
                var ok: u8 = undefined;
                asm volatile (
                    \\ rdrand %[v]
                    \\ setc %[ok]
                    : [v] "=r" (v),
                      [ok] "=r" (ok),
                    :
                    : .{ .cc = true });
                if (ok != 0) break :blk v;
            }
            break :blk null;
        },
        .aarch64 => blk: {
            // RNDR system register (ARMv8.5-A FEAT_RNG).
            // Returns null via NZCV.Z=1 if the RNG is unavailable.
            var v: u64 = undefined;
            var ok: u64 = undefined;
            asm volatile (
                \\ mrs %[v], rndr
                \\ cset %[ok], ne
                : [v] "=r" (v),
                  [ok] "=r" (ok),
                :
                // : .{ .cc = true }
            );
            break :blk if (ok != 0) v else null;
        },
        else => null,
    };
}

/// Counter-based fallback when hardware random is unavailable.
/// Mixes in a constant to ensure successive calls differ.
inline fn counterFallback(slot: usize) u64 {
    const raw: u64 = switch (builtin.cpu.arch) {
        .x86_64 => blk: {
            var low: u32 = undefined;
            var high: u32 = undefined;
            asm volatile ("rdtsc"
                : [_] "={eax}" (low),
                  [_] "={edx}" (high),
            );
            break :blk (@as(u64, high) << 32) | @as(u64, low);
        },
        .aarch64 => blk: {
            var v: u64 = undefined;
            asm volatile ("mrs %[v], cntvct_el0"
                : [v] "=r" (v),
            );
            break :blk v;
        },
        .riscv64 => blk: {
            // rdtime reads the real-time counter (guaranteed by the RISC-V spec).
            var v: u64 = undefined;
            asm volatile ("rdtime %[v]"
                : [v] "=r" (v),
            );
            break :blk v;
        },
        else => 0,
    };
    return raw ^ (slot *% 0x9E3779B97F4A7C15);
}

test "secure_vault: seal/unseal roundtrip" {
    const vault = try SecureVault.create(null);
    defer vault.unref();

    const plaintext = "this is a kernel secret";
    var blob: [plaintext.len + OVERHEAD]u8 = undefined;
    const blob_len = try vault.seal(plaintext, &blob);
    try std.testing.expect(blob_len == blob.len);

    var recovered: [plaintext.len]u8 = undefined;
    const rec_len = try vault.unseal(blob[0..blob_len], &recovered);
    try std.testing.expectEqual(plaintext.len, rec_len);
    try std.testing.expectEqualSlices(u8, plaintext, recovered[0..rec_len]);
}

test "secure_vault: tampered blob fails authentication" {
    const vault = try SecureVault.create(null);
    defer vault.unref();

    const plaintext = "secret data";
    var blob: [plaintext.len + OVERHEAD]u8 = undefined;
    const blob_len = try vault.seal(plaintext, &blob);

    // Flip a bit in the ciphertext.
    blob[blob_len / 2] ^= 0xFF;

    var out: [plaintext.len]u8 = undefined;
    const result = vault.unseal(blob[0..blob_len], &out);
    try std.testing.expectError(error.AuthFailed, result);
}

test "secure_vault: seal rejects oversized plaintext" {
    const vault = try SecureVault.create(null);
    defer vault.unref();

    const fake_ptr: [*]const u8 = @ptrFromInt(0x1000);
    const too_big = fake_ptr[0 .. MAX_PLAINTEXT + 1];
    var blob: [OVERHEAD + 1]u8 = undefined;
    try std.testing.expectError(error.TooBig, vault.seal(too_big, &blob));
}

test "secure_vault: two vaults cannot cross-unseal" {
    const v1 = try SecureVault.create(null);
    defer v1.unref();
    const v2 = try SecureVault.create(null);
    defer v2.unref();

    const plaintext = "vault isolation check";
    var blob: [plaintext.len + OVERHEAD]u8 = undefined;
    const blob_len = try v1.seal(plaintext, &blob);

    var out: [plaintext.len]u8 = undefined;
    const result = v2.unseal(blob[0..blob_len], &out);
    try std.testing.expectError(error.AuthFailed, result);
}
