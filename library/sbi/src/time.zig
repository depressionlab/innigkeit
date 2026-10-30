const base = @import("base.zig");
const ecall = @import("ecall.zig");

pub fn available() bool {
    return base.probeExtension(.TIME);
}

/// Programs the clock for next event after `time_value` time.
///
/// `stime_value` is in absolute time.
///
/// If the supervisor wishes to clear the timer interrupt without scheduling the next timer event, it may request a
/// timer interrupt infinitely far into the future (i.e., `setTimer(std.math.maxInt(u64)`).
///
/// Alternatively, to not receive timer interrupts, it may mask timer interrupts by clearing the `sie.STIE` CSR bit.
///
/// This function must clear the pending timer interrupt bit when `time_value` is set to some time in the future,
/// regardless of whether timer interrupts are masked or not.
///
/// Available from SBI v0.2.
pub fn setTimer(time_value: u64) void {
    ecall.oneArgs64NoReturnNoError(
        .TIME,
        @backingInt(TIME_FID.TIME_SET_TIMER),
        time_value,
    );
}

const TIME_FID = enum(i32) {
    TIME_SET_TIMER = 0x0,
};
