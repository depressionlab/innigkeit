const std = @import("std");
const innigkeit = @import("innigkeit");
const limine = @import("limine/interface.zig");
const boot = @import("boot");

pub const MemoryMap = union {
    unknown: void,
    limine: limine.MemoryMapIterator,

    pub fn next(memory_map: *MemoryMap) ?Entry {
        return switch (boot.bootloader_api) {
            .limine => memory_map.limine.next(),
            .unknown => null,
        };
    }

    /// An entry in the memory map provided by the bootloader.
    pub const Entry = struct {
        range: innigkeit.PhysicalRange,
        type: Type,

        pub const Type = enum {
            free,
            in_use,
            reserved,
            bootloader_reclaimable,
            acpi_reclaimable,
            acpi_nvs,
            framebuffer,
            reserved_mapped,

            unusable,
            unknown,

            pub fn isUsableForAllocation(entry_type: Type) bool {
                return switch (entry_type) {
                    .free, .in_use, .bootloader_reclaimable, .acpi_reclaimable => true,
                    .framebuffer, .acpi_nvs, .reserved, .unusable, .unknown, .reserved_mapped => false,
                };
            }
        };

        pub inline fn format(entry: Entry, writer: *std.Io.Writer) !void {
            try writer.print("{t} - {f}", .{ entry.type, entry.range });
        }
    };
};
