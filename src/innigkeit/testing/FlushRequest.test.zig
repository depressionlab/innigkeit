//! Regression test for `memory/core/FlushRequest.zig`'s EOI-timing fix.
const architecture = @import("architecture");
const builtin = @import("builtin");
const std = @import("std");

test "x64: flush_request interrupt EOIs before its handler runs, not after" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const Interrupt = architecture.current_decls.interrupts.Interrupt;
    const timing = architecture.interrupts.eoiTimingForVectorForTesting(Interrupt.flush_request) orelse
        return error.SkipZigTest;

    try std.testing.expectEqual(architecture.interrupts.Interrupt.Handler.EOI.before, timing);
}
