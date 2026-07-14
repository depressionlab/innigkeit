const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

const HPETAcpiTable = innigkeit.acpi.init.AcpiTable(innigkeit.acpi.tables.HPET);
const init_log = innigkeit.debug.log.scoped(.hpet_init);

const globals = @import("globals.zig");
const Hpet = @import("Hpet.zig");

pub fn registerTimeSource(candidate_time_sources: *innigkeit.time.init.CandidateTimeSources) void {
    const hpet_acpi_table = HPETAcpiTable.get(0) orelse return;
    hpet_acpi_table.deinit(); // immediately deinitialize the table as we only need to check if it exists

    candidate_time_sources.addTimeSource(.{
        .name = "hpet",
        .priority = 100,
        .initialization = .{ .simple = initializeHPET },
        .reference_counter = .{
            .prepareToWaitForFn = referenceCounterPrepareToWaitFor,
            .waitForFn = referenceCounterWaitFor,
        },
    });
}

fn initializeHPET() void {
    globals.hpet = .{
        .base = getHpetBase() catch |err|
            std.debug.panic("failed to get hpet base: {}!", .{err}),
    };
    init_log.debug("using hpet: {}", .{globals.hpet});

    const general_capabilities = globals.hpet.readGeneralCapabilitiesAndIDRegister();

    init_log.debug("counter is 64-bit: {}", .{general_capabilities.counter_is_64bit});

    globals.number_of_timers_minus_one = general_capabilities.number_of_timers_minus_one;

    globals.tick_duration_fs = general_capabilities.counter_tick_period_fs;
    init_log.debug("tick duration (fs): {}", .{globals.tick_duration_fs});

    var general_configuration = globals.hpet.readGeneralConfigurationRegister();
    general_configuration.enable = false;
    general_configuration.legacy_routing_enable = false;
    globals.hpet.writeGeneralConfigurationRegister(general_configuration);

    globals.hpet.writeCounterRegister(0);
}

fn referenceCounterPrepareToWaitFor(duration: core.Duration) void {
    _ = duration;

    var general_configuration = globals.hpet.readGeneralConfigurationRegister();
    general_configuration.enable = false;
    globals.hpet.writeGeneralConfigurationRegister(general_configuration);

    globals.hpet.writeCounterRegister(0);

    general_configuration.enable = true;
    globals.hpet.writeGeneralConfigurationRegister(general_configuration);
}

fn referenceCounterWaitFor(duration: core.Duration) void {
    const duration_ticks = ((duration.value * innigkeit.time.fs_per_ns) / globals.tick_duration_fs);

    const current_value = globals.hpet.readCounterRegister();

    const target_value = current_value + duration_ticks;

    while (globals.hpet.readCounterRegister() < target_value) {
        architecture.spinLoopHint();
    }
}

fn getHpetBase() ![*]volatile u64 {
    const hpet_acpi_table = HPETAcpiTable.get(0) orelse {
        // the table is known to exist as it is checked in `registerTimeSource`
        @panic("hpet table missing!");
    };
    defer hpet_acpi_table.deinit();
    const hpet = hpet_acpi_table.table;

    if (hpet.base_address.address_space != .memory) @panic("HPET base address is not memory mapped!");

    const register_region_range = try innigkeit.memory.heap.allocateSpecial(
        .{
            .physical_range = .from(
                .from(hpet.base_address.address),
                Hpet.register_region_size,
            ),
            .protection = .{ .read = true, .write = true },
            .cache = .uncached,
        },
    );

    return register_region_range.address.toPtr([*]volatile u64);
}
