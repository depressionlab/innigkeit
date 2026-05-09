const core = @import("core");

/// Enables a per-executor scheduler interrupt to be delivered every `period`.
pub inline fn enableInterrupt(period: core.Duration) void {
    return globals.enableInterruptFn(period);
}

pub const globals = struct {
    /// Set by `init.initializeTime`.
    pub var enableInterruptFn: *const fn (period: core.Duration) void = undefined;
};
