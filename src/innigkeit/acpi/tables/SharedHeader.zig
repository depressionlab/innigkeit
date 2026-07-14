const std = @import("std");

const core = @import("core");

/// All system description tables begin with this structure.
///
/// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#system-description-table-header)
pub const SharedHeader = extern struct {
    /// The ASCII string representation of the table identifier.
    ///
    /// Note that if OSPM finds a signature in a table that is not listed in the ACPI specification,
    /// then OSPM ignores the entire table (it is not loaded into ACPI namespace);
    /// OSPM ignores the table even though the values in the Length and Checksum fields are correct.
    signature: [4]u8 align(1),

    /// The length of the table, in bytes, including the header, starting from offset 0.
    ///
    /// This field is used to record the size of the entire table.
    length: u32 align(1),

    /// The revision of the structure corresponding to the signature field for this table.
    ///
    /// Larger revision numbers are backward compatible to lower revision numbers with the same signature.
    revision: u8,

    /// The entire table, including the checksum field, must add to zero to be considered valid.
    checksum: u8,

    /// An OEM-supplied string that identifies the OEM.
    oem_id: [6]u8 align(1),

    /// An OEM-supplied string that the OEM uses to identify the particular data table.
    ///
    /// This field is particularly useful when defining a definition block to distinguish definition block functions.
    ///
    /// The OEM assigns each dissimilar table a new OEM Table ID.
    oem_table_id: [8]u8 align(1),

    /// An OEM-supplied revision number.
    ///
    /// Larger numbers are assumed to be newer revisions.
    oem_revision: u32 align(1),

    /// Vendor ID of utility that created the table.
    ///
    /// For tables containing Definition Blocks, this is the ID for the ASL Compiler.
    creator_id: u32 align(1),

    /// Revision of utility that created the table.
    ///
    /// For tables containing Definition Blocks, this is the revision for the ASL Compiler.
    creator_revision: u32 align(1),

    pub fn signatureIs(shared_header: *const SharedHeader, signature: *const [4]u8) bool {
        return std.mem.eql(u8, signature, &shared_header.signature);
    }

    pub fn signatureAsString(shared_header: *const SharedHeader) []const u8 {
        return std.mem.asBytes(&shared_header.signature);
    }

    /// A sanity bound on the firmware-supplied table length.
    ///
    /// No real system description table comes anywhere near this size; anything larger is
    /// assumed to be corrupted firmware data.
    pub const MAXIMUM_TABLE_LENGTH = core.Size.from(4, .mib); // 4 MiB

    /// Returns `true` is the table is valid.
    pub fn isValid(shared_header: *const SharedHeader) bool {
        // the length is firmware-supplied, bound it before using it to slice
        if (shared_header.length < @sizeOf(SharedHeader)) return false;
        if (MAXIMUM_TABLE_LENGTH.lessThan(.from(shared_header.length, .byte))) return false;

        const bytes = blk: {
            const ptr: [*]const u8 = @ptrCast(shared_header);
            break :blk ptr[0..shared_header.length];
        };

        var lowest_byte_of_sum: u8 = 0;
        for (bytes) |b| lowest_byte_of_sum +%= b;

        // the sum of all bytes must have zero in the lowest byte
        return lowest_byte_of_sum == 0;
    }

    comptime {
        core.testing.expectSize(
            SharedHeader,

            core.Size.of(u8).multiplyScalar(4)
                .add(.of(u32))
                .add(core.Size.of(u8).multiplyScalar(16))
                .add(core.Size.of(u32).multiplyScalar(3)),
        );
    }
};

test "fuzz: SharedHeader.isValid never panics or reads out of bounds" {
    try std.testing.fuzz({}, fuzzIsValid, .{});
}

fn fuzzIsValid(context: void, smith: *std.testing.Smith) !void {
    _ = context;

    var buf: [128]u8 align(@alignOf(SharedHeader)) = undefined;
    smith.bytes(&buf);

    // isValid() trusts the caller to guarantee `length` bytes are actually
    // available starting at the header's own address (that's the
    // real-world precondition, that a table is always parsed from a buffer
    // already sized to its own claimed length). Clamp the fuzzed length to
    // this harness's buffer so the harness itself never reads out of
    // bounds; the property under test is that isValid() never panics for
    // any byte content once that precondition holds.
    const header: *SharedHeader = @ptrCast(&buf);
    header.length = @min(header.length, buf.len);

    _ = header.isValid();
}
