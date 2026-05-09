const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const ECAM = @import("ECAM.zig");
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

    var ecams: std.ArrayList(ECAM) = try .initCapacity(innigkeit.mem.heap.allocator, base_allocations.len);
    defer ecams.deinit(innigkeit.mem.heap.allocator);
    errdefer for (ecams.items) |ecam| innigkeit.mem.heap.deallocateSpecial(ecam.config_space);

    for (mcfg.baseAllocations()) |base_allocation| {
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
            .config_space = try innigkeit.mem.heap.allocateSpecial(
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

    globals.ecams = try ecams.toOwnedSlice(innigkeit.mem.heap.allocator);
}
