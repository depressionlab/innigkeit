const ReferenceCounter = @This();
const core = @import("core");

/// Prepares the counter to wait for `duration`.
///
/// Must be called before `_waitForFn` is called.
_prepareToWaitForFn: *const fn (duration: core.Duration) void,

/// Waits for `duration`.
///
/// Must be called after `_prepareToWaitForFn` is called.
_waitForFn: *const fn (duration: core.Duration) void,

/// Prepares the counter to wait for `duration`.
///
/// Must be called before `waitFor` is called.
pub inline fn prepareToWaitFor(
    self: ReferenceCounter,
    duration: core.Duration,
) void {
    self._prepareToWaitForFn(duration);
}

/// Waits for `duration`.
///
/// Must be called after `prepareToWaitFor` is called.
pub inline fn waitFor(
    self: ReferenceCounter,
    duration: core.Duration,
) void {
    self._waitForFn(duration);
}
