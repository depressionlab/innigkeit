//! Memory Map Feature
//!
//! For base revisions <= 2, memory between 0 and 0x1000 is never marked as usable memory.
//!
//! The entries are guaranteed to be sorted by base address, lowest to highest.
//!
//! Usable and bootloader reclaimable entries are guaranteed to be 4096 byte aligned for both base and length.
//!
//! Usable and bootloader reclaimable entries are guaranteed not to overlap with any other entry.
//!
//! To the contrary, all non-usable entries (including executable/modules) are not guaranteed any alignment, nor is it guaranteed that they
//! do not overlap other entries.

const core = @import("core");
const innigkeit = @import("innigkeit");
const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x67CF3D9D378A806F, 0xE304ACDFC50C3C62),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,
    _entry_count: u64,
    _entries: [*]const *const Entry,

    pub fn entries(self: *const Response) []const *const Entry {
        return self._entries[0..self._entry_count];
    }

    pub fn print(self: *const Response, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("Memmap{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("entries:\n");

        for (self.entries()) |entry| {
            try writer.splatByteAll(' ', new_indent + 2);
            try writer.print("{f}\n", .{entry});
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const Response, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};

pub const Entry = extern struct {
    /// Physical address of the base of the memory section
    base: innigkeit.PhysicalAddress,

    /// Length of the memory section
    length: core.Size,

    type: Type,

    pub const Type = enum(u64) {
        /// A region of the address space that is usable RAM, and does not contain other data, the executable, bootloader information,
        /// or anything valuable, and is therefore free for use.
        usable = 0,

        /// A region of the address space that are reserved for unspecified purposes by the firmware, hardware, or otherwise, and
        /// should not be touched by the executable.
        reserved = 1,

        /// A region of the address space containing ACPI related data, such as ACPI tables and AML code.
        ///
        /// The executable should make absolutely sure that no data contained in these regions is still needed before deciding to
        /// reclaim these memory regions for itself.
        ///
        /// Refer to the ACPI specification for further information.
        acpi_reclaimable = 2,

        /// A region of the address space used for ACPI non-volatile data storage.
        ///
        /// Refer to the ACPI specification for further information.
        acpi_nvs = 3,

        /// A region of the address space that contains bad RAM, which may be unreliable, and therefore these regions should be treated
        /// the same as reserved regions.
        bad_memory = 4,

        /// A region of the address space containing RAM used to store bootloader or firmware information that should be available to
        /// the executable (or, in some cases, hardware, such as for MP trampolines).
        ///
        /// The executable should make absolutely sure that no data contained in these regions is still needed before deciding to
        /// reclaim these memory regions for itself.
        bootloader_reclaimable = 5,

        /// An entry that is meant to have an illustrative purpose only, and are not authoritative sources to be used as a means to find
        /// the addresses of the executable or modules.
        ///
        /// One must use the specific Limine features (executable address and module features) to do that.
        executable_and_modules = 6,

        /// A region of the address space containing memory-mapped framebuffers.
        ///
        /// These entries exist for illustrative purposes only, and are not to be used to acquire the address of any framebuffer.
        ///
        /// One must use the framebuffer feature for that.
        framebuffer = 7,

        /// A region of the address space containing ACPI tables, if the firmware did not already map them within either the ACPI
        /// reclaimable or an ACPI NVS region.
        ///
        /// For base revision 5 or greater, these entries additionally contain SMBIOS tables, EFI Runtime Services code and data, and
        /// the EFI system table along with the data it references.
        ///
        /// Base revision 4 or greater.
        reserved_mapped = 8,

        _,
    };

    pub inline fn format(self: *const Entry, writer: *std.Io.Writer) !void {
        try writer.print("Entry({f} - {f} - {t})", .{ self.base, self.length, self.type });
    }
};
