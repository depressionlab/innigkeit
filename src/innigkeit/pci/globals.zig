const ECAM = @import("ECAM.zig");

/// All ECAMs in the system.
///
/// Set by `init.initializeECAM`.
pub var ecams: []ECAM = &.{};
