const boot = @import("boot");
const innigkeit = @import("innigkeit");
const limine = @import("limine/interface.zig");
const std = @import("std");

pub const MemoryMap = union {
    unknown: void,
    limine: limine.MemoryMapIterator,

    pub fn next(self: *MemoryMap) ?Entry {
        return switch (boot.bootloader_api) {
            .limine => self.limine.next(),
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

            pub fn isUsableForAllocation(self: MemoryMap.Entry.Type) bool {
                return switch (self) {
                    .free, .in_use, .bootloader_reclaimable, .acpi_reclaimable => true,
                    .framebuffer, .acpi_nvs, .reserved, .unusable, .unknown, .reserved_mapped => false,
                };
            }
        };

        pub inline fn format(self: MemoryMap.Entry, writer: *std.Io.Writer) !void {
            try writer.print("{t} - {f}", .{ self.type, self.range });
        }
    };
};
