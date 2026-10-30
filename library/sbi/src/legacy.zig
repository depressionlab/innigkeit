//! These legacy SBI extension are deprecated in favor of the other extensions.
//!
//! The page and access faults taken by the SBI implementation while accessing memory on behalf of the supervisor are
//! redirected back to the supervisor with `sepc` CSR pointing to the faulting `ECALL` instruction.
//!
//! Each function needs to be individually probed to check for support.
const base = @import("base.zig");
const ecall = @import("ecall.zig");

pub fn setTimerAvailable() bool {
    return base.probeExtension(.LEGACY_SET_TIMER);
}

/// Programs the clock for next event after `time_value` time.
///
/// This function also clears the pending timer interrupt bit.
///
/// If the supervisor wishes to clear the timer interrupt without scheduling the next timer event, it can either
/// request a timer interrupt infinitely far into the future (i.e., `setTimer(std.math.maxInt(u64))`), or it can
/// instead mask the timer interrupt by clearing `sie.STIE` CSR bit.
///
/// Available from SBI v0.1.
pub fn setTimer(time_value: u64) ImplementationDefinedError {
    return @fromBackingInt(@intCast(ecall.legacyOneArgs64WithReturn(.LEGACY_SET_TIMER, time_value)));
}

pub fn consolePutCharAvailable() bool {
    return base.probeExtension(.LEGACY_CONSOLE_PUTCHAR);
}

/// Write `char` to debug console.
///
/// Unlike `consoleGetChar`, this SBI call will block if there remain any pending characters to be transmitted or if
/// the receiving terminal is not yet ready to receive the byte. However, if the console doesn’t exist at all, then
/// the character is thrown away.
///
/// Available from SBI v0.1.
pub fn consolePutChar(char: u8) ImplementationDefinedError {
    return @fromBackingInt(@intCast(ecall.legacyOneArgsWithReturn(.LEGACY_CONSOLE_PUTCHAR, char)));
}

pub fn consoleGetCharAvailable() bool {
    return base.probeExtension(.LEGACY_CONSOLE_GETCHAR);
}

pub const ConsoleGetCharError = error{Failed};

/// Read a byte from debug console.
///
/// Available from SBI v0.1.
pub fn consoleGetChar() ConsoleGetCharError!u8 {
    const ret = ecall.legacyZeroArgsWithReturn(.LEGACY_CONSOLE_GETCHAR);
    if (ret < 0) {
        @branchHint(.unlikely);
        return ConsoleGetCharError.Failed;
    }

    return @intCast(ret);
}

pub fn clearIPIAvailable() bool {
    return base.probeExtension(.LEGACY_CLEAR_IPI);
}

/// Clears the pending IPIs if any.
///
/// The IPI is cleared only in the hart for which this SBI call is invoked.
///
/// `clearIPI` is deprecated because S-mode code can clear `sip.SSIP` CSR bit directly.
///
/// Returns `true` if an IPI had been pending `false` otherwise.
///
/// Available from SBI v0.1.
pub fn clearIPI() bool {
    return ecall.legacyZeroArgsWithReturn(.LEGACY_CLEAR_IPI) != 0;
}

pub fn sendIPIAvailable() bool {
    return base.probeExtension(.LEGACY_SEND_IPI);
}

/// Send an inter-processor interrupt to all the harts defined in `hart_mask`.
///
/// Interprocessor interrupts manifest at the receiving harts as Supervisor Software Interrupts.
///
/// `hart_mask` is a virtual address that points to a bit-vector of harts. The bit vector is represented as a
/// sequence of `usize` whose length equals the number of harts in the system divided by the number of bits in a
/// `usize`, rounded up to the next integer.
///
/// Available from SBI v0.1.
pub fn sendIPI(hart_mask: [*]const usize) ImplementationDefinedError {
    return @fromBackingInt(@intCast(ecall.legacyOneArgsWithReturn(.LEGACY_SEND_IPI, @bitCast(@intFromPtr(hart_mask)))));
}

pub fn remoteFenceIAvailable() bool {
    return base.probeExtension(.LEGACY_REMOTE_FENCE_I);
}

/// Instructs remote harts to execute `FENCE.I` instruction.
///
/// `hart_mask` is a virtual address that points to a bit-vector of harts. The bit vector is represented as a
/// sequence of `usize` whose length equals the number of harts in the system divided by the number of bits in a
/// `usize`, rounded up to the next integer.
///
/// Available from SBI v0.1.
pub fn remoteFenceI(hart_mask: [*]const usize) ImplementationDefinedError {
    return @fromBackingInt(@intCast(ecall.legacyOneArgsWithReturn(.LEGACY_REMOTE_FENCE_I, @bitCast(@intFromPtr(hart_mask)))));
}

pub fn remoteSFenceVMAAvailable() bool {
    return base.probeExtension(.LEGACY_REMOTE_SFENCE_VMA);
}

/// Instructs the remote harts to execute one or more `SFENCE.VMA` instructions, covering the range of
/// virtual addresses between `start` and `start + size`.
///
/// The remote fence operation applies to the entire address space if either:
///  - `start` and `size` are both `0`
///  - `size` is equal to `2^XLEN-1`
///
/// `hart_mask` is a virtual address that points to a bit-vector of harts. The bit vector is represented as a
/// sequence of `usize` whose length equals the number of harts in the system divided by the number of bits in a
/// `usize`, rounded up to the next integer.
///
/// Available from SBI v0.1.
pub fn remoteSFenceVMA(hart_mask: [*]const usize, start: usize, size: usize) ImplementationDefinedError {
    return @fromBackingInt(@intCast(ecall.legacyThreeArgsWithReturn(
        .LEGACY_REMOTE_SFENCE_VMA,
        @bitCast(@intFromPtr(hart_mask)),
        @bitCast(start),
        @bitCast(size),
    )));
}

pub fn remoteSFenceVMAWithASIDAvailable() bool {
    return base.probeExtension(.LEGACY_REMOTE_SFENCE_VMA_ASID);
}

/// Instruct the remote harts to execute one or more `SFENCE.VMA` instructions, covering the range of
/// virtual addresses between `start` and `start + size`.
///
/// This covers only the given ASID.
///
/// The remote fence operation applies to the entire address space if either:
///  - `start` and `size` are both `0`
///  - `size` is equal to `2^XLEN-1`
///
/// `hart_mask` is a virtual address that points to a bit-vector of harts. The bit vector is represented as a
/// sequence of `usize` whose length equals the number of harts in the system divided by the number of bits in a
/// `usize`, rounded up to the next integer.
///
/// Available from SBI v0.1.
pub fn remoteSFenceVMAWithASID(hart_mask: [*]const usize, start: usize, size: usize, asid: usize) ImplementationDefinedError {
    return @fromBackingInt(@intCast(ecall.legacyFourArgsWithReturn(
        .LEGACY_REMOTE_SFENCE_VMA_ASID,
        @bitCast(@intFromPtr(hart_mask)),
        @bitCast(start),
        @bitCast(size),
        @bitCast(asid),
    )));
}

pub fn systemShutdownAvailable() bool {
    return base.probeExtension(.LEGACY_SHUTDOWN);
}

/// Puts all the harts to shutdown state from supervisor point of view.
///
/// This SBI call doesn't return irrespective whether it succeeds or fails.
///
/// Available from SBI v0.1.
pub fn systemShutdown() noreturn {
    ecall.legacyZeroArgsNoReturn(.LEGACY_SHUTDOWN);
    unreachable;
}

pub const ImplementationDefinedError = enum(isize) {
    Success = 0,

    _,
};
