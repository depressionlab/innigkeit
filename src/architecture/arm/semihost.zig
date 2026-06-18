//! AArch64 semihosting console output (QEMU `-semihosting`).
//!
//! Semihosting calls trap to the host via `HLT #0xF000` (A64 encoding) with
//! the operation number in W0 and the parameter in X1 — they work regardless
//! of MMU/translation state, which makes them the only reliable output
//! channel before the kernel's own UART mapping exists. On real hardware
//! (no semihosting agent) `HLT` is an illegal instruction, so every call is
//! gated on `enabled`; QEMU test/run setups pass `-semihosting` and the
//! kernel build enables this only for QEMU-targeted images.
//!
//! Reference: "Semihosting for AArch32 and AArch64" (ARM DUI0003).
//! https://github.com/ARM-software/abi-aa/blob/main/semihosting/semihosting.rst

const std = @import("std");

/// Whether semihosting calls may be issued. Defaults to true on QEMU-style
/// boots (the only supported aarch64 target today); set to false before
/// running on metal without a debug agent.
pub var enabled: bool = true;

const SYS_WRITEC: u64 = 0x03; // write one character (param: pointer to byte)
const SYS_WRITE0: u64 = 0x04; // write NUL-terminated string (param: pointer)
const SYS_EXIT: u64 = 0x18; // terminate (param: pointer to {reason, subcode})

inline fn call(op: u64, param: u64) u64 {
    return asm volatile (
        \\ hlt #0xf000
        : [ret] "={x0}" (-> u64),
        : [op] "{x0}" (op),
          [param] "{x1}" (param),
        : .{ .memory = true });
}

pub fn putc(c: u8) void {
    if (!enabled) return;
    var byte: u8 = c;
    _ = call(SYS_WRITEC, @intFromPtr(&byte));
}

/// Write a string (need not be NUL-terminated; characters are written
/// individually to avoid requiring a sentinel).
pub fn write(s: []const u8) void {
    if (!enabled) return;
    for (s) |c| {
        var byte: u8 = c;
        _ = call(SYS_WRITEC, @intFromPtr(&byte));
    }
}

/// Write a u64 as zero-padded hex (no allocation, no formatting machinery).
pub fn writeHex(v: u64) void {
    if (!enabled) return;
    write("0x");
    var i: u6 = 60;
    while (true) : (i -= 4) {
        const nibble: u4 = @truncate(v >> i);
        putc("0123456789abcdef"[nibble]);
        if (i == 0) break;
    }
}

/// ADP_Stopped_ApplicationExit with `code` as the subcode: under QEMU
/// `-semihosting` this terminates the VM with that exit code.
pub fn exit(code: u64) noreturn {
    if (enabled) {
        const block: [2]u64 = .{ 0x20026, code }; // {reason, subcode}
        _ = call(SYS_EXIT, @intFromPtr(&block));
    }
    while (true) {
        asm volatile ("wfe");
    }
}
