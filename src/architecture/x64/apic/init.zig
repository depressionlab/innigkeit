const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const x64 = @import("../x64.zig");
const globals = @import("globals.zig");
const LAPIC = @import("LAPIC.zig").LAPIC;

const init_log = innigkeit.debug.log.scoped(.apic_init);

pub fn captureApicInformation(
    fadt: *const innigkeit.acpi.tables.FADT,
    madt: *const innigkeit.acpi.tables.MADT,
    x2apic_enabled: bool,
) !void {
    if (x2apic_enabled) {
        globals.lapic = .x2apic;
    } else {
        const register_space_range = try innigkeit.mem.heap.allocateSpecial(
            .{
                .physical_range = .from(
                    .from(madt.local_interrupt_controller_address),
                    LAPIC.Register.register_space_size,
                ),
                .protection = .{ .read = true, .write = true },
                .cache = .uncached,
            },
        );

        globals.lapic = .{
            .xapic = register_space_range.address.toPtr([*]volatile u8),
        };
    }

    init_log.debug("lapic in mode: {t}", .{globals.lapic});

    if (fadt.fixed_feature_flags.FORCE_APIC_PHYSICAL_DESTINATION_MODE) {
        @panic("physical destination mode is forced!");
    }
}

pub fn initApicOnCurrentExecutor() void {
    var spurious_interrupt_register = globals.lapic.readSupriousInterruptRegister();

    spurious_interrupt_register.apic_enable = true;
    spurious_interrupt_register.spurious_vector = .spurious_interrupt;

    globals.lapic.writeSupriousInterruptRegister(spurious_interrupt_register);

    // TODO: task priority
    // TODO: error interrupt
}

pub fn registerTimeSource(
    candidate_time_sources: *innigkeit.time.init.CandidateTimeSources,
) void {
    candidate_time_sources.addTimeSource(.{
        .name = "lapic",
        .priority = 150,
        .initialization = if (x64.info.lapic_base_tick_duration_fs != null)
            .{ .simple = initializeLapicTimer }
        else
            .{ .calibration_required = initializeLapicTimerCalibrate },
        .per_executor_periodic = .{
            .enableInterruptFn = perExecutorPeriodicEnableInterrupt,
        },
    });
}

const divide_configuration: LAPIC.DivideConfigurationRegister = .@"2";

fn initializeLapicTimer() void {
    std.debug.assert(x64.info.lapic_base_tick_duration_fs != null);

    globals.tick_duration_fs = x64.info.lapic_base_tick_duration_fs.? * divide_configuration.toInt();
    init_log.debug("tick duration (fs) from cpuid: {}", .{globals.tick_duration_fs});
}

fn initializeLapicTimerCalibrate(
    reference_counter: innigkeit.time.init.ReferenceCounter,
) void {
    globals.lapic.writeDivideConfigurationRegister(divide_configuration);

    {
        var lvt_timer_register = globals.lapic.readLVTTimerRegister();

        lvt_timer_register.vector = .debug; // interrupt is masked so it doesnt matter what the vector is set to
        lvt_timer_register.timer_mode = .oneshot;
        lvt_timer_register.masked = true;

        globals.lapic.writeLVTTimerRegister(lvt_timer_register);
    }

    // warmup
    {
        const warmup_duration = core.Duration.from(1, .millisecond);
        const number_of_warmups = 5;

        var total_warmup_ticks: u64 = 0;

        for (0..number_of_warmups) |_| {
            reference_counter.prepareToWaitFor(warmup_duration);

            globals.lapic.writeInitialCountRegister(std.math.maxInt(u32));
            reference_counter.waitFor(warmup_duration);
            const end = globals.lapic.readCurrentCountRegister();
            globals.lapic.writeInitialCountRegister(0);

            total_warmup_ticks += std.math.maxInt(u32) - end;
        }

        std.mem.doNotOptimizeAway(&total_warmup_ticks);
    }

    const sample_duration = core.Duration.from(5, .millisecond);
    const number_of_samples = 5;
    var total_ticks: u64 = 0;

    for (0..number_of_samples) |_| {
        reference_counter.prepareToWaitFor(sample_duration);

        globals.lapic.writeInitialCountRegister(std.math.maxInt(u32));
        reference_counter.waitFor(sample_duration);
        const end = globals.lapic.readCurrentCountRegister();
        globals.lapic.writeInitialCountRegister(0);

        total_ticks += std.math.maxInt(u32) - end;
    }

    const average_ticks = total_ticks / number_of_samples;

    globals.tick_duration_fs = (sample_duration.value * innigkeit.time.fs_per_ns) / average_ticks;
    init_log.debug("tick duration (fs) using reference counter: {}", .{globals.tick_duration_fs});
}

fn perExecutorPeriodicEnableInterrupt(period: core.Duration) void {
    globals.lapic.writeInitialCountRegister(0);
    globals.lapic.writeDivideConfigurationRegister(divide_configuration);

    {
        var lvt_timer_register = globals.lapic.readLVTTimerRegister();

        lvt_timer_register.vector = .per_executor_periodic;
        lvt_timer_register.timer_mode = .periodic;
        lvt_timer_register.masked = false;

        globals.lapic.writeLVTTimerRegister(lvt_timer_register);
    }

    const ticks = std.math.cast(
        u32,
        (period.value * innigkeit.time.fs_per_ns) / globals.tick_duration_fs,
    ) orelse @panic("period is too long!");

    globals.lapic.writeInitialCountRegister(ticks);
}
