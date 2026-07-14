const architecture = @import("architecture");
const std = @import("std");

pub const PanicType = union(enum) {
    normal: struct {
        return_address: usize,
        error_return_trace: ?*const std.builtin.StackTrace,
    },
    interrupt: architecture.interrupts.InterruptFrame,
};
