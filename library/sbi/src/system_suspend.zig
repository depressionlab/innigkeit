//! The system suspend extension defines a set of system-level sleep states and a function which allows the
//! supervisor-mode software to request that the system transitions to a sleep state.
//!
//! The term "system" refers to the world-view of the supervisor software domain invoking the call. System suspend may
//! only suspend the part of the overall system which is visible to the invoking supervisor software domain.
//!
//! The system suspend extension does not provide any way for supported sleep types to be probed. Platforms are expected
//! to specify their supported system sleep types and per-type wake up devices in their hardware descriptions.
//! The `SleepType.suspend_to_ram` sleep type is the one exception, and its presence is implied by that of the extension.
const base = @import("base.zig");
const ecall = @import("ecall.zig");

pub fn available() bool {
    return base.probeExtension(.SUSP);
}

pub const SystemSuspendError = error{
    /// `sleep_type` is reserved or is platform-specific and unimplemented.
    InvalidParameter,

    /// `sleep_type` is not reserved and is implemented, but the platform does not support it due to one or more
    /// missing dependencies.
    NotSupported,

    /// `resume_physical_address` is not valid, possibly due to the following reasons:
    ///  - It is not a valid physical address.
    ///  - Executable access to the address is prohibited by a physical memory protection mechanism or H-extension
    ///    G-stage for supervisor-mode.
    InvalidAddress,

    /// The suspend request failed due to unsatisfied entry criteria.
    Denied,

    /// The suspend request failed for unspecified or unknown other reasons.
    Failed,
};

/// A successful suspend and wake up, results in the hart which initiated the suspend, resuming from the STOPPED
/// state. To resume, the hart will jump to supervisor-mode, at the address specified by `resume_physical_address`,
/// with the specific register values:
///
/// | Register Name | Register Value         |
/// | ------------- | ---------------------- |
/// | `satp`        | `0`                    |
/// | `sstatus.SIE` | `0`                    |
/// | `x10`          | `hartid`               |
/// | `x11`          | `user_value` parameter |
///
/// All other registers are in an undefined state.
///
/// Besides ensuring all entry criteria for the selected sleep type are met, such as ensuring other harts are in the
/// STOPPED state, the caller must ensure all power units and domains are in a state compatible with the selected
/// sleep type.
///
/// The preparation of the power units, power domains, and wake-up devices used for resumption from the system sleep
/// state is platform specific and beyond the scope of this specification.
///
/// When supervisor software is running inside a virtual machine, the SBI implementation is provided by a hypervisor.
/// System suspend will behave similarly to the native case from the point of view of the supervisor software.
///
/// Available from SBI v2.0.
pub fn systemSuspend(
    sleep_type: SleepType,
    resume_physical_address: usize,
    user_value: usize,
) SystemSuspendError!noreturn {
    try ecall.threeArgsNoReturnWithError(
        .SUSP,
        @backingInt(SUSP_FID.SYSTEM_SUSPEND),
        @bitCast(@as(usize, sleep_type.toRaw())),
        @bitCast(resume_physical_address),
        @bitCast(user_value),
        SystemSuspendError,
    );
    unreachable;
}

pub const SleepType = union(enum) {
    suspend_to_ram,

    /// | Value                     | Description                              |
    /// | ------------------------- | ---------------------------------------- |
    /// | `0x00000000`              | This is a “suspend to RAM” sleep type, similar to ACPI’s S2 or S3. Entry
    /// |                           | requires all but the calling hart be in the HSM STOPPED state and all hart
    /// |                           | registers and CSRs are saved to RAM.     |
    /// | `0x00000001 - 0x7fffffff` | Reserved for future use                  |
    /// | `0x80000000 - 0xffffffff` | Platform-specific system sleep types     |
    custom: u32,

    fn toRaw(self: SleepType) u32 {
        return switch (self) {
            .suspend_to_ram => 0x00000000,
            .custom => |custom| custom,
        };
    }
};

const SUSP_FID = enum(i32) {
    SYSTEM_SUSPEND = 0x0,
};
