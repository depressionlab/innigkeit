const CandidateTimeSource = @This();

const core = @import("core");
const ReferenceCounter = @import("ReferenceCounter.zig");
const Tick = @import("wallclock.zig").Tick;

name: []const u8,

priority: u8,

initialization: Initialization = .none,

/// Provided if the time source is usable as a reference counter.
///
/// To be a valid reference counter the time source must not require calibration.
///
/// NOTE: The reference counter interface is only used during initialization.
reference_counter: ?ReferenceCounterOptions = null,

/// Provided if the time source is usable as a wallclock.
wallclock: ?WallclockOptions = null,

/// Provided if the time source is usable as a per-executor periodic interrupt.
///
/// If there is only one executor then a non per-executor time source is acceptable.
per_executor_periodic: ?PerExecutorPeriodicOptions = null,

initialized: bool = false,

pub fn initialize(self: *CandidateTimeSource, reference_counter: ReferenceCounter) void {
    if (self.initialized) return;
    switch (self.initialization) {
        .none => {},
        .simple => |simple| simple(),
        .calibration_required => |calibration_required| calibration_required(reference_counter),
    }
    self.initialized = true;
}

pub const Initialization = union(enum) {
    none,
    simple: *const fn () void,
    calibration_required: *const fn (reference_counter: ReferenceCounter) void,
};

pub const ReferenceCounterOptions = struct {
    /// Prepares the counter to wait for `duration`.
    ///
    /// Must be called before `waitForFn` is called.
    prepareToWaitForFn: *const fn (duration: core.Duration) void,

    /// Waits for `duration`.
    ///
    /// Must be called after `prepareToWaitForFn` is called.
    waitForFn: *const fn (duration: core.Duration) void,
};

pub const WallclockOptions = struct {
    /// Read the wallclock value.
    readFn: *const fn () Tick,

    /// Returns the duration between `value1` and `value2`, where `value2 >= value1`.
    ///
    /// Counter wraparound is assumed to have not occured.
    elapsedFn: *const fn (value1: Tick, value2: Tick) core.Duration,

    /// Whether this wallclock is the standard wallclock source for the current architecture.
    ///
    /// This is `true` only if this is the source used by `init.tryCaptureStandardWallclockStartTime`.
    ///
    /// For example on x86_64 this is the TSC.
    standard_wallclock_source: bool,
};

pub const PerExecutorPeriodicOptions = struct {
    /// Enables a per-executor scheduler interrupt to be delivered every `period`.
    enableInterruptFn: *const fn (period: core.Duration) void,
};
