//! The System Reset Extension provides a function that allow the supervisor software to request system-level reboot or
//! shutdown.
//!
//! The term "system" refers to the world-view of supervisor software and the underlying SBI implementation could be
//! provided by machine mode firmware or a hypervisor.
const base = @import("base.zig");
const ecall = @import("ecall.zig");

pub fn available() bool {
    return base.probeExtension(.SRST);
}

pub const SystemResetError = error{
    /// `reset_type` is not reserved and is implemented, but the platform does not support it due to one or more
    /// missing dependencies.
    NotSupported,

    /// At least one of `reset_type` or `reset_reason` is reserved or is platform-specific and unimplemented.
    InvalidParameter,

    /// The reset request failed for unspecified or unknown other reasons.
    Failed,
};

/// Reset the system based on provided `reset_type` and `reset_reason`.
///
/// This is a synchronous call and does not return if it succeeds.
///
/// When supervisor software is running natively, the SBI implementation is provided by machine mode firmware.
/// In this case, shutdown is equivalent to a physical power down of the entire system and cold reboot is equivalent
/// to a physical power cycle of the entire system.
/// Further, warm reboot is equivalent to a power cycle of the main processor and parts of the system, but not the entire system.
///
/// For example, on a server class system with a BMC (board management controller), a warm reboot will not power
/// cycle the BMC whereas a cold reboot will definitely power cycle the BMC.
///
/// When supervisor software is running inside a virtual machine, the SBI implementation is provided by a hypervisor.
/// Shutdown, cold reboot and warm reboot will behave functionally the same as the native case, but might not result
/// in any physical power changes.
///
/// Available from SBI v0.3.
pub fn systemReset(
    reset_type: ResetType,
    reset_reason: ResetReason,
) SystemResetError!noreturn {
    try ecall.twoArgsNoReturnWithError(
        .SRST,
        @backingInt(SRST_FID.RESET),
        @bitCast(@as(usize, reset_type.toRaw())),
        @bitCast(@as(usize, reset_reason.toRaw())),
        SystemResetError,
    );
    unreachable;
}

pub const ResetType = union(enum) {
    shutdown,
    cold_reboot,
    warm_reboot,

    /// | Value                     | Description                            |
    /// | ------------------------- | -------------------------------------- |
    /// | `0x00000000`              | Shutdown                               |
    /// | `0x00000001`              | Cold reboot                            |
    /// | `0x00000002`              | Warm reboot                            |
    /// | `0x00000003 - 0xEFFFFFFF` | Reserved for future use                |
    /// | `0xF0000000 - 0xFFFFFFFF` | Vendor or platform specific reset type |
    custom: u32,

    fn toRaw(self: ResetType) u32 {
        return switch (self) {
            .shutdown => 0x00000000,
            .cold_reboot => 0x00000001,
            .warm_reboot => 0x00000002,
            .custom => |custom| custom,
        };
    }
};

pub const ResetReason = union(enum) {
    no_reason,
    system_failure,

    /// | Value                     | Description                              |
    /// | ------------------------- | ---------------------------------------- |
    /// | `0x00000000`              | No reason                                |
    /// | `0x00000001`              | System failure                           |
    /// | `0x00000002 - 0xDFFFFFFF` | Reserved for future use                  |
    /// | `0xE0000000 - 0xEFFFFFFF` | SBI implementation specific reset reason |
    /// | `0xF0000000 - 0xFFFFFFFF` | Vendor or platform specific reset reason |
    custom: u32,

    fn toRaw(self: ResetReason) u32 {
        return switch (self) {
            .no_reason => 0x00000000,
            .system_failure => 0x00000001,
            .custom => |custom| custom,
        };
    }
};

const SRST_FID = enum(i32) {
    RESET = 0x0,
};
