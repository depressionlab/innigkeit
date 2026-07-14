//! ARM generic timer driver (EL1 virtual timer, CNTV).
//!
//! Uses CNTVCT_EL0 / CNTV_CVAL_EL0 / CNTV_CTL_EL0.
//! IRQ 27 = virtual timer PPI (wired by GICv2 per-CPU).
//!
//! Call `init()` once per CPU after GIC is initialised.
//! Call `setNextTick(ns)` to arm the next interrupt.
//! Register a handler with `gic.registerHandler(IRQ, handler)`.

const arm = @import("arm.zig");
const gic = @import("gic.zig");

pub const IRQ: u32 = 27;

// CNTV_CTL_EL0 bits
const CTL_ENABLE: u64 = 1 << 0;
const CTL_IMASK: u64 = 1 << 1;

/// Initialise the virtual timer on this CPU.
///
/// Enables IRQ 27 in the GIC and unmasks the timer.
pub fn init() void {
    // Enable the virtual timer interrupt in the GIC.
    gic.setPriority(IRQ, 0x80);
    gic.enableIrq(IRQ);

    // Disable timer initially (no CVAL set yet).
    arm.registers.CNTV_CTL_EL0.write(CTL_IMASK);
}

/// Convert a nanosecond duration to timer ticks at `freq` Hz: `ns * freq / 1e9`,
/// split into whole-seconds + remainder to avoid a 128-bit multiply while
/// staying exact (same technique as init.zig's `referenceCounterWaitFor/wallclockElapsed`).
fn nsToTicks(ns: u64, freq: u64) u64 {
    return (ns / 1_000_000_000) * freq + ((ns % 1_000_000_000) * freq) / 1_000_000_000;
}

/// Schedule the next timer interrupt `ns` nanoseconds from now.
pub fn setNextTick(ns: u64) void {
    const freq = arm.registers.CNTFRQ_EL0.read();
    const now = arm.registers.CNTVCT_EL0.read();
    const ticks = nsToTicks(ns, freq);
    arm.registers.CNTV_CVAL_EL0.write(now +% ticks);
    arm.registers.CNTV_CTL_EL0.write(CTL_ENABLE);
}

/// Disable the virtual timer (mask IRQ, leave CVAL as-is).
pub fn disable() void {
    arm.registers.CNTV_CTL_EL0.write(CTL_IMASK);
}

/// Read the current virtual counter value in timer ticks.
pub inline fn readTicks() u64 {
    return arm.registers.CNTVCT_EL0.read();
}

/// Read the timer frequency in Hz.
pub inline fn frequency() u64 {
    return arm.registers.CNTFRQ_EL0.read();
}

/// Convert timer ticks to milliseconds.
pub fn ticksToMs(ticks: u64) u64 {
    const freq = frequency();
    if (freq == 0) return 0;
    return ticks * 1000 / freq;
}

/// IRQ handler stub: re-arm the timer for the next period and acknowledge.
/// Replace with a proper per-executor scheduler tick once the scheduler is wired.
pub fn irqHandler() void {
    // Re-arm for ~1 ms (1_000_000 ns).
    setNextTick(1_000_000);
}
