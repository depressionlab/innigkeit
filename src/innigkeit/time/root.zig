const std = @import("std");

/// Femptoseconds per nanosecond.
pub const fs_per_ns = 1000000;

/// Femptoseconds per second.
pub const fs_per_s = fs_per_ns * std.time.ns_per_s;

pub const init = @import("init.zig");
pub const per_executor_periodic = @import("per_executor_periodic.zig");
pub const wallclock = @import("wallclock.zig");
