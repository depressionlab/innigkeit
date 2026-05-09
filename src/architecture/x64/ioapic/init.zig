const innigkeit = @import("innigkeit");
const IOAPIC = @import("IOAPIC.zig");
const globals = @import("globals.zig");
const SourceOverride = @import("SourceOverride.zig");

const init_log = innigkeit.debug.log.scoped(.ioapic_init);

pub fn captureMADTInformation(madt: *const innigkeit.acpi.tables.MADT) !void {
    var iter = madt.iterate();

    while (iter.next()) |entry| {
        switch (entry.entry_type) {
            .io_apic => {
                const io_apic_data = entry.specific.io_apic;

                const register_region_range = try innigkeit.mem.heap.allocateSpecial(
                    .{
                        .physical_range = .from(
                            .from(io_apic_data.ioapic_address),
                            IOAPIC.register_region_size,
                        ),
                        .protection = .{ .read = true, .write = true },
                        .cache = .uncached,
                    },
                );

                const ioapic = IOAPIC.init(
                    register_region_range.address,
                    io_apic_data.global_system_interrupt_base,
                );

                init_log.debug("found ioapic for gsi {}-{}", .{
                    ioapic.gsi_base,
                    ioapic.gsi_base + ioapic.number_of_redirection_entries,
                });

                try globals.io_apics.append(ioapic);
            },
            .interrupt_source_override => {
                const madt_iso = entry.specific.interrupt_source_override;
                const source_override: SourceOverride = .fromMADT(madt_iso);
                globals.source_overrides[madt_iso.source] = source_override;
                init_log.debug("found irq {} has {f}", .{ madt_iso.source, source_override });
            },
            else => continue,
        }
    }

    // sort the io apics by gsi base
    @import("std").mem.sort(
        IOAPIC,
        globals.io_apics.slice(),
        {},
        struct {
            fn lessThan(_: void, lhs: IOAPIC, rhs: IOAPIC) bool {
                return lhs.gsi_base < rhs.gsi_base;
            }
        }.lessThan,
    );
}
