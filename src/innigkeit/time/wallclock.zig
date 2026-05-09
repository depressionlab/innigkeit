const core = @import("core");

/// This is an opaque timer tick, to acquire an actual time value, use `elapsed`.
pub const Tick = enum(u64) {
    zero = 0,

    _,
};

/// Read the wallclock value.
pub inline fn read() Tick {
    return globals.readFn();
}

/// Returns the duration between `value1` and `value2`, where `value2 >= value1`.
///
/// Counter wraparound is assumed to have not occured.
pub inline fn elapsed(value1: Tick, value2: Tick) core.Duration {
    return globals.elapsedFn(value1, value2);
}

pub const globals = struct {
    /// Set by `init.initializeTime`.
    pub var readFn: *const fn () Tick = undefined;

    /// Set by `init.initializeTime`.
    pub var elapsedFn: *const fn (value1: Tick, value2: Tick) core.Duration = undefined;
};
