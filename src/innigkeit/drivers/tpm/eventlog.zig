//! TCG firmware measurement (event) log.
//!
//! The platform firmware records every pre-OS measurement it extends into the
//! TPM in the TCG event log. The bootloader captures it via
//! kernel a buffer that survives ExitBootServices. Replaying it reproduces the
//! firmware-owned PCRs, letting the OS attest what ran before it.
//!
//! Lifetime: Limine's buffer lives in *bootloader-reclaimable* memory, and its
//! later pages are not guaranteed to stay mapped once the kernel builds its own
//! direct map / reclaims that memory. So `capture()` copies it into kernel BSS
//! very early in stage1 (on Limine's page tables, before any reclaim); all later
//! consumers use that copy via `locate()`.
//!
//! Format: TCG PC Client Platform Firmware Profile, "crypto-agile" log: the
//! first record is a legacy `TCG_PCClientPCREvent` whose event data is the
//! `Spec ID Event03` structure, and every later record is a `TCG_PCR_EVENT2`.

const boot = @import("boot");
const innigkeit = @import("innigkeit");
const std = @import("std");
const log = innigkeit.debug.log.scoped(.tpm_event_log);

/// The "Spec ID Event03" signature that opens a crypto-agile log (16 bytes,
/// NUL-padded).
pub const spec_id_signature = "Spec ID Event03\x00";

pub const EventLog = boot.TpmEventLog;

/// Kernel-owned copy of the log. 32 KiB covers realistic firmware logs (QEMU's
/// is ~7 KiB; the PFP minimum log area is 64 KiB but is rarely filled).
var capture_buffer: [32 * 1024]u8 = undefined;
var captured: ?EventLog = null;

/// Copy the bootloader's TCG event log into kernel memory. Call ONCE, early in
/// stage1, before the bootloader-reclaimable memory it lives in can be reused
/// and while Limine's full HHDM mapping is still active. A no-op when there is
/// no log (no TPM / no EFI_TCG2_PROTOCOL / capture failed) or it is too large.
pub fn capture() void {
    const elog = boot.tpmEventLog() orelse return;
    if (elog.bytes.len == 0) return;
    if (elog.bytes.len > capture_buffer.len) {
        log.warn("TCG event log ({d} bytes) exceeds capture buffer; ignoring", .{elog.bytes.len});
        return;
    }
    @memcpy(capture_buffer[0..elog.bytes.len], elog.bytes);
    captured = .{ .bytes = capture_buffer[0..elog.bytes.len], .format = elog.format };
}

/// The captured firmware TCG event log, or `null` if none was captured.
pub fn locate() ?EventLog {
    return captured;
}

pub const ParseError = error{Malformed};

const Sha256 = std.crypto.hash.sha2.Sha256;
const alg_sha256: u16 = 0x000B;
const ev_no_action: u32 = 0x0000_0003;
/// `EV_EFI_VARIABLE_DRIVER_CONFIG`: the firmware measures the Secure Boot policy
/// variables (SecureBoot, PK, KEK, db, dbx) into PCR 7 with this event type.
const ev_efi_variable_driver_config: u32 = 0x8000_0001;
/// PCR 7 records the Secure Boot policy (TCG PC Client PFP).
const secure_boot_pcr: u32 = 7;

/// TPM_ALG digest sizes (bytes) for the algorithms a crypto-agile log may use.
fn digestSize(alg: u16) ?usize {
    return switch (alg) {
        0x0004 => 20, // SHA1
        0x000B => 32, // SHA256
        0x000C => 48, // SHA384
        0x000D => 64, // SHA512
        0x0012 => 32, // SM3_256
        else => null,
    };
}

/// One parsed crypto-agile record (`TCG_PCR_EVENT2`).
pub const Record = struct {
    pcr_index: u32,
    event_type: u32,
    /// The record's SHA-256 digest, if that bank is present.
    sha256: ?[]const u8,
    /// The event data payload.
    event: []const u8,
};

/// Iterator over the crypto-agile records, past the legacy record 0. TCG
/// event-log integers are little-endian (unlike TPM command structures).
pub const RecordIterator = struct {
    b: []const u8,
    p: usize,

    pub fn next(self: *RecordIterator) ParseError!?Record {
        const b = self.b;
        if (self.p + 8 > b.len) return null;
        const idx = try readU32(b, self.p);
        const event_type = try readU32(b, self.p + 4);
        var q = self.p + 8;

        // TPML_DIGEST_VALUES: count(4) || count × (alg(2) || digest[size]).
        const count = try readU32(b, q);
        q += 4;
        var sha256: ?[]const u8 = null;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const alg = try readU16(b, q);
            q += 2;
            const size = digestSize(alg) orelse return ParseError.Malformed;
            if (q + size > b.len) return ParseError.Malformed;
            if (alg == alg_sha256) sha256 = b[q..][0..size];
            q += size;
        }

        const event_size = try readU32(b, q);
        q += 4;
        if (q + event_size > b.len) return ParseError.Malformed;
        const event = b[q..][0..event_size];
        q += event_size;

        self.p = q;
        return .{
            .pcr_index = idx,
            .event_type = event_type,
            .sha256 = sha256,
            .event = event,
        };
    }
};

/// Start iterating the crypto-agile records after the legacy record 0
/// (`TCG_PCClientPCREvent`: pcrIndex(4) || eventType(4) || digest[20] ||
/// eventSize(4) || event[eventSize], itself EV_NO_ACTION and not extended).
pub fn records(elog: EventLog) ParseError!RecordIterator {
    const b = elog.bytes;
    if (b.len < 32) return ParseError.Malformed;
    return .{ .b = b, .p = 32 + try readU32(b, 28) };
}

/// Replay the log's SHA-256 measurements for `pcr_index` and return the folded
/// PCR value (`PCR_new = SHA256(PCR_old || digest)`, starting from zero as PCRs
/// 0..16 do). `EV_NO_ACTION` records (e.g. the Spec ID event) are not extended,
/// per the PC Client PFP. Reproduces the firmware-owned PCR so it can be checked
/// against a live `PCR_Read`.
pub fn replaySha256Pcr(elog: EventLog, pcr_index: u32) ParseError![Sha256.digest_length]u8 {
    var pcr = [_]u8{0} ** Sha256.digest_length;
    var it = try records(elog);
    while (try it.next()) |rec| {
        if (rec.pcr_index == pcr_index and rec.event_type != ev_no_action) {
            const digest = rec.sha256 orelse return ParseError.Malformed;
            var h = Sha256.init(.{});
            h.update(&pcr);
            h.update(digest);
            h.final(&pcr);
        }
    }
    return pcr;
}

/// The UEFI Secure Boot state as *measured by the firmware* into PCR 7:
/// `true` = enabled, `false` = disabled, `null` = the `SecureBoot` variable was
/// not measured in this log (e.g. firmware without Secure Boot support).
///
/// This reads the firmware's own measured value of the `SecureBoot` EFI variable
/// (an EV_EFI_VARIABLE_DRIVER_CONFIG event): no live EFI runtime-services call,
/// so no firmware-code mapping hazard, and the answer is attested by PCR 7 (to
/// which the disk key is already sealed, so a lie about the SB state would change
/// PCR 7 and break unseal anyway). Trust-equivalent to a live `GetVariable`,
/// strictly safer.
pub fn secureBootEnabled(elog: EventLog) ParseError!?bool {
    var it = try records(elog);
    while (try it.next()) |rec| {
        if (rec.pcr_index != secure_boot_pcr) continue;
        if (rec.event_type != ev_efi_variable_driver_config) continue;
        const value = parseVariableData(rec.event, "SecureBoot") orelse continue;
        if (value.len < 1) continue;
        return value[0] != 0;
    }
    return null;
}

/// If `event` is a UEFI_VARIABLE_DATA whose UnicodeName equals `ascii_name`,
/// return its VariableData bytes. Layout (little-endian): VariableName
/// EFI_GUID[16] || UnicodeNameLength(u64, CHAR16 count) || VariableDataLength(u64)
/// || UnicodeName[CHAR16 × len] || VariableData[bytes].
fn parseVariableData(event: []const u8, ascii_name: []const u8) ?[]const u8 {
    if (event.len < 16 + 8 + 8) return null;
    const name_len = std.mem.readInt(u64, event[16..][0..8], .little);
    const data_len = std.mem.readInt(u64, event[24..][0..8], .little);
    // Bound both lengths against the event before any arithmetic (garbage-safe).
    if (name_len > event.len or data_len > event.len) return null;
    if (name_len != ascii_name.len) return null;
    const name_bytes = name_len * 2;
    const data_off = 32 + name_bytes;
    if (data_off + data_len > event.len) return null;
    // Compare the UTF-16LE UnicodeName against the ASCII name.
    for (ascii_name, 0..) |ch, i| {
        if (event[32 + i * 2] != ch or event[32 + i * 2 + 1] != 0) return null;
    }
    return event[data_off..][0..@intCast(data_len)];
}

fn readU32(b: []const u8, off: usize) ParseError!u32 {
    if (off + 4 > b.len) return ParseError.Malformed;
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn readU16(b: []const u8, off: usize) ParseError!u16 {
    if (off + 2 > b.len) return ParseError.Malformed;
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
