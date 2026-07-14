const builtin = @import("builtin");

pub const is_debug = builtin.mode == .Debug;
