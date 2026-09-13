//! Cross-platform hardware-backed random number source.

const builtin = @import("builtin");
const std = @import("std");

/// Architecture-specific hardware random number.
///
/// Returns `null` if not available of the instruction signals failure.
pub inline fn next() ?u64 {
    return switch (builtin.cpu.arch) {
        .x86_64 => blk: {
            // Guard: `RDRAND` is not universally supported on x86_64. It was
            // introduced with Ivy Bridge (Intel, 2012) and Jaguar (AMD, 2013).
            // Issuing the instruction on an older CPU causes #UD (illegal
            // opcode), which would fault the kernel. Check CPUID leaf 1
            // `ECX[30]` before attempting the instruction.
            if (!x64RdrandSupported()) break :blk null;

            // Intel recommends retrying `RDRAND` up to 10 times, since brief
            // failure is common under high system load (e.g., DRNG reseeding,
            // contention).
            var attempts: usize = 0;
            while (attempts < 10) : (attempts += 1) {
                var v: u64 = undefined;
                var ok: u8 = undefined;
                asm volatile (
                    \\ rdrand %[v]
                    \\ setc %[ok]
                    : [v] "=r" (v),
                      [ok] "=r" (ok),
                    :
                    : .{ .cc = true });
                if (ok != 0) break :blk v;
            }
            break :blk null;
        },
        .aarch64 => blk: {
            // RNDR system register (ARMv8.5-A FEAT_RNG).
            // Returns `null` via NZCV.Z=1 if the RNG isn't available.
            var v: u64 = undefined;
            var ok: u64 = undefined;
            asm volatile (
            // RNDR by architectural encoding (`S3_3_C2_C4_0`). `rndr`
            // only assembles when the target enables FEAT_RNG (+rand),
            // which the freestanding aarch64 target does nit.
                \\ mrs %[v], S3_3_C2_C4_0
                \\ cset %[ok], ne
                : [v] "=r" (v),
                  [ok] "=r" (ok),
                :
                // : .{ .cc = true }
            );
            break :blk if (ok != 0) v else null;
        },
        else => null,
    };
}

/// Returns `true` if RDRAND is supported on the current x86_64 CPU.
///
/// Executes CPUID leaf 1 and tests ECX bit 30 (RDRAND feature flag).
fn x64RdrandSupported() bool {
    var ecx: u32 = undefined;
    asm volatile ("cpuid"
        : [ecx] "={ecx}" (ecx),
        : [leaf] "{eax}" (@as(u32, 1)),
        : .{ .eax = true, .ebx = true, .edx = true });
    return (ecx >> 30) & 1 != 0;
}

/// Counter-based fallback when a true hardware RNG is unavailable.
///
/// `slot_index` is mixed in as a domain-separation constant so repeated
/// calls with a stalled clock produce distinct output.
inline fn counterFallback(slot_index: usize) u64 {
    const raw: u64 = switch (builtin.cpu.arch) {
        .x86_64 => blk: {
            var low: u32 = undefined;
            var high: u32 = undefined;
            asm volatile ("rdtsc"
                : [_] "={eax}" (low),
                  [_] "={edx}" (high),
            );
            break :blk (@as(u64, high) << 32) | @as(u64, low);
        },
        .aarch64 => blk: {
            var v: u64 = undefined;
            asm volatile ("mrs %[v], cntvct_el0"
                : [v] "=r" (v),
            );
            break :blk v;
        },
        .riscv64 => blk: {
            // rdtime reads the real-time counter
            var v: u64 = undefined;
            asm volatile ("rdtime %[v]"
                : [v] "=r" (v),
            );
            break :blk v;
        },
        else => 0,
    };
    return raw ^ (slot_index *% 0x9E3779B97F4A7C15);
}

pub inline fn nextOrCounter(slot_index: usize) u64 {
    return (next() orelse 0) ^ counterFallback(slot_index);
}

/// Fill a buffer of any length with `nextOrCounter` bytes, 8 at a time.
pub fn fill(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) : (i += 8) {
        const v = nextOrCounter(i);
        const n = @min(8, buf.len - i);
        @memcpy(buf[i..][0..n], std.mem.asBytes(&v)[0..n]);
    }
}
