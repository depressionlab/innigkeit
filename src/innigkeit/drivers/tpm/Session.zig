//! Salted HMAC-authenticated TPM session state and cryptography.

const std = @import("std");
const kdf = @import("kdf.zig");

const P256 = std.crypto.ecc.P256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Aes128 = std.crypto.core.aes.Aes128;

pub const digest_len = 32; // SHA-256
pub const cfb_key_len = 16; // AES-128
pub const cfb_iv_len = 16; // one AES block

/// A P-256 point in TPM2's raw big-endian coordinate encoding.
pub const EccPoint = struct {
    x: [digest_len]u8,
    y: [digest_len]u8,
};

/// `TPMA_SESSION` attribute bits (TPM 2.0 Part 2).
pub const attr_continue_session: u8 = 0x01;
pub const attr_decrypt: u8 = 0x20;
pub const attr_encrypt: u8 = 0x40;

pub const Error = error{EcdhFailed};

/// The host's ephemeral public point returned by `deriveSalt`.
///
/// It's sent as `encryptedSalt` which is safe to expose. `salt` can
/// only be derived by the TPM that holds the matching private key.
pub const Salted = struct {
    ephemeral_public: EccPoint,
    salt: [digest_len]u8,
};

/// Perform ECDH against the TPM's public point `qs` using an ephemeral P-256
/// keypair derived from `scalar_seed`, deriving the session salt via `KDFe`
/// per TPM 2.0's ECC secret-sharing scheme:
/// `salt = KDFe(Z.x, "SECRET", Qe.x, Qs.x, 256)`.
pub fn deriveSalt(qs: EccPoint, scalar_seed: [64]u8) Error!Salted {
    const qs_point = pointFromCoordinates(qs) catch return Error.EcdhFailed;
    const de = P256.scalar.reduce64(scalar_seed, .big);

    const qe_point = P256.basePoint.mul(de, .big) catch return Error.EcdhFailed;
    const z_point = qs_point.mul(de, .big) catch return Error.EcdhFailed;

    const qe_affine = qe_point.affineCoordinates();
    const z_affine = z_point.affineCoordinates();
    const qe: EccPoint = .{ .x = qe_affine.x.toBytes(.big), .y = qe_affine.y.toBytes(.big) };
    const z_x = z_affine.x.toBytes(.big);

    var salt: [digest_len]u8 = undefined;
    kdf.kdfe(&z_x, "SECRET", &qe.x, &qs.x, &salt);
    return .{ .ephemeral_public = qe, .salt = salt };
}

fn pointFromCoordinates(p: EccPoint) !P256 {
    const x = try P256.Fe.fromBytes(p.x, .big);
    const y = try P256.Fe.fromBytes(p.y, .big);
    return P256.fromAffineCoordinates(.{ .x = x, .y = y });
}

/// Marshal `point` as a `TPMS_ECC_POINT`.
///
/// `TPMS_ECC_POINT` is only the *content* of `TPM2_StartAuthSession`'s
/// `TPM2B_ENCRYPTED_SECRET encryptedSalt` field for an ECC `tpmKey`
/// (the point itself is what's encrypted: ECDH needs no separate
/// cipher, the shared secret that only the TPM can provide is the
/// protection).
///
/// This is the TPM2B's *payload* only. Since the caller wraps the payload
/// in `encryptedSalt`'s own outer `size` field, wrapping it again would
/// double the TPM2B nesting anad the TPM would reject it (`TPM2_RC_VALUE`).
pub const encrypted_salt_len = 2 + digest_len + 2 + digest_len; // x TPM2B || y TPM2B
pub fn marshalEncryptedSalt(buf: *[encrypted_salt_len]u8, point: EccPoint) []const u8 {
    std.mem.writeInt(u16, buf[0..2], digest_len, .big);
    @memcpy(buf[2..][0..digest_len], &point.x);
    std.mem.writeInt(u16, buf[2 + digest_len ..][0..2], digest_len, .big);
    @memcpy(buf[2 + digest_len + 2 ..][0..digest_len], &point.y);
    return buf[0..encrypted_salt_len];
}

/// Derives the TPM 2.0 Part 1 §19.6.4 session key.
///
/// `sessionKey = KDFa(salt, "ATH", nonceTPM, nonceCaller, 256)`
///
/// Computed once after `TPM2_StartAuthSession`'s response. Unlike per-command
/// nonces it does not change for the auth session's lifetime.
pub fn deriveSessionKey(salt: [digest_len]u8, nonce_tpm: [digest_len]u8, nonce_caller: [digest_len]u8) [digest_len]u8 {
    var key: [digest_len]u8 = undefined;
    kdf.kdfa(&salt, "ATH", &nonce_tpm, &nonce_caller, &key);
    return key;
}

/// A salted authorization session's rolling state.
///
/// The session object handles one request/response round trip at a time:
/// a command consumes the current `nonce_caller`/`nonce_tpm` pair, and
/// a successful response's HMAC check rolls `nonce_tpm` forward to what
/// the TPM just generated. Never share one `Session` across concurrent
/// in-flight commands.
pub const Session = struct {
    handle: u32,
    key: [digest_len]u8,
    nonce_caller: [digest_len]u8,
    nonce_tpm: [digest_len]u8,

    /// Adopt a fresh `nonceCaller` for the next command.
    ///
    /// Note that the caller supplies the randomness.
    pub fn rollNonceCaller(self: *Session, fresh: [digest_len]u8) void {
        self.nonce_caller = fresh;
    }

    /// Run `authHMAC` for a command using this session per TPM 2.0 Part 1 §19.6.3.
    ///
    /// `HMAC(sessionKey, cpHash || nonceNewer=nonceCaller || nonceOlder=nonceTPM || sessionAttributes)`.
    ///
    /// Call `Session.rollNonceCaller` first if this is not the very first command on
    /// a freshly-started session to refresh hardware randomness.
    pub fn commandHmac(self: *const Session, cp_hash: [digest_len]u8, attrs: u8) [digest_len]u8 {
        var mac = HmacSha256.init(&self.key);
        mac.update(&cp_hash);
        mac.update(&self.nonce_caller);
        mac.update(&self.nonce_tpm);
        mac.update(&.{attrs});
        var out: [digest_len]u8 = undefined;
        mac.final(&out);
        return out;
    }

    /// Verify a response's `authHMAC`.
    ///
    /// This serves as proof that the TPM which answered actually has ownership
    /// of `key` (and transitively, that the salted exchange succeeded against
    /// the real TPM) and that no interposer altered the response in transit.
    ///
    /// `rpHash`/`resp_attrs`/`got_hmac` come from the just-received response;
    /// `new_nonce_tpm` is the fresh nonce the TPM included in it.
    ///
    /// On success, rolls `nonce_tpm` forward to `new_nonce_tpm` (needed prior
    /// to `responseParamMask`, since that decrypts using the *new* nonce).
    pub fn verifyResponseHmac(
        self: *Session,
        rp_hash: [digest_len]u8,
        resp_attrs: u8,
        new_nonce_tpm: [digest_len]u8,
        got_hmac: []const u8,
    ) error{AuthFailed}!void {
        var mac = HmacSha256.init(&self.key);
        mac.update(&rp_hash);
        mac.update(&new_nonce_tpm);
        mac.update(&self.nonce_caller);
        mac.update(&.{resp_attrs});
        var want: [digest_len]u8 = undefined;
        mac.final(&want);
        if (got_hmac.len != digest_len or !std.mem.eql(u8, &want, got_hmac)) {
            return error.AuthFailed;
        }
        self.nonce_tpm = new_nonce_tpm;
    }

    /// Encrypt a command's `decrypt` attributed first parameter in place
    /// with AES-128-CFB (TPM 2.0 Part 1 §21.7).
    ///
    /// The session's `symmetric` must be `TPM_ALG_AES`/128/`TPM_ALG_CFB`
    /// for this to mean anything to the TPM. `TPM_ALG_NULL` means the
    /// session supports no parameter encryption at all. Call after
    /// `Session.rollNonceCaller` (same nonce this command's HMAC uses).
    pub fn encryptCommandParam(self: *const Session, data: []u8) void {
        const key_iv = deriveCfbKeyIv(self.key, self.nonce_caller, self.nonce_tpm);
        cfbCrypt(key_iv.key, key_iv.iv, data, .encrypt);
    }

    /// Decrypt a response's `encrypt` aqttributed first parameter in place.
    ///
    /// Call after `Session.verifyResponseHmac` has rolled `nonce_tpm` to the
    /// response's new value (the key/IV derivation uses it as "nonceNewer").
    pub fn decryptResponseParam(self: *const Session, data: []u8) void {
        const key_iv = deriveCfbKeyIv(self.key, self.nonce_tpm, self.nonce_caller);
        cfbCrypt(key_iv.key, key_iv.iv, data, .decrypt);
    }
};

const CfbKeyIv = struct { key: [cfb_key_len]u8, iv: [cfb_iv_len]u8 };

/// `KDFa(sessionKey, "CFB", nonceNewer, nonceOlder, (keyBits + blockBits))`
///
///
/// The key is split into the AES key (first `cfb_key_len` bytes) and IV
/// (remaining `cfb_iv_len` bytes).
///
/// We use TPM 2.0 Part 1 §21.7's one-KDFa-call construction for a CFB-mode
/// parameter-encryption session.
fn deriveCfbKeyIv(session_key: [digest_len]u8, nonce_newer: [digest_len]u8, nonce_older: [digest_len]u8) CfbKeyIv {
    var buf: [cfb_key_len + cfb_iv_len]u8 = undefined;
    kdf.kdfa(&session_key, "CFB", &nonce_newer, &nonce_older, &buf);
    return .{ .key = buf[0..cfb_key_len].*, .iv = buf[cfb_key_len..][0..cfb_iv_len].* };
}

/// Run AES-128-CFB(128) in place.
///
/// We use NIST SP800-38A's segmented, ciphertext-feedback CFB, keystream
/// generated one AES block at a time and XORed in, the final partial block
/// using only as many keystream bytes as it needs.
///
/// Encryption  and decryption differ only in which buffer (plaintext or
/// ciphertext) becomes the next block's feedback register.
fn cfbCrypt(key: [cfb_key_len]u8, iv: [cfb_iv_len]u8, data: []u8, comptime direction: enum { encrypt, decrypt }) void {
    const ctx = Aes128.initEnc(key);
    var feedback = iv;
    var off: usize = 0;
    while (off < data.len) {
        var keystream: [16]u8 = undefined;
        ctx.encrypt(&keystream, &feedback);
        const n = @min(16, data.len - off);
        const chunk = data[off..][0..n];
        switch (direction) {
            .encrypt => {
                for (chunk, 0..) |*b, i| b.* ^= keystream[i];
                @memcpy(feedback[0..n], chunk);
            },
            .decrypt => {
                @memcpy(feedback[0..n], chunk);
                for (chunk, 0..) |*b, i| b.* ^= keystream[i];
            },
        }
        off += n;
    }
}

test "deriveSalt: same TPM point + independent ephemeral seeds yield independent salts" {
    const base = P256.basePoint.affineCoordinates();
    const qs: EccPoint = .{ .x = base.x.toBytes(.big), .y = base.y.toBytes(.big) };

    const a = try deriveSalt(qs, [_]u8{0x11} ** 64);
    const b = try deriveSalt(qs, [_]u8{0x22} ** 64);
    try std.testing.expect(!std.mem.eql(u8, &a.salt, &b.salt));
    try std.testing.expect(!std.mem.eql(u8, &a.ephemeral_public.x, &b.ephemeral_public.x));

    // Deterministic in the seed (so the TPM side, given the same Qe and its
    // own private key, reproducibly derives the identical salt).
    const a2 = try deriveSalt(qs, [_]u8{0x11} ** 64);
    try std.testing.expectEqualSlices(u8, &a.salt, &a2.salt);
}

test "marshalEncryptedSalt: wire layout is TPMS_ECC_POINT's two TPM2B coordinates, un-double-wrapped" {
    const point: EccPoint = .{ .x = [_]u8{0xAA} ** digest_len, .y = [_]u8{0xBB} ** digest_len };
    var buf: [encrypted_salt_len]u8 = undefined;
    const out = marshalEncryptedSalt(&buf, point);

    try std.testing.expectEqual(@as(usize, encrypted_salt_len), out.len);
    try std.testing.expectEqual(@as(u16, digest_len), std.mem.readInt(u16, out[0..2], .big));
    try std.testing.expectEqualSlices(u8, &point.x, out[2..][0..digest_len]);
    try std.testing.expectEqual(@as(u16, digest_len), std.mem.readInt(u16, out[2 + digest_len ..][0..2], .big));
    try std.testing.expectEqualSlices(u8, &point.y, out[2 + digest_len + 2 ..][0..digest_len]);
}

test "Session: command and response HMACs are independently verifiable and reject tampering" {
    var s: Session = .{
        .handle = 0x0300_0000,
        .key = [_]u8{0x42} ** digest_len,
        .nonce_caller = [_]u8{0x01} ** digest_len,
        .nonce_tpm = [_]u8{0x02} ** digest_len,
    };
    const cp_hash = [_]u8{0x03} ** digest_len;
    const hmac = s.commandHmac(cp_hash, attr_encrypt);
    try std.testing.expect(!std.mem.allEqual(u8, &hmac, 0));

    const rp_hash = [_]u8{0x04} ** digest_len;
    const new_nonce_tpm = [_]u8{0x05} ** digest_len;
    const good_hmac = blk: {
        var mac = HmacSha256.init(&s.key);
        mac.update(&rp_hash);
        mac.update(&new_nonce_tpm);
        mac.update(&s.nonce_caller);
        mac.update(&.{attr_encrypt});
        var out: [digest_len]u8 = undefined;
        mac.final(&out);
        break :blk out;
    };

    var tampered = s;
    var bad_hmac = good_hmac;
    bad_hmac[0] ^= 0xFF;
    try std.testing.expectError(error.AuthFailed, tampered.verifyResponseHmac(rp_hash, attr_encrypt, new_nonce_tpm, &bad_hmac));

    try s.verifyResponseHmac(rp_hash, attr_encrypt, new_nonce_tpm, &good_hmac);
    try std.testing.expectEqualSlices(u8, &new_nonce_tpm, &s.nonce_tpm);
}

test "cfbCrypt: multi-block round-trip with a non-block-aligned final chunk" {
    const key = [_]u8{0x11} ** cfb_key_len;
    const iv = [_]u8{0x22} ** cfb_iv_len;
    const plain = "this sealed volume key is exactly the kind of thing SB-7 hides"; // not a multiple of 16
    try std.testing.expect(plain.len % 16 != 0);

    var buf: [plain.len]u8 = undefined;
    @memcpy(&buf, plain);
    cfbCrypt(key, iv, &buf, .encrypt);
    try std.testing.expect(!std.mem.eql(u8, plain, &buf)); // actually changed
    cfbCrypt(key, iv, &buf, .decrypt);
    try std.testing.expectEqualStrings(plain, &buf);
}

test "Session: encryptCommandParam/decryptResponseParam use independent key schedules but each round-trips" {
    var s: Session = .{
        .handle = 1,
        .key = [_]u8{0x77} ** digest_len,
        .nonce_caller = [_]u8{0x01} ** digest_len,
        .nonce_tpm = [_]u8{0x02} ** digest_len,
    };
    const secret = "0123456789abcdef0123456789abcdef"; // 33 bytes: > 2 blocks

    var cmd_buf: [secret.len]u8 = undefined;
    @memcpy(&cmd_buf, secret);
    s.encryptCommandParam(&cmd_buf);
    try std.testing.expect(!std.mem.eql(u8, secret, &cmd_buf));

    // A naive decrypt using the (unrolled) response key must NOT recover it.
    var wrong = cmd_buf;
    s.decryptResponseParam(&wrong);
    try std.testing.expect(!std.mem.eql(u8, secret, &wrong));

    // But re-deriving the same command-side key/IV does.
    const key_iv = deriveCfbKeyIv(s.key, s.nonce_caller, s.nonce_tpm);
    cfbCrypt(key_iv.key, key_iv.iv, &cmd_buf, .decrypt);
    try std.testing.expectEqualStrings(secret, &cmd_buf);
}
