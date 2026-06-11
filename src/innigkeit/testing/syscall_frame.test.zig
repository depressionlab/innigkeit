//! Syscall ABI regression tests.
//!
//! These live under `src/innigkeit/` (rather than next to the architecture
//! code) because only files reachable from the innigkeit module's import
//! hierarchy are collected by the test build; the `architecture` module is a
//! separate package whose inline tests are never collected.

const std = @import("std");
const builtin = @import("builtin");
const architecture = @import("architecture");

// Regression test: arg4 was once read from rbx instead of r10. The x86-64
// syscall ABI passes arguments in rdi, rsi, rdx, r10, r8, r9 (rcx is clobbered
// by the `syscall` instruction itself, so r10 stands in for it).
test "x64: syscall args 1-6 come from rdi, rsi, rdx, r10, r8, r9" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const Frame = architecture.current_decls.user.SyscallFrame;

    var frame: Frame = undefined;
    // Distinct sentinel in every general-purpose register field so any
    // mis-mapped argument is caught, regardless of which register it reads.
    frame.rax = 0xA0;
    frame.rbx = 0xB0;
    frame.rdx = 0xD0;
    frame.rbp = 0xBF;
    frame.rdi = 0xD1;
    frame.rsi = 0x51;
    frame.r8 = 0x80;
    frame.r9 = 0x90;
    frame.r10 = 0x10;
    frame.r12 = 0x12;
    frame.r13 = 0x13;
    frame.r14 = 0x14;
    frame.r15 = 0x15;

    try std.testing.expectEqual(@as(usize, 0xD1), frame.arg(.one)); // rdi
    try std.testing.expectEqual(@as(usize, 0x51), frame.arg(.two)); // rsi
    try std.testing.expectEqual(@as(usize, 0xD0), frame.arg(.three)); // rdx
    try std.testing.expectEqual(@as(usize, 0x10), frame.arg(.four)); // r10, NOT rbx
    try std.testing.expectEqual(@as(usize, 0x80), frame.arg(.five)); // r8
    try std.testing.expectEqual(@as(usize, 0x90), frame.arg(.six)); // r9
}
