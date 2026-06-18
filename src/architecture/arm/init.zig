//! AArch64 boot-time initialization hooks.
//!
//! These implement the `architecture.init` and time-source slots for the
//! single-executor M1 bring-up. The ARM Generic Timer (CNTPCT/CNTVCT) backs
//! the reference counter, the wallclock, and the per-executor periodic
//! scheduler tick; the GICv2 routes the virtual-timer PPI (IRQ 27).

const std = @import("std");

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

const arm = @import("arm.zig");

const log = innigkeit.debug.log.scoped(.arm_init);

/// Set up a non-bootstrap executor's arch-specific state.
pub fn prepareExecutor(executor: *innigkeit.Executor, architecture_processor_id: u64) void {
    executor.arch_specific = .{ .mpidr = architecture_processor_id };
}

pub fn captureSystemInformation(
    stage: architecture.init.CaptureSystemInformationStage,
    options: architecture.current_decls.init.CaptureSystemInformationOptions,
) anyerror!void {
    _ = stage;
    _ = options;
    // The ARM Generic Timer is self-describing via CNTFRQ_EL0 and the GIC base
    // addresses are fixed on the QEMU virt machine, so there is no MMIO probing
    // to do for now.
}

pub fn configureGlobalSystemFeatures() void {}

/// Configure per-executor features. Called once on the bootstrap executor
/// after early system info, again after full system info, and on every
/// executor after full system info. Bringing up the GIC + generic timer is
/// idempotent enough to run here once MMIO is mapped (after `initializeMemorySystem`).
pub fn configurePerExecutorSystemFeatures() void {
    // The device MMIO (GIC, PL011) is only mapped after `initializeMemorySystem`
    // has built and loaded the kernel page table. Skip GIC/timer bring-up
    // until then; this function is re-invoked after full system info.
    arm.semihost.write("[arm] configurePerExecutorSystemFeatures\n");
    if (!innigkeit.mem.globals.memory_system_initialized) return;

    // The GIC distributor and the shared IRQ-handler table are GLOBAL: bring
    // them up exactly once (on the bootstrap executor). The GIC CPU interface
    // and the generic timer are PER-EXECUTOR (banked PPI/SGI state and per-CPU
    // timer registers), so every executor initialises its own below. This is
    // what M3 SMP needs; on the single-core path the per-executor calls are an
    // idempotent re-write, matching how x64 re-applies its per-executor
    // registers on each invocation.
    if (!gic_distributor_initialized) {
        gic_distributor_initialized = true;
        arm.semihost.write("[arm] configurePerExecutor: bringing up GIC distributor\n");
        log.debug("initializing GICv2 distributor and registering timer handler", .{});
        arm.gic.initDistributor();
        arm.gic.registerHandler(arm.timer.IRQ, perExecutorPeriodicTick);
    }

    arm.gic.initCpuInterface();
    arm.timer.init();
}

/// Tracks the one-time GIC distributor bring-up. The CPU interface and timer
/// are per-executor and deliberately NOT guarded by this flag.
var gic_distributor_initialized: bool = false;

/// Register the ARM Generic Timer as the reference counter, wallclock and
/// per-executor periodic source.
pub fn registerArchitecturalTimeSources(
    candidate_time_sources: *innigkeit.time.init.CandidateTimeSources,
) void {
    arm.semihost.write("[arm] registerArchitecturalTimeSources\n");
    candidate_time_sources.addTimeSource(.{
        .name = "arm_generic_timer",
        .priority = 200,
        .initialization = .none,
        .reference_counter = .{
            .prepareToWaitForFn = referenceCounterPrepareToWaitFor,
            .waitForFn = referenceCounterWaitFor,
        },
        .wallclock = .{
            .readFn = wallclockRead,
            .elapsedFn = wallclockElapsed,
            .standard_wallclock_source = true,
        },
        .per_executor_periodic = .{
            .enableInterruptFn = perExecutorPeriodicEnableInterrupt,
        },
    });
}

pub fn initLocalInterruptController() void {
    // Folded into `configurePerExecutorSystemFeatures` (GIC CPU interface).
}

/// Physical counter frequency in Hz (CNTFRQ_EL0).
///
/// Fixed for the lifetime of the system; read on demand.
inline fn counterFrequency() u64 {
    return arm.registers.CNTFRQ_EL0.read();
}

fn wallclockRead() innigkeit.time.wallclock.Tick {
    return @enumFromInt(arm.registers.CNTPCT_EL0.read());
}

fn wallclockElapsed(
    value1: innigkeit.time.wallclock.Tick,
    value2: innigkeit.time.wallclock.Tick,
) core.Duration {
    const ticks = @intFromEnum(value2) - @intFromEnum(value1);
    const freq = counterFrequency();
    // nanoseconds = ticks * 1e9 / freq. Order the multiply first; ticks here
    // are bounded by realistic uptimes so the intermediate does not overflow
    // for the durations the kernel prints.
    const ns = if (freq == 0) 0 else (ticks / freq) * 1_000_000_000 +
        ((ticks % freq) * 1_000_000_000) / freq;
    return .{ .value = ns };
}

fn referenceCounterPrepareToWaitFor(duration: core.Duration) void {
    _ = duration;
}

fn referenceCounterWaitFor(duration: core.Duration) void {
    const freq = counterFrequency();
    // ticks = ns * freq / 1e9
    const ticks = (duration.value / 1_000_000_000) * freq +
        ((duration.value % 1_000_000_000) * freq) / 1_000_000_000;
    const start = arm.registers.CNTPCT_EL0.read();
    while (arm.registers.CNTPCT_EL0.read() -% start < ticks) {
        arm.instructions.isb();
    }
}

/// Period the scheduler asked for, stored so the IRQ handler can re-arm.
var periodic_period_ns: u64 = 5_000_000;

fn perExecutorPeriodicEnableInterrupt(period: core.Duration) void {
    periodic_period_ns = period.value;
    // Arm the virtual timer and make sure the timer interrupt is unmasked.
    arm.timer.setNextTick(period.value);
    architecture.interrupts.enable();
}

/// Virtual-timer IRQ handler: drive the timer subsystems and the scheduler
/// preempt check, then re-arm for the next period. Mirrors x64's
/// `perExecutorPeriodicHandler`.
fn perExecutorPeriodicTick() void {
    arm.timer.setNextTick(periodic_period_ns);
    innigkeit.sync.nanosleep.tick();
    innigkeit.sync.futex.tick();
    innigkeit.Task.Current.get().tickAndRequestPreemptIfNeeded();
}
