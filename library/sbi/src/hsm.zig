//! The Hart State Management (HSM) Extension introduces a set of hart states and a set of functions which allow the
//! supervisor-mode software to request a hart state change.
//!
//! A platform can have multiple harts grouped into hierarchical topology groups (namely cores, clusters, nodes, etc.)
//! with separate platform specific low-power states for each hierarchical group. These platform specific low-power
//! states of hierarchical topology groups can be represented as platform specific suspend states of a hart.
//!
//! An SBI implementation can utilize the suspend states of higher topology groups using one of the following approaches:
//! - Platform-coordinated: In this approach, when a hart becomes idle the supervisor-mode power-management software
//! will request deepest suspend state for the hart and higher topology groups.
//! An SBI implementation should choose a suspend state at higher topology group which is:
//!     - Not deeper than the specified suspend state
//!     - Wake-up latency is not higher than the wake-up latency of the specified suspend state
//!
//! - OS-inititated: In this approach, the supervisor-mode power-managment software will directly request a suspend
//! state for higher topology group after the last hart in that group becomes idle. When a hart becomes idle, the
//! supervisor-mode power-managment software will always select suspend state for the hart itself but it will select a
//! suspend state for a higher topology group only if the hart is the last running hart in the group.
//! An SBI implementation should:
//!     - Never choose a suspend state for higher topology group different from the specified suspend state
//!     - Always prefer most recent suspend state requested for higher topology group
const base = @import("base.zig");
const ecall = @import("ecall.zig");

pub fn available() bool {
    return base.probeExtension(.HSM);
}

pub const HartStartError = error{
    /// `start_physical_address` is not valid, possibly due to the following reasons:
    ///  - It is not a valid physical address.
    ///  - Executable access to the address is prohibited by a physical memory protection mechanism or H-extension
    ///    G-stage for supervisor-mode.
    InvalidAddress,

    /// `hartid` is not a valid hartid as the corresponding hart cannot be started in supervisor mode.
    InvalidParameter,

    /// The given hartid is already started.
    AlreadyAvailable,

    /// The start request failed for unspecified or unknown other reasons.
    Failed,
};

/// Request the SBI implementation to start executing the target hart in supervisor-mode, at the address specified
/// by `start_addr`, with register values:
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
/// This call is asynchronous — more specifically, `hartStart` may return before the target hart starts executing as
/// long as the SBI implementation is capable of ensuring the return code is accurate.
///
/// If the SBI implementation is a platform runtime firmware executing in machine-mode (M-mode), then it MUST
/// configure any physical memory protection it supports, such as that defined by PMP, and other M-mode state,
/// before transferring control to supervisor-mode software.
///
/// Available from SBI v0.2.
pub fn hartStart(
    hartid: usize,
    start_physical_address: usize,
    user_value: usize,
) HartStartError!void {
    return ecall.threeArgsNoReturnWithError(
        .HSM,
        @backingInt(HSM_FID.HART_START),
        @bitCast(hartid),
        @bitCast(start_physical_address),
        @bitCast(user_value),
        HartStartError,
    );
}

pub const HartStopError = error{
    /// Failed to stop execution of the current hart.
    Failed,
};

/// Request the SBI implementation to stop executing the calling hart in supervisor-mode and return its ownership to
/// the SBI implementation.
///
/// This call is not expected to return under normal conditions.
///
/// Must be called with supervisor-mode interrupts disabled.
///
/// Available from SBI v0.2.
pub fn hartStop() HartStopError!noreturn {
    try ecall.zeroArgsNoReturnWithError(
        .HSM,
        @backingInt(HSM_FID.HART_STOP),
        HartStopError,
    );
    unreachable;
}

pub const HartStatusError = error{
    /// The given hartid is not valid.
    InvalidParameter,
};

/// Get the current status (or HSM state id) of the given hart.
///
/// The harts may transition HSM states at any time due to any concurrent `hartStart`, `hartStop` or `hartSuspend`
/// calls, the return value from this function may not represent the actual state of the hart at the time of return
/// value verification.
///
/// Available from SBI v0.2.
pub fn hartStatus(hartid: usize) HartStatusError!State {
    return @fromBackingInt(@intCast(try ecall.oneArgsWithReturnWithError(
        .HSM,
        @backingInt(HSM_FID.HART_GET_STATUS),
        @bitCast(hartid),
        HartStatusError,
    )));
}

pub const HartSuspendError = error{
    /// `suspend_type` is not reserved and is implemented, but the platform does not support it due to one or more
    /// missing dependencies.
    NotSupported,

    /// `suspend_type` is reserved or is platform-specific and unimplemented.
    InvalidParameter,

    /// `resume_physical_address` is not valid, possibly due to the following reasons:
    ///  - It is not a valid physical address.
    ///  - Executable access to the address is prohibited by a physical memory protection mechanism or H-extension
    ///    G-stage for supervisor-mode.
    InvalidAddress,

    /// The suspend request failed for unspecified or unknown other reasons.
    Failed,
};

/// Request the SBI implementation to put the calling hart in a platform specific suspend (or low power) state
/// specified by the `suspend_type` parameter.
///
/// The hart will automatically come out of suspended state and resume normal execution when it receives an
/// interrupt or platform specific hardware event.
///
/// The platform specific suspend states for a hart can be either retentive or non-retentive in nature.
///
/// A retentive suspend state will preserve hart register and CSR values for all privilege modes whereas a
/// non-retentive suspend state will not preserve hart register and CSR values.
///
/// Resuming from a retentive suspend state is straight forward and the supervisor-mode software will see
/// `hartSuspend` return without any failures. The `resume_physical_address` parameter is unused during retentive
/// suspend.
///
/// Resuming from a non-retentive suspend state is relatively more involved and requires software to restore various
/// hart registers and CSRs for all privilege modes. Upon resuming from non-retentive suspend state, the hart will
/// jump to supervisor-mode at address specified by `resume_physical_address` with register values:
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
/// Available from SBI v0.3.
pub fn hartSuspend(
    suspend_type: SuspendType,
    resume_physical_address: usize,
    user_value: usize,
) HartSuspendError!void {
    return ecall.threeArgsNoReturnWithError(
        .HSM,
        @backingInt(HSM_FID.HART_SUSPEND),
        @bitCast(@as(usize, suspend_type.toRaw())),
        @bitCast(resume_physical_address),
        @bitCast(user_value),
        HartSuspendError,
    );
}

pub const SuspendType = union(enum) {
    /// Default retentive suspend
    retentive,

    /// Default non-retentive suspend
    non_retentive,

    /// | Value                     | Description                             |
    /// | ------------------------- | --------------------------------------- |
    /// | `0x00000000`              | Default retentive suspend               |
    /// | `0x00000001 - 0x0FFFFFFF` | Reserved for future use                 |
    /// | `0x10000000 - 0x7FFFFFFF` | Platform specific retentive suspend     |
    /// | `0x80000000`              | Default non-retentive suspend           |
    /// | `0x80000001 - 0x8FFFFFFF` | Reserved for future use                 |
    /// | `0x90000000 - 0xFFFFFFFF` | Platform specific non-retentive suspend |
    custom: u32,

    fn toRaw(self: SuspendType) u32 {
        return switch (self) {
            .retentive => 0x00000000,
            .non_retentive => 0x80000000,
            .custom => |custom| custom,
        };
    }
};

pub const State = enum(isize) {
    /// The hart is physically powered-up and executing normally.
    started = 0x0,

    /// The hart is not executing in supervisor-mode or any lower privilege mode.
    ///
    /// It is probably powered-down by the SBI implementation if the underlying platform has a mechanism to
    /// physically power-down harts.
    stopped = 0x1,

    /// Some other hart has requested to start (or power-up) the hart from the `stopped` state and the SBI
    /// implementation is still working to get the hart in the `started` state.
    start_pending = 0x2,

    /// The hart has requested to stop (or power-down) itself from the `started` state and the SBI implementation is
    /// still working to get the hart in the `stopped` state.
    stop_pending = 0x3,

    /// This hart is in a platform specific suspend (or low power) state.
    suspended = 0x4,

    /// The hart has requested to put itself in a platform specific low power state from the `started` state and the
    /// SBI implementation is still working to get the hart in the platform specific `suspended` state.
    suspend_pending = 0x5,

    /// An interrupt or platform specific hardware event has caused the hart to resume normal execution from the
    /// `suspended` state and the SBI implementation is still working to get the hart in the `started` state.
    resume_pending = 0x6,

    _,
};

const HSM_FID = enum(i32) {
    HART_START = 0x0,
    HART_STOP = 0x1,
    HART_GET_STATUS = 0x2,
    HART_SUSPEND = 0x3,
};
