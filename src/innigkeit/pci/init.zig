const ECAM = @import("ECAM.zig");
const innigkeit = @import("innigkeit");
const std = @import("std");
const Function = @import("Function.zig").Function;
const globals = @import("globals.zig");

const DEVICES_PER_BUS = 32;
const FUNCTIONS_PER_DEVICE = 8;

const init_log = innigkeit.debug.log.scoped(.pci_init);
const MCFGAcpiTable = innigkeit.acpi.init.AcpiTable(innigkeit.acpi.tables.MCFG);

/// Initializes the PCI ECAM.
///
/// No-op if no MCFG table is found.
pub fn initializeECAM() !void {
    const mcfg_acpi_table = MCFGAcpiTable.get(0) orelse {
        init_log.warn("no MCFG table found - skipping PCI ECAM initialization", .{});
        return;
    };
    defer mcfg_acpi_table.deinit();
    const mcfg = mcfg_acpi_table.table;

    const base_allocations = mcfg.baseAllocations();

    var ecams: std.ArrayList(ECAM) = try .initCapacity(innigkeit.memory.heap.allocator, base_allocations.len);
    defer ecams.deinit(innigkeit.memory.heap.allocator);
    errdefer for (ecams.items) |ecam| innigkeit.memory.heap.deallocateSpecial(ecam.config_space);

    for (mcfg.baseAllocations()) |base_allocation| {
        // end_pci_bus/start_pci_bus come straight from the firmware-supplied
        // MCFG table; a malformed entry with end < start would otherwise
        // underflow this subtraction (u8 - u8) and panic.
        if (base_allocation.end_pci_bus < base_allocation.start_pci_bus) {
            init_log.warn("MCFG: malformed base allocation (start_bus={} > end_bus={}), skipping", .{
                base_allocation.start_pci_bus, base_allocation.end_pci_bus,
            });
            continue;
        }

        const ecam = ecams.addOneAssumeCapacity();

        const number_of_buses = base_allocation.end_pci_bus - base_allocation.start_pci_bus;

        const ecam_config_space_physical_range: innigkeit.PhysicalRange = .from(
            base_allocation.base_address,
            Function.enhanced_configuration_space_size
                .multiplyScalar(FUNCTIONS_PER_DEVICE)
                .multiplyScalar(DEVICES_PER_BUS)
                .multiplyScalar(number_of_buses),
        );

        ecam.* = .{
            .start_bus = base_allocation.start_pci_bus,
            .end_bus = base_allocation.end_pci_bus,
            .segment_group = base_allocation.segment_group,
            .config_space = try innigkeit.memory.heap.allocateSpecial(
                .{
                    .physical_range = ecam_config_space_physical_range,
                    .protection = .{ .read = true, .write = true },
                    .cache = .uncached,
                },
            ),
        };

        init_log.debug("found ECAM - segment group: {} - start bus: {} - end bus: {} @ {f}", .{
            ecam.segment_group,
            ecam.start_bus,
            ecam.end_bus,
            ecam_config_space_physical_range,
        });
    }

    globals.ecams = try ecams.toOwnedSlice(innigkeit.memory.heap.allocator);
}
