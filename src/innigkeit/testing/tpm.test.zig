//! TPM CRB transport tests.
//!
//! Only collected when the kernel is built with the TPM gate enabled
//! (`-Dtpm_socket=...`), so the default suite baseline is unchanged.
//! Even then, the tests skip gracefully if no TPM is present.

const innigkeit = @import("innigkeit");
const std = @import("std");
const Tpm = innigkeit.drivers.tpm.Tpm;
const tpm_cmds = @import("../drivers/tpm/tpm.zig");

test "tpm/crb: GetCapability reports a manufacturer" {
    const tpm = Tpm.fromAcpi() orelse
        return error.SkipZigTest;
    const manufacturer = try tpm.getProperty(tpm_cmds.pt_manufacturer);
    // swtpm/libtpms reports "IBM\0" (0x49424d00); any TPM returns a non-zero id.
    try std.testing.expect(manufacturer != 0);
}

test "tpm/crb: GetRandom returns the requested byte count" {
    const tpm = Tpm.fromAcpi() orelse
        return error.SkipZigTest;
    var buf: [16]u8 = undefined;
    const got = try tpm.getRandom(&buf);
    try std.testing.expectEqual(@as(usize, buf.len), got.len);
}

test "tpm/crb: two GetRandom calls differ" {
    const tpm = Tpm.fromAcpi() orelse
        return error.SkipZigTest;
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    _ = try tpm.getRandom(&a);
    _ = try tpm.getRandom(&b);
    // Astronomically unlikely to collide; guards against a stuck/echoed buffer.
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "tpm/crb: PCR extend folds as SHA256(old || measurement)" {
    const tpm = Tpm.fromAcpi() orelse
        return error.SkipZigTest;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const pcr = 11; // OS-controlled PCR

    const before = try tpm.pcrRead(pcr);

    var measurement: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("innigkeit measured boot", &measurement, .{});
    try tpm.pcrExtend(pcr, measurement);

    const after = try tpm.pcrRead(pcr);

    // The TPM computes PCR_new = SHA256(PCR_old || measurement); reproduce it.
    var expected: [Sha256.digest_length]u8 = undefined;
    var h = Sha256.init(.{});
    h.update(&before);
    h.update(&measurement);
    h.final(&expected);

    try std.testing.expectEqualSlices(u8, &expected, &after);
}

test "tpm/crb: CreatePrimary yields a usable handle" {
    const tpm = innigkeit.drivers.tpm.device() orelse
        return error.SkipZigTest;
    const handle = try tpm.createPrimary();
    defer tpm.flushContext(handle);
    try std.testing.expect(handle != 0);
}

test "tpm/crb: PolicyPCR trial session yields a non-zero digest" {
    const tpm = innigkeit.drivers.tpm.device() orelse
        return error.SkipZigTest;
    const session = try tpm.startAuthSession(.trial);
    defer tpm.flushContext(session);

    try tpm.policyPcr(session, 11);
    const digest = try tpm.policyGetDigest(session);

    // A PCR-bound policy digest is a SHA-256 over (zero policy || PolicyPCR ||
    // pcr selection || pcr digest), so it must be non-zero.
    try std.testing.expect(!std.mem.allEqual(u8, &digest, 0));
}

test "tpm/crb: seal to a PCR policy and unseal it back" {
    const tpm = innigkeit.drivers.tpm.device() orelse
        return error.SkipZigTest;

    const primary = try tpm.createPrimary();
    defer tpm.flushContext(primary);

    // Derive the PCR-11 auth policy via a trial session.
    const trial = try tpm.startAuthSession(.trial);
    try tpm.policyPcr(trial, 11);
    const policy = try tpm.policyGetDigest(trial);
    tpm.flushContext(trial);

    const secret = "disk-volume-key-0123456789abcdef"; // 32 bytes
    const obj = try tpm.create(primary, policy, secret);
    const item = try tpm.load(primary, obj);
    defer tpm.flushContext(item);

    // Unseal under a real policy session bound to the same PCR.
    const session = try tpm.startAuthSession(.policy);
    try tpm.policyPcr(session, 11);
    var out: [64]u8 = undefined;
    const recovered = try tpm.unseal(item, session, &out); // consumes the session
    try std.testing.expectEqualSlices(u8, secret, recovered);
}

test "tpm/crb: sealToPcr/unsealWithPcr round-trip" {
    const tpm = innigkeit.drivers.tpm.device() orelse
        return error.SkipZigTest;
    const primary = try tpm.createPrimary();
    defer tpm.flushContext(primary);

    const secret = "wrapper round-trip volume key";
    const obj = try tpm.sealToPcr(primary, 11, secret);
    var out: [64]u8 = undefined;
    const got = try tpm.unsealWithPcr(primary, 11, obj, &out);
    try std.testing.expectEqualSlices(u8, secret, got);
}

test "tpm/crb: unseal fails after the bound PCR changes" {
    const tpm = innigkeit.drivers.tpm.device() orelse
        return error.SkipZigTest;
    const primary = try tpm.createPrimary();
    defer tpm.flushContext(primary);

    const secret = "key sealed to a known boot state";
    const obj = try tpm.sealToPcr(primary, 11, secret);

    // Extend PCR 11 -> the policy can no longer be satisfied.
    var tamper: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("evil-maid", &tamper, .{});
    try tpm.pcrExtend(11, tamper);

    var out: [64]u8 = undefined;
    try std.testing.expectError(error.TpmError, tpm.unsealWithPcr(primary, 11, obj, &out));
}

test "tpm/eventlog: bootloader provides a crypto-agile TCG log" {
    const eventlog = innigkeit.drivers.tpm.eventlog;
    const elog = eventlog.locate() orelse return error.SkipZigTest;
    try std.testing.expect(elog.format == .tcg_2);

    // Crypto-agile log: first record TCG_PCClientPCREvent = pcrIndex(4) ||
    // eventType(4) || digest[20] || eventDataSize(4) || event[]; the event data
    // opens with the Spec ID Event03 signature.
    const sig_off = 4 + 4 + 20 + 4;
    try std.testing.expect(elog.bytes.len > sig_off + eventlog.spec_id_signature.len);
    try std.testing.expectEqualSlices(
        u8,
        eventlog.spec_id_signature,
        elog.bytes[sig_off..][0..eventlog.spec_id_signature.len],
    );
}

test "tpm/eventlog: replayed log reproduces the firmware PCRs" {
    const tpm = innigkeit.drivers.tpm.device() orelse
        return error.SkipZigTest;
    const eventlog = innigkeit.drivers.tpm.eventlog;
    const elog = eventlog.locate() orelse
        return error.SkipZigTest;

    // PCRs 0..7 are firmware/boot owned and untouched by the OS, so replaying
    // the captured log must reproduce their live values exactly.
    //
    // Limine captures the log via EFI_TCG2_PROTOCOL.GetEventLog
    // *before* it calls ExitBootServices, but the firmware measures two normative
    // EV_EFI_ACTION strings into PCR 5 *inside* ExitBootServices (TCG PC Client
    // PFP §10.4.4). Those two extends therefore hit the live TPM but are absent
    // from our frozen log snapshot, so PCR 5's replay is short by exactly them.
    // We reconcile by folding the two known action digests onto the PCR-5 replay;
    // every other PCR must match the raw replay. (PCR 11 is excluded here: the
    // kernel extends it after the log was captured.)
    //
    // Compare with `memory.eql` + kernel-log diagnostics: expectEqualSlices would
    // `std.debug.print` a diff on mismatch, which panics in the freestanding kernel.
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const ebs_actions = [_][]const u8{
        "Exit Boot Services Invocation",
        "Exit Boot Services Returned with Success",
    };

    const diag = innigkeit.debug.log.scoped(.eventlog_diag);
    var mismatches: u32 = 0;
    var pcr: u32 = 0;
    while (pcr < 8) : (pcr += 1) {
        var replayed = try eventlog.replaySha256Pcr(elog, pcr);

        // PCR 5 only: append the post-snapshot ExitBootServices measurements. An
        // EV_EFI_ACTION digest is SHA256 over the action string (no NUL).
        if (pcr == 5) {
            for (ebs_actions) |action| {
                var action_digest: [Sha256.digest_length]u8 = undefined;
                Sha256.hash(action, &action_digest, .{});
                var h = Sha256.init(.{});
                h.update(&replayed);
                h.update(&action_digest);
                h.final(&replayed);
            }
        }

        const actual = try tpm.pcrRead(pcr);
        if (!std.mem.eql(u8, &replayed, &actual)) {
            diag.err("PCR{d}: replay={x} actual={x}", .{ pcr, &replayed, &actual });
            mismatches += 1;
        }
    }
    try std.testing.expect(mismatches == 0);
}

test "tpm/eventlog: SecureBoot state is readable from the PCR-7 log" {
    const eventlog = innigkeit.drivers.tpm.eventlog;
    const elog = eventlog.locate() orelse return error.SkipZigTest;

    // The firmware measures the SecureBoot EFI variable into PCR 7 as an
    // EV_EFI_VARIABLE_DRIVER_CONFIG event. Firmware without Secure Boot support
    // (the default non-secboot OVMF) does not carry it -> null; skip there rather
    // than fail. Under a Secure-Boot-capable firmware this returns the measured
    // enabled/disabled state. Either way the parse must not error.
    const state = try eventlog.secureBootEnabled(elog) orelse return error.SkipZigTest;

    // When booted under a Secure-Boot-enrolled OVMF, the measured state must be *enabled*.
    if (@import("kernel_options").expect_secure_boot) {
        try std.testing.expect(state);
    }
}

// In-memory backing so the seam test exercises the real TPM seal/unseal of an
// XTS volume key without needing a writable disk in the test VM.
const RamDisk = struct {
    sectors: [4][512]u8 = std.mem.zeroes([4][512]u8),

    pub fn readSectors(self: *RamDisk, lba: u64, buf: []u8, count: u32) !void {
        var i: u32 = 0;
        while (i < count) : (i += 1) @memcpy(buf[i * 512 ..][0..512], &self.sectors[@intCast(lba + i)]);
    }

    pub fn writeSectors(self: *RamDisk, lba: u64, buf: []const u8, count: u32) !void {
        var i: u32 = 0;
        while (i < count) : (i += 1) @memcpy(&self.sectors[@intCast(lba + i)], buf[i * 512 ..][0..512]);
    }
};

test "tpm/crb: sealed volume key drives AES-XTS disk encryption" {
    const tpm = innigkeit.drivers.tpm.device() orelse return error.SkipZigTest;
    const EncryptedBlockDevice = innigkeit.crypto.EncryptedBlockDevice;

    const primary = try tpm.createPrimary();
    defer tpm.flushContext(primary);

    // A 64-byte AES-XTS-256 volume key from the TPM RNG (<=32 bytes/call).
    var key: [64]u8 = undefined;
    var off: usize = 0;
    while (off < key.len) {
        const got = try tpm.getRandom(key[off..][0..@min(32, key.len - off)]);
        off += got.len;
    }

    // Seal it to PCR 11, then recover it: the bytes must match exactly.
    const sealed = try tpm.sealToPcr(primary, 11, &key);
    var recovered: [64]u8 = undefined;
    const r = try tpm.unsealWithPcr(primary, 11, sealed, &recovered);
    try std.testing.expectEqualSlices(u8, &key, r);

    // The recovered key is a usable XTS key: encrypt through the device, confirm
    // the backing holds ciphertext, and read back the plaintext.
    var disk = RamDisk{};
    var dev = EncryptedBlockDevice(*RamDisk).init(&disk, recovered);
    const plain = [_]u8{0xC3} ** 512;
    try dev.writeSectors(1, &plain, 1);
    try std.testing.expect(!std.mem.eql(u8, &plain, &disk.sectors[1]));
    var out: [512]u8 = undefined;
    try dev.readSectors(1, &out, 1);
    try std.testing.expectEqualSlices(u8, &plain, &out);
}

test "encrypted volume: provision persists header, open recovers the key off disk" {
    const tpm = innigkeit.drivers.tpm.device() orelse return error.SkipZigTest;
    const ev = innigkeit.filesystem.EncryptedVolume;

    const primary = try tpm.createPrimary();
    defer tpm.flushContext(primary);

    var disk = RamDisk{};
    var v1 = try ev.provision(tpm, primary, &disk);
    const plain = [_]u8{0x5A} ** 512;
    try v1.writeSectors(ev.data_start_lba, &plain, 1);

    // A fresh mount: re-read the header off disk, unseal the key, decrypt.
    var v2 = try ev.open(tpm, primary, &disk);
    var out: [512]u8 = undefined;
    try v2.readSectors(ev.data_start_lba, &out, 1);
    try std.testing.expectEqualSlices(u8, &plain, &out);

    // The header sector is plaintext (magic); the data sector is ciphertext.
    try std.testing.expect(std.mem.eql(u8, "INNIKVOL", disk.sectors[0][0..8]));
    try std.testing.expect(!std.mem.eql(u8, &plain, &disk.sectors[ev.data_start_lba]));
}

test "tpm/crb: SecureVault is TPM-backed and seals/unseals" {
    if (innigkeit.drivers.tpm.device() == null) return error.SkipZigTest;
    const SecureVault = innigkeit.capabilities.SecureVault;

    const vault: *SecureVault = try .create();
    defer vault.unref();
    try std.testing.expect(vault.tpm_backed);

    const msg = "tpm-backed vault secret";
    var blob: [msg.len + SecureVault.OVERHEAD]u8 = undefined;
    const blob_len = try vault.seal(msg, &blob);
    var out: [msg.len]u8 = undefined;
    const out_len = try vault.unseal(blob[0..blob_len], &out);
    try std.testing.expectEqualSlices(u8, msg, out[0..out_len]);
}

test "encrypted volume: provisioned data disk mounts via the boot scan" {
    const tpm = innigkeit.drivers.tpm.device() orelse return error.SkipZigTest;
    const ev = innigkeit.filesystem.EncryptedVolume;
    const blk = innigkeit.drivers.virtio.blk;
    // Needs the second (blank) data disk the --tpm gate attaches.
    if (blk.deviceCount() < 2) return error.SkipZigTest;

    // The blank disk has no header, so stage4's scan mounted nothing.
    try std.testing.expect(ev.bootVolume() == null);

    // Provision it as an encrypted volume (seals the key to the CURRENT PCR
    // state, so the immediate re-scan below unseals under the same state).
    const primary = try tpm.createPrimary();
    defer tpm.flushContext(primary);
    var vol = try ev.provision(tpm, primary, ev.VirtioBacking{ .dev_idx = 1 });
    const plain = [_]u8{0xEE} ** 512;
    try vol.writeSectors(ev.data_start_lba, &plain, 1);

    // Re-run the boot scan: it must find the header, unseal, and mount.
    ev.mountAtBoot();
    const mounted = ev.bootVolume() orelse return error.TestUnexpectedResult;
    var out: [512]u8 = undefined;
    try mounted.readSectors(ev.data_start_lba, &out, 1);
    try std.testing.expect(std.mem.eql(u8, &plain, &out));
}

// Kept last: this test extends firmware PCR 7 to prove multi-PCR binding, which
// would corrupt the event-log replay test's PCR-7 comparison if it ran earlier.
test "tpm/crb: multi-PCR seal binds firmware + OS PCRs (0-7 & 11)" {
    const tpm = innigkeit.drivers.tpm.device() orelse return error.SkipZigTest;
    const seal_pcrs = &innigkeit.drivers.tpm.seal_pcrs;

    const primary = try tpm.createPrimary();
    defer tpm.flushContext(primary);

    // Seal to the full firmware+OS PCR set (0–7 & 11) and recover it back.
    const secret = "volume key bound to the whole boot";
    const obj = try tpm.sealToPcrs(primary, seal_pcrs, secret);
    var out: [64]u8 = undefined;
    const got = try tpm.unsealWithPcrs(primary, seal_pcrs, obj, &out);
    try std.testing.expectEqualSlices(u8, secret, got);

    // Tamper a *firmware* PCR (PCR 7 = Secure Boot policy). Because the key is
    // bound to 0–7 as well as 11, changing any one of them must break unseal.
    // This is what makes a tampered or Secure-Boot-disabled boot unable to
    // recover the disk key, not just an OS-level change.
    var tamper: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("firmware evil-maid", &tamper, .{});
    try tpm.pcrExtend(7, tamper);

    try std.testing.expectError(error.TpmError, tpm.unsealWithPcrs(primary, seal_pcrs, obj, &out));
}
