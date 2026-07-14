//! KDFa TPM 2.0 key-derivation function.
//!
//! TPM 2.0 Part 1 §11.4.9.1: an SP800-108 counter-mode KDF built on HMAC. Used
//! to derive the session key, the per-command HMAC keys, and the CFB
//! parameter-encryption key/IV of an authorization session.
//!
//! ```
//!   KDFa(hashAlg, key, label, contextU, contextV, bits):
//!     for i = 1, 2, ...: HMAC(key, i_be32 || label || 0x00 || contextU || contextV || bits_be32)
//! ```
//! concatenated, truncated to `bits`, high bits of the first byte masked off
//! when `bits` is not a multiple of 8.

const std = @import("std");
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const digest_len = Hmac.mac_length;

/// Maximum derived-key length this helper supports (covers session keys, HMAC
/// keys and CFB key+IV, we can expect all <= 64 bytes).
pub const max_out = 96;

/// Derive `out.len` bytes with KDFa over SHA-256. `label` must NOT include its
/// trailing NUL, as this adds the single 0x00 delimiter the spec requires. The
/// requested bit count encoded into each block is `out.len * 8`.
pub fn kdfa(
    key: []const u8,
    label: []const u8,
    context_u: []const u8,
    context_v: []const u8,
    out: []u8,
) void {
    std.debug.assert(out.len <= max_out);
    const bits: u32 = @intCast(out.len * 8);

    var counter: u32 = 0;
    var produced: usize = 0;
    while (produced < out.len) {
        counter += 1;

        var hmac = Hmac.init(key);
        var be: [4]u8 = undefined;
        std.mem.writeInt(u32, &be, counter, .big);
        hmac.update(&be);
        hmac.update(label);
        hmac.update(&[_]u8{0}); // label/context delimiter
        hmac.update(context_u);
        hmac.update(context_v);
        std.mem.writeInt(u32, &be, bits, .big);
        hmac.update(&be);

        var block: [digest_len]u8 = undefined;
        hmac.final(&block);

        const take = @min(digest_len, out.len - produced);
        @memcpy(out[produced..][0..take], block[0..take]);
        produced += take;
    }

    // Mask the unused high bits of the first byte when bits % 8 != 0. (bits is a
    // multiple of 8 here since out is byte-sized, so this is a no-op kept for
    // spec fidelity if sub-byte lengths are ever requested.)
    const rem: u3 = @intCast(bits % 8);
    if (rem != 0) out[0] &= (@as(u8, 1) << rem) - 1;
}

/// KDFe TPM 2.0 ECDH key-derivation function (Part 1 §11.4.9.3, an SP800-56A
/// concatenation KDF over a plain hash, NOT HMAC). Derives the session
/// salt from an ECDH shared secret `z`:
/// ```
///   for counter i = 1, 2, ...:
///      SHA256(i_be32 ‖ z ‖ label ‖ 0x00 ‖ party_u ‖ party_v)
/// ```
/// `label` must NOT include its trailing NUL. `party_u`/`party_v` are the X
/// coordinates of the ephemeral and TPM public points.
pub fn kdfe(
    z: []const u8,
    label: []const u8,
    party_u: []const u8,
    party_v: []const u8,
    out: []u8,
) void {
    std.debug.assert(out.len <= max_out);
    var counter: u32 = 0;
    var produced: usize = 0;
    while (produced < out.len) {
        counter += 1;
        var h = Sha256.init(.{});
        var be: [4]u8 = undefined;
        std.mem.writeInt(u32, &be, counter, .big);
        h.update(&be);
        h.update(z);
        h.update(label);
        h.update(&[_]u8{0});
        h.update(party_u);
        h.update(party_v);
        var block: [digest_len]u8 = undefined;
        h.final(&block);
        const take = @min(digest_len, out.len - produced);
        @memcpy(out[produced..][0..take], block[0..take]);
        produced += take;
    }
}

test "kdfa: single-block output matches a direct HMAC" {
    // With out.len <= 32 the result is exactly the first block, so we can check
    // it against an independent HMAC computation of the same preimage.
    const key = "session-key-material";
    const label = "ATH";
    const ctx_u = [_]u8{ 0xDE, 0xAD };
    const ctx_v = [_]u8{ 0xBE, 0xEF };

    var out: [32]u8 = undefined;
    kdfa(key, label, &ctx_u, &ctx_v, &out);

    var hmac = Hmac.init(key);
    hmac.update(&[_]u8{ 0, 0, 0, 1 }); // counter = 1, be32
    hmac.update(label);
    hmac.update(&[_]u8{0});
    hmac.update(&ctx_u);
    hmac.update(&ctx_v);
    hmac.update(&[_]u8{ 0, 0, 1, 0 }); // bits = 256, be32
    var expect: [32]u8 = undefined;
    hmac.final(&expect);

    try std.testing.expectEqualSlices(u8, &expect, &out);
}

test "kdfa: multi-block output chains counters 1..N" {
    const key = "k";
    var out: [40]u8 = undefined; // > 32 -> two blocks
    kdfa(key, "CFB", "", "", &out);

    // First 32 bytes = block(counter=1); next 8 = prefix of block(counter=2).
    var b1 = Hmac.init(key);
    b1.update(&[_]u8{ 0, 0, 0, 1 });
    b1.update("CFB");
    b1.update(&[_]u8{0});
    b1.update(&[_]u8{ 0, 0, 1, 40 * 8 - 256 }); // bits = 320 = 0x0140
    var d1: [32]u8 = undefined;
    b1.final(&d1);
    try std.testing.expectEqualSlices(u8, &d1, out[0..32]);

    var b2 = Hmac.init(key);
    b2.update(&[_]u8{ 0, 0, 0, 2 });
    b2.update("CFB");
    b2.update(&[_]u8{0});
    b2.update(&[_]u8{ 0, 0, 1, 40 * 8 - 256 });
    var d2: [32]u8 = undefined;
    b2.final(&d2);
    try std.testing.expectEqualSlices(u8, d2[0..8], out[32..40]);
}

test "kdfa: distinct labels/contexts give distinct keys" {
    const key = "same-key";
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    var c: [32]u8 = undefined;
    kdfa(key, "ATH", "", "", &a);
    kdfa(key, "CFB", "", "", &b); // different label
    kdfa(key, "ATH", "x", "", &c); // different context
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "kdfe: single-block output matches a direct SHA-256" {
    const z = [_]u8{0x11} ** 32;
    const pu = [_]u8{0x22} ** 32;
    const pv = [_]u8{0x33} ** 32;

    var out: [32]u8 = undefined;
    kdfe(&z, "SECRET", &pu, &pv, &out);

    var h = Sha256.init(.{});
    h.update(&[_]u8{ 0, 0, 0, 1 });
    h.update(&z);
    h.update("SECRET");
    h.update(&[_]u8{0});
    h.update(&pu);
    h.update(&pv);
    var expect: [32]u8 = undefined;
    h.final(&expect);

    try std.testing.expectEqualSlices(u8, &expect, &out);
}

test "kdfe: is distinct from kdfa for the same inputs" {
    const key = [_]u8{0xAB} ** 32;
    var e: [32]u8 = undefined;
    var a: [32]u8 = undefined;
    kdfe(&key, "SECRET", "", "", &e);
    kdfa(&key, "SECRET", "", "", &a);
    try std.testing.expect(!std.mem.eql(u8, &e, &a)); // hash vs HMAC construction
}
