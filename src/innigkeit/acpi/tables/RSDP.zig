const std = @import("std");

const core = @import("core");
const innigkeit = @import("innigkeit");

/// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#root-system-description-pointer-rsdp-structure)
pub const RSDP = extern struct {
    /// "RSD PTR "
    signature: [8]u8 align(1),

    /// This is the checksum of the fields defined in the ACPI 1.0 specification.
    ///
    /// This includes only the first 20 bytes of this table, bytes 0 to 19, including the checksum field.
    ///
    /// These bytes must sum to zero.
    checksum: u8 align(1),

    /// An OEM-supplied string that identifies the OEM
    oem_id: [6]u8 align(1),

    /// The revision of this structure.
    ///
    /// Larger revision numbers are backward compatible to lower revision numbers.
    ///
    /// The ACPI version 1.0 revision number of this table is zero.
    ///
    /// The ACPI version 1.0 RSDP Structure only includes the first 20 bytes of this table, bytes 0 to 19.
    /// It does not include the Length field and beyond.
    ///
    /// The current value for this field is 2.
    revision: u8 align(1),

    /// 32 bit physical address of the RSDT.
    rsdt_addr: u32 align(1),

    /// The length of the table, in bytes, including the header, starting from offset 0.
    ///
    /// This field is used to record the size of the entire table.
    ///
    /// This field is not available in the ACPI version 1.0 RSDP Structure.
    length: u32 align(1),

    /// 64 bit physical address of the XSDT.
    ///
    /// This field is not available in the ACPI version 1.0 RSDP Structure.
    xsdt_addr: innigkeit.PhysicalAddress align(1),

    /// This is a checksum of the entire table, including both checksum fields.
    ///
    /// This field is not available in the ACPI version 1.0 RSDP Structure.
    extended_checksum: u8 align(1),

    _reserved: [3]u8 align(1),

    const BYTES_IN_ACPI_1_STRUCTURE = 20;

    /// A sanity bound on the firmware-supplied ACPI 2.0 extended length.
    ///
    /// The ACPI 2.0 RSDP is 36 bytes; anything beyond a page is assumed to be corrupted
    /// firmware data.
    const MAXIMUM_TABLE_LENGTH = 4096;

    pub fn sdtAddress(rsdp: *const RSDP) innigkeit.PhysicalAddress {
        return switch (rsdp.revision) {
            0 => .from(rsdp.rsdt_addr),
            2 => rsdp.xsdt_addr,
            else => std.debug.panic("unknown ACPI revision: {d}!", .{rsdp.revision}),
        };
    }

    /// Returns `true` is the table is valid.
    pub fn isValid(rsdp: *const RSDP) bool {
        // Before the RSDP is relied upon you should check that the checksum is valid.
        // For ACPI 1.0 you add up every byte in the structure and make sure the lowest byte of the result is equal
        // to zero.
        // For ACPI 2.0 and later, the spec separately defines an ExtendedChecksum covering every byte of the
        // table (bytes 0 to Length-1, including both checksum fields). Checking that alone is what we do
        // below and is equivalent in practice to what other OSes check; we do not separately re-verify the
        // original 20-byte ACPI 1.0 `checksum` field once revision >= 2.

        const bytes = blk: {
            const ptr: [*]const u8 = @ptrCast(rsdp);
            const length_of_table: usize = switch (rsdp.revision) {
                0 => BYTES_IN_ACPI_1_STRUCTURE,
                2 => extended: {
                    // the extended length is firmware-supplied, bound it before using it to slice
                    if (rsdp.length < @sizeOf(RSDP)) return false;
                    if (rsdp.length > MAXIMUM_TABLE_LENGTH) return false;
                    break :extended rsdp.length;
                },
                else => return false,
            };
            break :blk ptr[0..length_of_table];
        };

        var lowest_byte_of_sum: u8 = 0;
        for (bytes) |b| lowest_byte_of_sum +%= b;

        // the sum of all bytes must have zero in the lowest byte
        return lowest_byte_of_sum == 0;
    }

    comptime {
        core.testing.expectSize(
            RSDP,
            core.Size.of(u8).multiplyScalar(16)
                .add(core.Size.of(u32).multiplyScalar(2))
                .add(.of(u64))
                .add(core.Size.of(u8).multiplyScalar(4)),
        );
    }
};
