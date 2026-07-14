//! TPM-sealed encrypted volume.
//!
//! Binds disk encryption (AES-XTS `EncryptedBlockDevice`) to boot state
//! (PCR sealing). The AES-XTS volume key is generated from the TPM RNG and
//! sealed to the boot PCR; the sealed object is persisted in a plaintext header
//! in sector 0 of the volume. At mount, `open` reads the header, unseals the
//! key (which only succeeds when the measured boot state still matches), and
//! returns the encrypted device. The plaintext key lives only on the stack and
//! is zeroed before return.
//!
//! On-disk header (sector 0, plaintext): a multi-keyslot table (see
//! `volume_header.zig`). The kernel writes/reads the `tpm_pcr` slot (the
//! TPM-sealed volume key). Other slots (e.g. an Argon2id `passphrase` recovery
//! slot added by a host tool) are preserved and ignored here. Encrypted file
//! data lives in sectors `data_start_lba`..; sector 0 is never handed to the
//! encrypted device.

const innigkeit = @import("innigkeit");
const std = @import("std");
const blk = innigkeit.drivers.virtio.blk;
const Tpm = innigkeit.drivers.tpm.Tpm;
const SealedObject = innigkeit.drivers.tpm.SealedObject;
const EncryptedBlockDevice = innigkeit.crypto.EncryptedBlockDevice;
const VolumeHeader = @import("VolumeHeader.zig");
const log = innigkeit.debug.log.scoped(.enc_volume);

/// virtio-blk backing store for the `EncryptedBlockDevice`.
pub const VirtioBacking = struct {
    dev_idx: usize,

    pub fn readSectors(self: VirtioBacking, lba: u64, buf: []u8, count: u32) blk.ReadError!void {
        return blk.readSectors(self.dev_idx, lba, buf, count);
    }
    pub fn writeSectors(self: VirtioBacking, lba: u64, buf: []const u8, count: u32) blk.WriteError!void {
        return blk.writeSectors(self.dev_idx, lba, buf, count);
    }
};

/// A virtio-blk volume transparently encrypted with AES-XTS-256.
pub const Volume = EncryptedBlockDevice(VirtioBacking);

/// AES-XTS-256 volume-key length (32-byte data key || 32-byte tweak key).
pub const key_length = EncryptedBlockDevice(VirtioBacking).key_length;

/// PCRs the volume key is sealed to: firmware/Secure-Boot PCRs 0–7 *and* the OS
/// measurement PCR 11.
pub const seal_pcrs = &innigkeit.drivers.tpm.seal_pcrs;

const sector_size = 512;
const header_lba = 0;
/// Encrypted data starts after the header sector.
pub const data_start_lba = 1;

pub const Error = error{ BadHeader, ShortKey } || error{DeviceError};

/// Generate a fresh volume key from the TPM RNG, seal it to the boot PCR under
/// `parent`, write the sealed object into the volume header, and return the
/// opened encrypted device. `backing` is any block store exposing
/// `readSectors`/`writeSectors` (kernel: `VirtioBacking`).
pub fn provision(tpm: Tpm, parent: u32, backing: anytype) !EncryptedBlockDevice(@TypeOf(backing)) {
    var key: [key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try fillFromTpm(tpm, &key);

    const sealed = try tpm.sealToPcrs(parent, seal_pcrs, &key);
    var sector: [sector_size]u8 = undefined;
    var tpm_slot: [tpm_slot_max]u8 = undefined;
    const payload = encodeTpmSlot(&tpm_slot, sealed);
    VolumeHeader.write(&sector, &.{.{ .type = .tpm_pcr, .bytes = payload }}) catch
        return Error.BadHeader;
    try backing.writeSectors(header_lba, &sector, 1);
    return EncryptedBlockDevice(@TypeOf(backing)).init(backing, key);
}

/// Mount an existing volume: read the header from sector 0, unseal the volume
/// key (succeeds only if the boot PCR still matches its value at provision
/// time), and return the encrypted device.
pub fn open(tpm: Tpm, parent: u32, backing: anytype) !EncryptedBlockDevice(@TypeOf(backing)) {
    var sector: [sector_size]u8 = undefined;
    try backing.readSectors(header_lba, &sector, 1);
    const parsed = VolumeHeader.parse(&sector) catch return Error.BadHeader;
    const payload = parsed.find(.tpm_pcr) orelse return Error.BadHeader;
    const sealed = decodeTpmSlot(payload) catch return Error.BadHeader;

    var key: [key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);

    const recovered = try tpm.unsealWithPcrs(parent, seal_pcrs, sealed, &key);
    if (recovered.len != key_length) {
        log.err("unsealed volume key has wrong length {d}", .{recovered.len});
        return error.ShortKey;
    }
    return EncryptedBlockDevice(@TypeOf(backing)).init(backing, key);
}

// The encrypted data volume mounted at boot, if one was found and opened.
var boot_volume: ?Volume = null;

/// The boot-mounted encrypted data volume, or null when none is present /
/// FDE is off / the boot state was untrusted and the key stayed sealed.
pub fn bootVolume() ?*Volume {
    return if (boot_volume) |*v| v else null;
}

/// Scan the virtio-blk devices for an encrypted data volume and mount the first
/// one found (stage4). The on-disk header IS the full-disk-encryption toggle: a
/// disk carrying the `INNIKVOL` magic must unseal to become available, and a
/// disk without it is a plaintext volume (FDE off). The disk is self-describing,
/// so the choice is made once at provision time and survives reinstalls.
pub fn mountAtBoot() void {
    const tpm_drv = innigkeit.drivers.tpm;

    var i: usize = 0;
    while (i < blk.deviceCount()) : (i += 1) {
        var sector: [sector_size]u8 = undefined;
        blk.readSectors(i, header_lba, &sector, 1) catch continue;
        if (!std.mem.eql(u8, sector[0..8], &VolumeHeader.magic)) continue; // plaintext disk: FDE off

        if (tpm_drv.eventlog.locate()) |elog| {
            const sb_state = tpm_drv.eventlog.secureBootEnabled(elog) catch null;
            if (sb_state) |enabled| if (!enabled) {
                log.warn("blk[{d}]: encrypted volume found but Secure Boot is disabled; key stays sealed", .{i});
                continue;
            };
        }

        const tpm = tpm_drv.device() orelse {
            log.warn("blk[{d}]: encrypted volume found but no TPM; key stays sealed", .{i});
            continue;
        };
        const primary = tpm.createPrimary() catch |err| {
            log.warn("blk[{d}]: TPM primary creation failed: {t}; key stays sealed", .{ i, err });
            continue;
        };
        defer tpm.flushContext(primary);

        boot_volume = open(tpm, primary, VirtioBacking{ .dev_idx = i }) catch |err| {
            log.warn("blk[{d}]: encrypted volume did not unseal ({t}); boot state untrusted or header damaged", .{ i, err });
            continue;
        };
        log.info("blk[{d}]: encrypted data volume unsealed and mounted", .{i});
        return;
    }
}

// TPM-slot payload = private_len(u32 LE) || public_len(u32 LE) || private || public.
const tpm_slot_hdr = 8;
const tpm_slot_max = tpm_slot_hdr + @typeInfo(@FieldType(SealedObject, "private")).array.len +
    @typeInfo(@FieldType(SealedObject, "public")).array.len;

/// Serialize `sealed` into `buf`, returning the used prefix.
fn encodeTpmSlot(buf: *[tpm_slot_max]u8, sealed: SealedObject) []const u8 {
    std.mem.writeInt(u32, buf[0..4], @intCast(sealed.private_len), .little);
    std.mem.writeInt(u32, buf[4..8], @intCast(sealed.public_len), .little);
    @memcpy(buf[tpm_slot_hdr..][0..sealed.private_len], sealed.privateBytes());
    @memcpy(buf[tpm_slot_hdr + sealed.private_len ..][0..sealed.public_len], sealed.publicBytes());
    return buf[0 .. tpm_slot_hdr + sealed.private_len + sealed.public_len];
}

fn decodeTpmSlot(payload: []const u8) Error!SealedObject {
    if (payload.len < tpm_slot_hdr) return Error.BadHeader;
    var obj: SealedObject = .{};
    const private_len = std.mem.readInt(u32, payload[0..4], .little);
    const public_len = std.mem.readInt(u32, payload[4..8], .little);
    if (private_len > obj.private.len or public_len > obj.public.len) return Error.BadHeader;
    if (tpm_slot_hdr + private_len + public_len > payload.len) return Error.BadHeader;

    @memcpy(obj.private[0..private_len], payload[tpm_slot_hdr..][0..private_len]);
    obj.private_len = private_len;
    @memcpy(obj.public[0..public_len], payload[tpm_slot_hdr + private_len ..][0..public_len]);
    obj.public_len = public_len;
    return obj;
}

/// Fill `key` from the TPM hardware RNG (GetRandom returns <= 32 bytes per call).
fn fillFromTpm(tpm: Tpm, key: *[key_length]u8) !void {
    var off: usize = 0;
    while (off < key.len) {
        const want = @min(32, key.len - off);
        const got = try tpm.getRandom(key[off..][0..want]);
        if (got.len == 0) return Error.DeviceError;
        off += got.len;
    }
}
