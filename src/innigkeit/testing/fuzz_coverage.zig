//! Per-syscall-selector coverage counters for the in-kernel fuzzing
//! corpus-feedback channel.
//!
//! Coarser than real per-basic-block coverage: Zig 0.16 has no
//! SanitizerCoverage-equivalent instrumentation so this answers
//! "which syscalls executed," not "which branches executed."
//!
//! `recordHit` is called from `syscalls.zig`'s `dispatch()`, gated
//! at the call site by `kernel_options.fuzz_channel_test` so it
//! costs nothing in a normal build; this file itself always compiles
//! (the table and its own tests are cheap either way).

const libinnigkeit = @import("libinnigkeit");
const std = @import("std");

const Syscall = libinnigkeit.Syscall;

var counters: std.enums.EnumArray(Syscall, std.atomic.Value(u32)) =
    .initFill(.init(0));

/// Record one real dispatch of `syscall` (called only once the entitlement
/// gate has passed and the handler is about to run: a permission-denied
/// attempt is not "coverage" of that handler's code).
pub fn recordHit(syscall: Syscall) void {
    _ = counters.getPtr(syscall).fetchAdd(1, .monotonic);
}

/// Snapshot every counter into `out`, in `std.meta.tags(Syscall)` order.
///
/// We use the same fixed order the host-side reader (`tools/kernel_fuzz`) walks.
/// `out.len` must be at least `std.meta.tags(Syscall).len`.
pub fn dumpInto(out: []u32) void {
    for (std.meta.tags(Syscall), 0..) |tag, i| {
        out[i] = counters.get(tag).load(.monotonic);
    }
}

test "fuzz coverage: recordHit is reflected in the next dumpInto, other counters untouched" {
    const tag: Syscall = .getpid;
    var before: [std.meta.tags(Syscall).len]u32 = undefined;
    dumpInto(&before);

    recordHit(tag);
    recordHit(tag);

    var after: [std.meta.tags(Syscall).len]u32 = undefined;
    dumpInto(&after);

    for (std.meta.tags(Syscall), 0..) |t, i| {
        const expected_delta: u32 = if (t == tag) 2 else 0;
        try std.testing.expectEqual(before[i] + expected_delta, after[i]);
    }
}
