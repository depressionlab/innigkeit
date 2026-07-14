//! TPM 2.0 driver: CRB transport (`Crb`) + command layer (`Tpm`).

const std = @import("std");

pub const Crb = @import("crb.zig");
pub const Tpm = @import("tpm.zig").Tpm;
pub const SealedObject = @import("tpm.zig").SealedObject;
pub const SessionType = @import("tpm.zig").SessionType;
pub const eventlog = @import("eventlog.zig");
pub const kdf = @import("kdf.zig");

const boot = @import("boot");
const innigkeit = @import("innigkeit");
const log = innigkeit.debug.log.scoped(.tpm);

/// OS-controlled PCR used for Innigkeit's own measurements (TCG PC Client
/// convention: PCR 11 is reserved for the OS/loader).
pub const boot_pcr = 11;

/// The full set of PCRs the at-rest disk key is sealed to: the firmware/
/// Secure-Boot-owned PCRs 0–7 (SRTM, platform config, option ROMs, boot manager,
/// and the PCR-7 Secure Boot policy) *plus* the OS-measured PCR 11.
/// A change to firmware, the Secure Boot policy, or the OS measurements all
/// break unseal, so a tampered or SB-disabled boot cannot recover the volume key.
pub const seal_pcrs = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, boot_pcr };

// Cached TPM singleton. `Crb.fromAcpi` maps the control area as device MMIO,
// which must happen exactly once for the lifetime of the kernel; callers
// (boot probe, every SecureVault creation, tests) go through `device()` so the
// mapping is shared rather than leaked per call.
var probe_lock: innigkeit.sync.TicketSpinLock = .{};
var probed = false;
var cached: ?Tpm = null;

/// The system TPM, or `null` if none is present/usable. Probes and maps the CRB
/// region on first call; cached thereafter. Safe under concurrent callers.
pub fn device() ?Tpm {
    probe_lock.lock();
    defer probe_lock.unlock();
    if (!probed) {
        cached = .fromAcpi();
        probed = true;
    }
    return cached;
}

/// Probe for a TPM during boot, log what was found, and start measured boot
/// by extending the root of trust into PCR 11. Non-fatal: a machine
/// without a (CRB) TPM simply boots without one. Later stages will
/// consume the device to back `SecureVault`.
pub fn init() void {
    const tpm = device() orelse {
        log.debug("no CRB TPM 2.0 device present", .{});
        return;
    };

    const manufacturer = tpm.getProperty(@import("tpm.zig").pt_manufacturer) catch |err| {
        log.warn("TPM present but GetCapability failed: {t}", .{err});
        return;
    };

    // The manufacturer property is four ASCII bytes, big-endian.
    const id = std.mem.toBytes(std.mem.nativeToBig(u32, manufacturer));
    log.info("TPM 2.0 present (CRB), manufacturer '{s}'", .{&id});

    // Measured boot: extend the OS-controlled root of trust into PCR 11.
    //
    //  1. the code-signing root key (app-integrity anchor), and
    //  2. the whole kernel executable image. Because the initfs is
    //     `@embedFile`'d into the kernel and `kernel_options`/config are comptime
    //     constants, the kernel image already contains the initfs and config,
    //     so this one measurement binds kernel code + initfs + config together.
    //
    // The firmware/bootloader stages are attested separately via PCRs 0–7
    // and PCR 11 is the OS's own measurement.
    measure(tpm, "codesign-root-key", &innigkeit.user.codesign.keys.default_public_key);
    if (boot.kernelExecutableFile()) |kernel_image| {
        measure(tpm, "kernel-image", kernel_image);
    } else {
        log.warn("no kernel executable file from bootloader; PCR{d} kernel measurement skipped", .{boot_pcr});
    }
}

/// Extend `SHA-256(data)` into the boot PCR, logging the labelled measurement.
/// Best-effort: a TPM error is logged, not fatal (a measurement failure must
/// not brick boot; the divergent PCR will simply fail a later seal/unseal).
pub fn measure(tpm: Tpm, label: []const u8, data: []const u8) void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    tpm.pcrExtend(boot_pcr, digest) catch |err| {
        log.warn("failed to measure '{s}' into PCR{d}: {t}", .{ label, boot_pcr, err });
        return;
    };
    log.info("measured '{s}' into PCR{d}", .{ label, boot_pcr });
}
