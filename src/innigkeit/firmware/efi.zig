//! UEFI System Table access.
//!
//! Limine hands us the EFI System Table address (`boot.efiSystemTable()`) and
//! leaves EFI Runtime Services callable after ExitBootServices *without* calling
//! `SetVirtualAddressMap`, so the pointers inside the table are physical and the
//! runtime code stays at its physical address. We reach the (data) tables
//! through the kernel direct map.
//!
//! This module currently reads the table read-only: validate the
//! signatures and expose the Runtime Services table. Calling a runtime-services
//! function (e.g. `GetVariable` for the `SecureBoot` variable) needs the
//! EFI runtime *code* region mapped executable against the kernel's W^X direct
//! map first, and is done separately.

const boot = @import("boot");
const innigkeit = @import("innigkeit");
const log = innigkeit.debug.log.scoped(.efi);

/// "IBI SYST": EFI_SYSTEM_TABLE_SIGNATURE.
const system_table_signature: u64 = 0x5453_5953_2049_4249;
/// "RUNTSERV": EFI_RUNTIME_SERVICES_SIGNATURE.
const runtime_services_signature: u64 = 0x5652_4553_544E_5552;

/// EFI_TABLE_HEADER (UEFI 2.x, §4.2).
pub const TableHeader = extern struct {
    signature: u64,
    revision: u32,
    header_size: u32,
    crc32: u32,
    reserved: u32,
};

/// EFI_SYSTEM_TABLE (UEFI §4.3). Pointers are held as `u64` (physical addresses
/// under Limine) and dereferenced through the direct map, never called directly.
pub const SystemTable = extern struct {
    hdr: TableHeader,
    firmware_vendor: u64, // CHAR16*
    firmware_revision: u32,
    console_in_handle: u64,
    con_in: u64,
    console_out_handle: u64,
    con_out: u64,
    standard_error_handle: u64,
    std_err: u64,
    runtime_services: u64, // EFI_RUNTIME_SERVICES*
    boot_services: u64,
    number_of_table_entries: u64,
    configuration_table: u64,
};

/// EFI_RUNTIME_SERVICES (UEFI §4.5): only the header is read here; the function
/// pointers (GetVariable at index 6) are used later on.
pub const RuntimeServices = extern struct {
    hdr: TableHeader,
    get_time: u64,
    set_time: u64,
    get_wakeup_time: u64,
    set_wakeup_time: u64,
    set_virtual_address_map: u64,
    convert_pointer: u64,
    get_variable: u64,
    get_next_variable_name: u64,
    set_variable: u64,
    get_next_high_monotonic_count: u64,
    reset_system: u64,
};

/// Cached, validated System Table (set by `init`), or null when we are not on an
/// EFI platform or the table failed validation.
var system_table: ?*const SystemTable = null;

/// Dereference a physical address (as reported inside EFI tables) via the kernel
/// direct map.
fn physPtr(comptime T: type, phys: u64) *const T {
    const pa: innigkeit.PhysicalAddress = .{ .value = phys };
    return pa.toDirectMap().toPtr(*const T);
}

/// Resolve the bootloader-reported System Table address to a direct-map pointer.
fn systemTablePtr() ?*const SystemTable {
    const addr = boot.efiSystemTable() orelse return null;
    return switch (addr) {
        .physical => |p| p.toDirectMap().toPtr(*const SystemTable),
        .virtual => |v| v.toPtr(*const SystemTable),
    };
}

/// Probe and validate the EFI System Table, logging the firmware type, vendor
/// revision, and Runtime Services revision. Read-only and best-effort: any
/// inconsistency is logged and leaves `system_table` null rather than trusting a
/// bad table.
pub fn init() void {
    if (boot.firmwareType()) |ft| log.debug("firmware type: {t}", .{ft});

    const st = systemTablePtr() orelse {
        log.debug("no EFI system table from bootloader", .{});
        return;
    };

    if (st.hdr.signature != system_table_signature) {
        log.warn("EFI system table signature mismatch: {x}", .{st.hdr.signature});
        return;
    }

    const rs = physPtr(RuntimeServices, st.runtime_services);
    if (rs.hdr.signature != runtime_services_signature) {
        log.warn("EFI runtime services signature mismatch: {x}", .{rs.hdr.signature});
        return;
    }

    system_table = st;
    log.info(
        "EFI system table ok (rev {x}, firmware rev {x}, runtime services rev {x})",
        .{ st.hdr.revision, st.firmware_revision, rs.hdr.revision },
    );
}

/// The validated EFI System Table, if present.
pub fn systemTable() ?*const SystemTable {
    return system_table;
}

/// The EFI Runtime Services table, if the System Table was validated.
pub fn runtimeServices() ?*const RuntimeServices {
    const st = system_table orelse return null;
    return physPtr(RuntimeServices, st.runtime_services);
}
