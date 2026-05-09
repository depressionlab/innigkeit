const LAPIC = @import("LAPIC.zig").LAPIC;

/// Initialized in `init.captureApicInformation`.
pub var lapic: LAPIC = undefined;

/// The duration of a tick in femptoseconds.
///
/// Initalized in `init.initializeLapicTimer[Calibrate]`
pub var tick_duration_fs: u64 = undefined;
