const std = @import("std");
const builtin = @import("builtin");

const native_endian: std.builtin.Endian = builtin.cpu.arch.endian();
pub const is_debug = builtin.mode == .Debug;
