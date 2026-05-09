//! This feature provides the frequency of the primary timestamp counter.
//!
//! The primary timestamp counter is the counter read by the `RDTSC` instruction on x86-64, `CNTPCT_EL0` on aarch64, `RDTIME` on riscv64,
//! and `RDTIME.D` on loongarch64.
//!
//! Note: The frequency value provided by this feature is best-effort, and may not be fully precise depending on the platform and the method
//! used by the bootloader to determine it.
//!
//! Note: If the bootloader is unable to determine the timestamp counter frequency, no response will be provided.

const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x10f2ee1d87d195e4, 0xf747a2b78f6ddb31),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    /// The frequency of the primary timestamp counter, in Hertz.
    frequency: u64,
};
