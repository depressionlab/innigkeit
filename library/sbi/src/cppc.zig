//! ACPI defines the Collaborative Processor Performance Control (CPPC) mechanism, which is an abstract and flexible
//! mechanism for the supervisor-mode power-management software to collaborate with an entity in the platform to manage
//! the performance of the processors.
//!
//! The SBI CPPC extension provides an abstraction to access the CPPC registers through SBI calls. The CPPC registers
//! can be memory locations shared with a separate platform entity such as a BMC. Even though CPPC is defined in the
//! ACPI specification, it may be possible to implement a CPPC driver based on Device Tree.
const base = @import("base.zig");
const ecall = @import("ecall.zig");

pub fn available() bool {
    return base.probeExtension(.CPPC);
}

pub const ProbeError = error{
    /// `register` is reserved.
    InvalidParameter,

    /// The probe request failed for unspecified or unknown other reasons.
    Failed,
};

/// Probe whether the CPPC register as specified by the `register` parameter is implemented or not by the platform.
///
/// Returns the width of the register in bits if the register is implemented, otherwise returns `null`.
///
/// Available from SBI v2.0.
pub fn probe(register: Register) ProbeError!?usize {
    const ret = try ecall.oneArgsWithReturnWithError(
        .CPPC,
        @backingInt(CPPC_FID.PROBE_REGISTER),
        @bitCast(@as(usize, @backingInt(register))),
        ProbeError,
    );
    if (ret == 0) {
        @branchHint(.unlikely);
        return null;
    }
    return @bitCast(ret);
}

pub const ReadError = error{
    /// `register` is reserved.
    InvalidParameter,

    /// `register` is not implemented by the platform.
    NotSupported,

    /// `register` is a write-only register.
    Denied,

    /// The read request failed for unspecified or unknown other reasons.
    Failed,
};

/// Reads the register as specified in the `register` parameter.
///
/// When supervisor mode XLEN is 32, the  value will only contain the lower 32 bits of the CPPC register value.
///
/// Available from SBI v2.0.
pub fn read(register: Register) ReadError!usize {
    return @bitCast(try ecall.oneArgsWithReturnWithError(
        .CPPC,
        @backingInt(CPPC_FID.READ_REGISTER),
        @bitCast(@as(usize, @backingInt(register))),
        ReadError,
    ));
}

/// Reads the upper 32-bit value of the register specified in the `register` parameter.
///
/// This function always returns zero in when supervisor mode XLEN is 64 or higher.
///
/// Available from SBI v2.0.
pub fn readHigh(register: Register) ReadError!usize {
    return @bitCast(try ecall.oneArgsWithReturnWithError(
        .CPPC,
        @backingInt(CPPC_FID.READ_HIGH_REGISTER),
        @bitCast(@as(usize, @backingInt(register))),
        ReadError,
    ));
}

pub const WriteError = error{
    /// `register` is reserved.
    InvalidParameter,

    /// `register` is not implemented by the platform.
    NotSupported,

    /// `register` is a read-only register.
    Denied,

    ///  The write request failed for unspecified or unknown other reasons.
    Failed,
};

/// Writes the value passed in the `value` parameter to the register as specified in the `register` parameter.
///
/// Available from SBI v2.0.
pub fn write(register: Register, value: u64) WriteError!void {
    try ecall.twoArgsLastArg64NoReturnWithError(
        .CPPC,
        @backingInt(CPPC_FID.WRITE_REGISTER),
        @bitCast(@as(usize, @backingInt(register))),
        value,
        WriteError,
    );
}

/// The identifiers for all CPPC registers to be used by the SBI CPPC functions.
///
/// The first half of the 32-bit register space corresponds to the registers as defined by the ACPI specification.
/// The second half provides the information not defined in the ACPI specification, but is additionally required by
/// the supervisor-mode power-management software.
pub const Register = enum(u32) {
    /// Bit width 32 - Attribute Read-only - ACPI Spec 6.5: 8.4.6.1.1.1
    HighestPerformance = 0x00000000,
    /// Bit width 32 - Attribute Read-only - ACPI Spec 6.5: 8.4.6.1.1.2
    NominalPerformance = 0x00000001,
    /// Bit width 32 - Attribute Read-only - ACPI Spec 6.5: 8.4.6.1.1.4
    LowestNonlinearPerformance = 0x00000002,
    /// Bit width 32 - Attribute Read-only - ACPI Spec 6.5: 8.4.6.1.1.5
    LowestPerformance = 0x00000003,
    /// Bit width 32 - Attribute Read-only - ACPI Spec 6.5: 8.4.6.1.1.6
    GuaranteedPerformanceRegister = 0x00000004,
    /// Bit width 32 - Attribute Read/Write - ACPI Spec 6.5: 8.4.6.1.2.3
    DesiredPerformanceRegister = 0x00000005,
    /// Bit width 32 - Attribute Read/Write - ACPI Spec 6.5: 8.4.6.1.2.2
    MinimumPerformanceRegister = 0x00000006,
    /// Bit width 32 - Attribute Read/Write - ACPI Spec 6.5: 8.4.6.1.2.1
    MaximumPerformanceRegister = 0x00000007,
    /// Bit width 32 - Attribute Read/Write - ACPI Spec 6.5: 8.4.6.1.2.4
    PerformanceReductionToleranceRegister = 0x00000008,
    /// Bit width 32 - Attribute Read/Write - ACPI Spec 6.5: 8.4.6.1.2.5
    TimeWindowRegister = 0x00000009,
    /// Bit width 32/64 - Attribute Read-only - ACPI Spec 6.5: 8.4.6.1.3.1
    CounterWraparoundTime = 0x0000000A,
    /// Bit width 32/64 - Attribute Read-only - ACPI Spec 6.5: 8.4.6.1.3.1
    ReferencePerformanceCounterRegister = 0x0000000B,
    /// Bit width 32/64 - Attribute Read-only - ACPI Spec 6.5: 8.4.6.1.3.1
    DeliveredPerformanceCounterRegister = 0x0000000C,
    /// Bit width 32 - Attribute Read/Write - ACPI Spec 6.5: 8.4.6.1.3.2
    PerformanceLimitedRegister = 0x0000000D,
    /// Bit width 32 - Attribute Read/Write - ACPI Spec 6.5: 8.4.6.1.4
    CPPCEnableRegister = 0x0000000E,
    /// Bit width 32 - Attribute Read/Write - ACPI Spec 6.5: 8.4.6.1.5
    AutonomousSelectionEnable = 0x0000000F,
    /// Bit width 32 - Attribute Read/Write - ACPI Spec 6.5: 8.4.6.1.6
    AutonomousActivityWindowRegister = 0x00000010,
    /// Bit width 32 - Attribute Read/Write - ACPI Spec 6.5: 8.4.6.1.7
    EnergyPerformancePreferenceRegister = 0x00000011,
    /// Bit width 32 - Attribute Read-only - ACPI Spec 6.5: 8.4.6.1.1.3
    ReferencePerformance = 0x00000012,
    /// Bit width 32 - Attribute Read-only - ACPI Spec 6.5: 8.4.6.1.1.7
    LowestFrequency = 0x00000013,
    /// Bit width 32 - Attribute Read-only - ACPI Spec 6.5: 8.4.6.1.1.7
    NominalFrequency = 0x00000014,

    // 0x00000015 - 0x7FFFFFFF Reserved for future use

    /// Provides the maximum (worst-case) performance state transition latency in nanoseconds.
    ///
    /// Bit width 32 - Attribute Read-only
    TransitionLatency = 0x80000000,

    // 0x80000001 - 0xFFFFFFFF Reserved for future use
};

const CPPC_FID = enum(i32) {
    PROBE_REGISTER = 0x0,
    READ_REGISTER = 0x1,
    READ_HIGH_REGISTER = 0x2,
    WRITE_REGISTER = 0x3,
};
