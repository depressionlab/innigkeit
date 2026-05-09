const Hpet = @import("Hpet.zig");

pub var hpet: Hpet = undefined; // Initalized during `initializeHPET`

/// The duration of a tick in femptoseconds.
pub var tick_duration_fs: u64 = undefined; // Initalized during `initializeHPET`

pub var number_of_timers_minus_one: u5 = undefined; // Initalized during `initializeHPET`
