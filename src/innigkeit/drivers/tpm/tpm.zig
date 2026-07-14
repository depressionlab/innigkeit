//! TPM 2.0 command layer.

const std = @import("std");

const Crb = @import("crb.zig");
const innigkeit = @import("innigkeit");
const log = innigkeit.debug.log.scoped(.tpm);

const header_size = Crb.tpm_header_size;

const StructureTag = enum(u16) {
    no_sessions = 0x8001,
    sessions = 0x8002,
};

/// Command codes (TPM 2.0 Part 2).
const CommandCode = enum(u32) {
    get_capability = 0x0000_017A,
    get_random = 0x0000_017B,
    pcr_extend = 0x0000_0182,
    pcr_read = 0x0000_017E,
    create_primary = 0x0000_0131,
    flush_context = 0x0000_0165,
    start_auth_session = 0x0000_0176,
    policy_pcr = 0x0000_017F,
    policy_get_digest = 0x0000_0189,
    create = 0x0000_0153,
    load = 0x0000_0157,
    unseal = 0x0000_015E,
};

// Permanent handles.
const rh_owner: u32 = 0x4000_0001; // TPM_RH_OWNER (storage hierarchy)
const rh_null: u32 = 0x4000_0007; // TPM_RH_NULL

/// Authorization-session kinds (TPM_SE). A `trial` session computes a policy
/// digest without authorizing anything (used to derive an object's authPolicy);
/// a `policy` session authorizes a real command (e.g. Unseal).
pub const SessionType = enum(u8) {
    policy = 0x01,
    trial = 0x03,
};

// Algorithm identifiers (TPM 2.0 Part 2, TPM_ALG_ID).
const alg_ecc: u16 = 0x0023;
const alg_aes: u16 = 0x0006;
const alg_cfb: u16 = 0x0043;
const alg_null: u16 = 0x0010;
const alg_keyedhash: u16 = 0x0008;
const ecc_nist_p256: u16 = 0x0003;

/// TPMT_PUBLIC template for the storage-hierarchy parent: ECC NIST P-256,
/// fixedTPM|fixedParent|sensitiveDataOrigin|userWithAuth|noDA|restricted|decrypt
/// (objectAttributes 0x00030472), AES-128-CFB symmetric, NULL scheme/kdf, empty
/// unique. Built at comptime from the named constants to avoid magic bytes.
const ecc_parent_template: [26]u8 = blk: {
    var t: [26]u8 = undefined;
    var o: usize = 0;
    o = putU16(&t, o, alg_ecc); // type
    o = putU16(&t, o, alg_sha256); // nameAlg
    o = putU32(&t, o, 0x0003_0472); // objectAttributes
    o = putU16(&t, o, 0); // authPolicy (empty)
    o = putU16(&t, o, alg_aes); // symmetric.algorithm
    o = putU16(&t, o, 128); // symmetric.keyBits
    o = putU16(&t, o, alg_cfb); // symmetric.mode
    o = putU16(&t, o, alg_null); // scheme (NULL)
    o = putU16(&t, o, ecc_nist_p256); // curveID
    o = putU16(&t, o, alg_null); // kdf (NULL)
    o = putU16(&t, o, 0); // unique.x (empty)
    o = putU16(&t, o, 0); // unique.y (empty)
    break :blk t;
};

// Capabilities / properties.
const cap_tpm_properties: u32 = 0x0000_0006;
/// TPM_PT_MANUFACTURER (TPM2_PT_FIXED + 5).
pub const pt_manufacturer: u32 = 0x0000_0105;

// Password authorization session handle (TPM_RS_PW): empty-password auth, no
// HMAC. Sufficient for extending PCRs whose authValue is the default (empty);
// session-based parameter encryption is deferred hardening.
const rs_pw: u32 = 0x4000_0009;

// SHA-256 PCR bank: algorithm id and digest length.
const alg_sha256: u16 = 0x000B;
pub const sha256_digest_len = 32;

/// PCR select bitmap length covering PCRs 0..23 (PC Client: 24 PCRs / 8).
const pcr_select_min = 3;

/// Largest random request we issue in one command.
const max_random = 32;

pub const Error = Crb.Error || error{TpmError};

/// A sealed object as returned by `TPM2_Create`: the encrypted private blob and
/// its public area, which together can be `load`ed back under the same parent.
pub const SealedObject = struct {
    private: [256]u8 = undefined,
    private_len: usize = 0,
    public: [128]u8 = undefined,
    public_len: usize = 0,

    pub fn privateBytes(self: *const SealedObject) []const u8 {
        return self.private[0..self.private_len];
    }
    pub fn publicBytes(self: *const SealedObject) []const u8 {
        return self.public[0..self.public_len];
    }
};

/// A TPM 2.0 device reached over the CRB transport.
pub const Tpm = struct {
    transport: Crb,

    /// Probe ACPI for a usable CRB TPM; `null` if none is present/supported.
    pub fn fromAcpi() ?Tpm {
        return .{ .transport = Crb.fromAcpi() orelse return null };
    }

    /// `TPM2_GetRandom`: fill `out` (<= 32 bytes) with TPM-generated random
    /// bytes, returning the populated prefix (the TPM may return fewer).
    pub fn getRandom(self: Tpm, out: []u8) Error![]u8 {
        std.debug.assert(out.len <= max_random);

        var cmd: [header_size + 2]u8 = undefined;
        writeHeader(&cmd, .no_sessions, cmd.len, .get_random);
        std.mem.writeInt(u16, cmd[header_size..][0..2], @intCast(out.len), .big);

        var rsp: [header_size + 2 + max_random]u8 = undefined;
        const body = try self.run(&cmd, &rsp);

        // Response body is a TPM2B_DIGEST: size(2) || bytes.
        if (body.len < 2) return Crb.Error.MalformedResponse;
        const size = std.mem.readInt(u16, body[0..][0..2], .big);
        if (size > out.len or 2 + @as(usize, size) > body.len) return Crb.Error.MalformedResponse;
        @memcpy(out[0..size], body[2..][0..size]);
        return out[0..size];
    }

    /// `TPM2_GetCapability` for a single `TPM_CAP_TPM_PROPERTIES` value.
    pub fn getProperty(self: Tpm, property: u32) Error!u32 {
        var cmd: [header_size + 12]u8 = undefined;
        writeHeader(&cmd, .no_sessions, cmd.len, .get_capability);
        std.mem.writeInt(u32, cmd[header_size..][0..4], cap_tpm_properties, .big);
        std.mem.writeInt(u32, cmd[header_size + 4 ..][0..4], property, .big);
        std.mem.writeInt(u32, cmd[header_size + 8 ..][0..4], 1, .big); // propertyCount

        var rsp: [64]u8 = undefined;
        const body = try self.run(&cmd, &rsp);

        // Body: moreData(1) || capability(4) || propertyCount(4) || [ property(4) value(4) ].
        if (body.len < 1 + 4 + 4 + 8) return Crb.Error.MalformedResponse;
        const count = std.mem.readInt(u32, body[5..][0..4], .big);
        if (count < 1) return Crb.Error.MalformedResponse;
        return std.mem.readInt(u32, body[13..][0..4], .big);
    }

    /// `TPM2_PCR_Extend`: fold `digest` into the SHA-256 bank of PCR `index`
    /// (PCR_new = SHA256(PCR_old || digest)). Uses an empty-password session.
    pub fn pcrExtend(self: Tpm, index: u32, digest: [sha256_digest_len]u8) Error!void {
        // header || pcrHandle(4) || authSize(4) || authArea(9) ||
        //   TPML_DIGEST_VALUES{ count(4) || hashAlg(2) || digest(32) }
        const auth_area_size = 9; // RS_PW(4) || nonceSize(2)=0 || attrs(1)=0 || hmacSize(2)=0
        var cmd: [header_size + 4 + 4 + auth_area_size + 4 + 2 + sha256_digest_len]u8 = undefined;
        writeHeader(&cmd, .sessions, cmd.len, .pcr_extend);

        var off: usize = header_size;
        off = putU32(&cmd, off, index); // pcrHandle (PCR index is its own handle)
        off = putU32(&cmd, off, auth_area_size);
        off = putU32(&cmd, off, rs_pw); // sessionHandle
        off = putU16(&cmd, off, 0); // nonceSize
        cmd[off] = 0; // sessionAttributes
        off += 1;
        off = putU16(&cmd, off, 0); // hmacSize (empty password)
        off = putU32(&cmd, off, 1); // digest count
        off = putU16(&cmd, off, alg_sha256);
        @memcpy(cmd[off..][0..sha256_digest_len], &digest);
        off += sha256_digest_len;
        std.debug.assert(off == cmd.len);

        var rsp: [header_size + 16]u8 = undefined;
        _ = try self.run(&cmd, &rsp); // run() validates the response code
    }

    /// `TPM2_PCR_Read`: read the current SHA-256 value of PCR `index`.
    pub fn pcrRead(self: Tpm, index: u32) Error![sha256_digest_len]u8 {
        // header || TPML_PCR_SELECTION{ count(4)=1 || TPMS_PCR_SELECTION{ hash(2) ||
        //   sizeofSelect(1)=3 || pcrSelect(3) } }
        var cmd: [header_size + 4 + 2 + 1 + pcr_select_min]u8 = undefined;
        writeHeader(&cmd, .no_sessions, cmd.len, .pcr_read);

        var off: usize = header_size;
        off = putU32(&cmd, off, 1); // count of selections
        off = putU16(&cmd, off, alg_sha256);
        cmd[off] = pcr_select_min; // sizeofSelect
        off += 1;
        std.debug.assert(index >> 3 < pcr_select_min);
        var select = [_]u8{0} ** pcr_select_min;
        select[index >> 3] |= @as(u8, 1) << @intCast(index & 0x7);
        @memcpy(cmd[off..][0..pcr_select_min], &select);
        off += pcr_select_min;
        std.debug.assert(off == cmd.len);

        var rsp: [128]u8 = undefined;
        const body = try self.run(&cmd, &rsp);

        // Body: pcrUpdateCounter(4) || TPML_PCR_SELECTION{ count(4) || hash(2) ||
        //   sizeofSelect(1) || select(3) } || TPML_DIGEST{ count(4) ||
        //   TPM2B_DIGEST{ size(2) || digest } }.
        const digest_size_off = 4 + 4 + 2 + 1 + pcr_select_min + 4; // = 18
        if (body.len < digest_size_off + 2 + sha256_digest_len) return Crb.Error.MalformedResponse;
        const digest_size = std.mem.readInt(u16, body[digest_size_off..][0..2], .big);
        if (digest_size != sha256_digest_len) return Crb.Error.MalformedResponse;

        var out: [sha256_digest_len]u8 = undefined;
        @memcpy(&out, body[digest_size_off + 2 ..][0..sha256_digest_len]);
        return out;
    }

    /// `TPM2_CreatePrimary`: create the storage-hierarchy primary (an ECC
    /// NIST P-256 restricted-decrypt parent) used to wrap sealed objects.
    /// Returns the transient object handle; the caller must `flushContext` it.
    /// The primary is regenerated deterministically from the hierarchy seed,
    /// so the same template yields the same key each boot.
    pub fn createPrimary(self: Tpm) Error!u32 {
        var cmd: [256]u8 = undefined;
        var off: usize = header_size;
        off = putU32(&cmd, off, rh_owner); // primaryHandle (auth = owner)

        // Authorization area: empty-password session.
        off = putU32(&cmd, off, 9); // authorizationSize
        off = putU32(&cmd, off, rs_pw);
        off = putU16(&cmd, off, 0); // nonce
        cmd[off] = 0; // sessionAttributes
        off += 1;
        off = putU16(&cmd, off, 0); // hmac (empty password)

        // inSensitive (TPM2B_SENSITIVE_CREATE): empty userAuth + empty data.
        off = putU16(&cmd, off, 4); // size of the sensitive-create structure
        off = putU16(&cmd, off, 0); // userAuth (TPM2B_AUTH), empty
        off = putU16(&cmd, off, 0); // data (TPM2B_SENSITIVE_DATA), empty

        // inPublic (TPM2B_PUBLIC): the ECC storage-parent template.
        off = putU16(&cmd, off, ecc_parent_template.len);
        @memcpy(cmd[off..][0..ecc_parent_template.len], &ecc_parent_template);
        off += ecc_parent_template.len;

        off = putU16(&cmd, off, 0); // outsideInfo (TPM2B_DATA), empty
        off = putU32(&cmd, off, 0); // creationPCR (TPML_PCR_SELECTION), none

        writeHeader(cmd[0..off], .sessions, off, .create_primary);

        var rsp: [512]u8 = undefined;
        const resp = try self.transport.transmit(cmd[0..off], &rsp);
        try checkRc(resp, .create_primary);
        // Response handle area: the new object handle follows the 10-byte header.
        if (resp.len < header_size + 4) return Crb.Error.MalformedResponse;
        return std.mem.readInt(u32, resp[header_size..][0..4], .big);
    }

    /// `TPM2_FlushContext`: evict a transient object or session handle.
    pub fn flushContext(self: Tpm, handle: u32) void {
        var cmd: [header_size + 4]u8 = undefined;
        writeHeader(&cmd, .no_sessions, cmd.len, .flush_context);
        _ = putU32(&cmd, header_size, handle);
        var rsp: [header_size + 8]u8 = undefined;
        _ = self.transport.transmit(&cmd, &rsp) catch |err|
            log.warn("FlushContext(0x{x:0>8}) failed: {t}", .{ handle, err });
    }

    /// `TPM2_StartAuthSession`: open an unbound, unsalted SHA-256 session of
    /// the given kind (no parameter encryption). Returns the session handle;
    /// the caller must `flushContext` it.
    pub fn startAuthSession(self: Tpm, session_type: SessionType) Error!u32 {
        var cmd: [header_size + 4 + 4 + 2 + 16 + 2 + 1 + 2 + 2]u8 = undefined;
        var off: usize = header_size;
        off = putU32(&cmd, off, rh_null); // tpmKey (no salt)
        off = putU32(&cmd, off, rh_null); // bind (unbound)
        off = putU16(&cmd, off, 16); // nonceCaller size (>= 16 required)
        @memset(cmd[off..][0..16], 0);
        off += 16;
        off = putU16(&cmd, off, 0); // encryptedSalt (empty)
        cmd[off] = @intFromEnum(session_type);
        off += 1;
        off = putU16(&cmd, off, alg_null); // symmetric (no param encryption)
        off = putU16(&cmd, off, alg_sha256); // authHash
        std.debug.assert(off == cmd.len);

        writeHeader(&cmd, .no_sessions, cmd.len, .start_auth_session);
        var rsp: [128]u8 = undefined;
        const resp = try self.transport.transmit(&cmd, &rsp);
        try checkRc(resp, .start_auth_session);
        if (resp.len < header_size + 4) return Crb.Error.MalformedResponse;
        return std.mem.readInt(u32, resp[header_size..][0..4], .big);
    }

    /// `TPM2_PolicyPCR`: bind `session`'s policy to the current SHA-256 value of
    /// PCR `index`. An empty pcrDigest makes the TPM fold in whatever the PCR
    /// currently holds, so a real policy session unseals only when the PCR
    /// still matches the value present when the object was sealed.
    pub fn policyPcr(self: Tpm, session: u32, index: u32) Error!void {
        return self.policyPcrSet(session, &.{index});
    }

    /// `TPM2_PolicyPCR` over a *set* of PCRs in the SHA-256 bank: binds the
    /// session to the combined state of every PCR in `indices` (one
    /// `TPML_PCR_SELECTION`, multiple selection bits). Used to seal secrets to
    /// firmware/Secure-Boot PCRs 0–7 *and* the OS-controlled PCR 11 at once, so a
    /// change to any of them breaks the policy.
    pub fn policyPcrSet(self: Tpm, session: u32, indices: []const u32) Error!void {
        var cmd: [header_size + 4 + 2 + 4 + 2 + 1 + pcr_select_min]u8 = undefined;
        var off: usize = header_size;
        off = putU32(&cmd, off, session); // policySession handle
        off = putU16(&cmd, off, 0); // pcrDigest (empty)
        off = putU32(&cmd, off, 1); // pcrSelection count (single SHA-256 bank)
        off = putU16(&cmd, off, alg_sha256);
        cmd[off] = pcr_select_min;
        off += 1;
        var select = [_]u8{0} ** pcr_select_min;
        for (indices) |index| {
            std.debug.assert(index >> 3 < pcr_select_min);
            select[index >> 3] |= @as(u8, 1) << @intCast(index & 0x7);
        }
        @memcpy(cmd[off..][0..pcr_select_min], &select);
        off += pcr_select_min;
        std.debug.assert(off == cmd.len);

        writeHeader(&cmd, .no_sessions, cmd.len, .policy_pcr);
        var rsp: [header_size + 16]u8 = undefined;
        const resp = try self.transport.transmit(&cmd, &rsp);
        try checkRc(resp, .policy_pcr);
    }

    /// `TPM2_PolicyGetDigest`: read `session`'s current policy digest. Used on a
    /// trial session to obtain the authPolicy to seal an object under.
    pub fn policyGetDigest(self: Tpm, session: u32) Error![sha256_digest_len]u8 {
        var cmd: [header_size + 4]u8 = undefined;
        writeHeader(&cmd, .no_sessions, cmd.len, .policy_get_digest);
        _ = putU32(&cmd, header_size, session);

        var rsp: [128]u8 = undefined;
        const body = try self.run(&cmd, &rsp);
        if (body.len < 2) return Crb.Error.MalformedResponse;
        const len = std.mem.readInt(u16, body[0..][0..2], .big);
        if (len != sha256_digest_len or body.len < 2 + sha256_digest_len) {
            return Crb.Error.MalformedResponse;
        }
        var out: [sha256_digest_len]u8 = undefined;
        @memcpy(&out, body[2..][0..sha256_digest_len]);
        return out;
    }

    /// `TPM2_Create`: seal `data` into a keyedHash object under `parent`,
    /// gated by `policy` (a PolicyPCR digest from a trial session). The object
    /// has no authValue and `userWithAuth` clear, so it can only be unsealed via
    /// a policy session that reproduces `policy` (i.e. only when the bound PCR
    /// still matches. Returns the sealed private/public pair).
    pub fn create(self: Tpm, parent: u32, policy: [sha256_digest_len]u8, data: []const u8) Error!SealedObject {
        var cmd: [512]u8 = undefined;
        var off: usize = header_size;
        off = putU32(&cmd, off, parent);

        off = emptyPasswordAuth(&cmd, off);

        // inSensitive: empty userAuth, sealed data = `data`.
        off = putU16(&cmd, off, @intCast(2 + 2 + data.len)); // TPM2B_SENSITIVE_CREATE size
        off = putU16(&cmd, off, 0); // userAuth (empty)
        off = putU16(&cmd, off, @intCast(data.len)); // sensitive data size
        @memcpy(cmd[off..][0..data.len], data);
        off += data.len;

        // inPublic: keyedHash sealed-data template with the PCR auth policy.
        const public_size_at = off;
        var p = off + 2;
        p = putU16(&cmd, p, alg_keyedhash); // type
        p = putU16(&cmd, p, alg_sha256); // nameAlg
        p = putU32(&cmd, p, 0x0000_0412); // fixedTPM | fixedParent | noDA
        p = putU16(&cmd, p, sha256_digest_len); // authPolicy size
        @memcpy(cmd[p..][0..sha256_digest_len], &policy);
        p += sha256_digest_len;
        p = putU16(&cmd, p, alg_null); // keyedHash scheme (NULL = plain sealed data)
        p = putU16(&cmd, p, 0); // unique (empty)
        _ = putU16(&cmd, public_size_at, @intCast(p - (public_size_at + 2)));
        off = p;

        off = putU16(&cmd, off, 0); // outsideInfo (empty)
        off = putU32(&cmd, off, 0); // creationPCR (none)

        writeHeader(cmd[0..off], .sessions, off, .create);
        var rsp: [1024]u8 = undefined;
        const resp = try self.transport.transmit(cmd[0..off], &rsp);
        try checkRc(resp, .create);

        // ST_SESSIONS response: header(10) || paramSize(4) || outPrivate || outPublic || ...
        if (resp.len < header_size + 4) return Crb.Error.MalformedResponse;
        const params = resp[header_size + 4 ..];
        const priv = try readTpm2b(params, 0);
        const publ = try readTpm2b(params, priv.next);

        var obj: SealedObject = .{};
        if (priv.bytes.len > obj.private.len or publ.bytes.len > obj.public.len) {
            return Crb.Error.MalformedResponse;
        }
        @memcpy(obj.private[0..priv.bytes.len], priv.bytes);
        obj.private_len = priv.bytes.len;
        @memcpy(obj.public[0..publ.bytes.len], publ.bytes);
        obj.public_len = publ.bytes.len;
        return obj;
    }

    /// `TPM2_Load`: load a sealed object back under `parent`, returning the
    /// transient handle (flush it when done).
    pub fn load(self: Tpm, parent: u32, obj: SealedObject) Error!u32 {
        var cmd: [512]u8 = undefined;
        var off: usize = header_size;
        off = putU32(&cmd, off, parent);
        off = emptyPasswordAuth(&cmd, off);
        off = putU16(&cmd, off, @intCast(obj.private_len));
        @memcpy(cmd[off..][0..obj.private_len], obj.privateBytes());
        off += obj.private_len;
        off = putU16(&cmd, off, @intCast(obj.public_len));
        @memcpy(cmd[off..][0..obj.public_len], obj.publicBytes());
        off += obj.public_len;

        writeHeader(cmd[0..off], .sessions, off, .load);
        var rsp: [256]u8 = undefined;
        const resp = try self.transport.transmit(cmd[0..off], &rsp);
        try checkRc(resp, .load);
        if (resp.len < header_size + 4) return Crb.Error.MalformedResponse;
        return std.mem.readInt(u32, resp[header_size..][0..4], .big);
    }

    /// `TPM2_Unseal`: recover the sealed data from `item`, authorized by a
    /// `policy_session` that has satisfied the object's PCR policy. The session
    /// is consumed (continueSession is not set), so the caller must not reuse
    /// or re-flush it.
    pub fn unseal(self: Tpm, item: u32, policy_session: u32, out: []u8) Error![]u8 {
        var cmd: [header_size + 4 + 4 + 9]u8 = undefined;
        var off: usize = header_size;
        off = putU32(&cmd, off, item);
        // Authorization area referencing the policy session (empty HMAC).
        off = putU32(&cmd, off, 9); // authorizationSize
        off = putU32(&cmd, off, policy_session);
        off = putU16(&cmd, off, 0); // nonce
        cmd[off] = 0; // sessionAttributes (continueSession clear -> auto-flush)
        off += 1;
        off = putU16(&cmd, off, 0); // hmac (empty)
        std.debug.assert(off == cmd.len);

        writeHeader(&cmd, .sessions, cmd.len, .unseal);
        var rsp: [256]u8 = undefined;
        const resp = try self.transport.transmit(&cmd, &rsp);
        try checkRc(resp, .unseal);
        if (resp.len < header_size + 4) return Crb.Error.MalformedResponse;
        const data = try readTpm2b(resp[header_size + 4 ..], 0);
        if (data.bytes.len > out.len) return Crb.Error.MalformedResponse;
        @memcpy(out[0..data.bytes.len], data.bytes);
        return out[0..data.bytes.len];
    }

    /// Seal `data` under `parent` so it can only be recovered while PCR `pcr`
    /// holds its current SHA-256 value. Derives the auth policy with a trial
    /// session, then `create`s the sealed object. Returns the object to persist.
    pub fn sealToPcr(self: Tpm, parent: u32, pcr: u32, data: []const u8) Error!SealedObject {
        return self.sealToPcrs(parent, &.{pcr}, data);
    }

    /// Recover data sealed by `sealToPcr`. Succeeds only if PCR `pcr` still
    /// holds the value it had at seal time; otherwise the policy is not
    /// satisfied and the TPM refuses to unseal.
    pub fn unsealWithPcr(self: Tpm, parent: u32, pcr: u32, obj: SealedObject, out: []u8) Error![]u8 {
        return self.unsealWithPcrs(parent, &.{pcr}, obj, out);
    }

    /// Seal `data` bound to the combined state of every PCR in `pcrs` (all in the
    /// SHA-256 bank). For maximal security, we use the firmware/Secure-Boot
    /// PCRs 0–7 *and* the OS-measured PCR 11, so any pre-OS *or* OS tampering
    /// breaks unseal.
    pub fn sealToPcrs(self: Tpm, parent: u32, pcrs: []const u32, data: []const u8) Error!SealedObject {
        const trial = try self.startAuthSession(.trial);
        defer self.flushContext(trial);
        try self.policyPcrSet(trial, pcrs);
        const policy = try self.policyGetDigest(trial);
        return self.create(parent, policy, data);
    }

    /// Recover data sealed by `sealToPcrs`. Succeeds only if every bound PCR
    /// still holds its seal-time value; a change to any one leaves the policy
    /// unsatisfiable and the TPM refuses to unseal.
    pub fn unsealWithPcrs(self: Tpm, parent: u32, pcrs: []const u32, obj: SealedObject, out: []u8) Error![]u8 {
        const item = try self.load(parent, obj);
        defer self.flushContext(item);

        const session = try self.startAuthSession(.policy);
        // unseal() consumes the session on success; flush it only if we error
        // out before then (e.g. PolicyPCR/Unseal failure leaves it live).
        errdefer self.flushContext(session);
        try self.policyPcrSet(session, pcrs);
        return self.unseal(item, session, out);
    }

    /// Transmit a command and return the response *body* (the bytes after the
    /// 10-byte header), after checking the response code is success.
    fn run(self: Tpm, cmd: []const u8, rsp: []u8) Error![]u8 {
        const resp = try self.transport.transmit(cmd, rsp);
        try checkRc(resp, @enumFromInt(std.mem.readInt(u32, cmd[6..][0..4], .big)));
        return resp[header_size..];
    }
};

/// Validate a TPM response header's response code (bytes 6..10) is success.
fn checkRc(resp: []const u8, code: CommandCode) Error!void {
    if (resp.len < header_size) return Crb.Error.MalformedResponse;
    const rc = std.mem.readInt(u32, resp[6..][0..4], .big);
    if (rc != 0) {
        log.err("TPM command 0x{x:0>8} failed: rc=0x{x:0>8}", .{ @intFromEnum(code), rc });
        return Error.TpmError;
    }
}

/// Write a TPM 2.0 command header: tag(2) || commandSize(4) || commandCode(4).
fn writeHeader(buf: []u8, tag: StructureTag, size: usize, code: CommandCode) void {
    std.mem.writeInt(u16, buf[0..][0..2], @intFromEnum(tag), .big);
    std.mem.writeInt(u32, buf[2..][0..4], @intCast(size), .big);
    std.mem.writeInt(u32, buf[6..][0..4], @intFromEnum(code), .big);
}

/// Write a big-endian `u32` value at `off` in `buf`, returning the next offset.
fn putU32(buf: []u8, off: usize, value: u32) usize {
    std.mem.writeInt(u32, buf[off..][0..4], value, .big);
    return off + 4;
}

/// Write a big-endian `u16` value at `off` in `buf`, returning the next offset.
fn putU16(buf: []u8, off: usize, value: u16) usize {
    std.mem.writeInt(u16, buf[off..][0..2], value, .big);
    return off + 2;
}

/// Write an empty-password authorization area (TPM_RS_PW, no nonce, no
/// attributes, empty HMAC) at `off`, returning the next offset. authorizationSize
/// is the fixed 9 bytes that follow.
fn emptyPasswordAuth(buf: []u8, off: usize) usize {
    var o = putU32(buf, off, 9); // authorizationSize
    o = putU32(buf, o, rs_pw); // sessionHandle = TPM_RS_PW
    o = putU16(buf, o, 0); // nonce (empty)
    buf[o] = 0; // sessionAttributes
    o += 1;
    o = putU16(buf, o, 0); // hmac (empty password)
    return o;
}

/// Read a size-prefixed TPM2B field from `body` at `off`, returning its bytes
/// and the offset just past it.
fn readTpm2b(body: []const u8, off: usize) Error!struct { bytes: []const u8, next: usize } {
    if (off + 2 > body.len) return Crb.Error.MalformedResponse;
    const len = std.mem.readInt(u16, body[off..][0..2], .big);
    if (off + 2 + len > body.len) return Crb.Error.MalformedResponse;
    return .{ .bytes = body[off + 2 ..][0..len], .next = off + 2 + len };
}
