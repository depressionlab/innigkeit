//! The base extension is designed to be as small as possible.
//!
//! As such, it only contains functionality for probing which SBI extensions are available and for querying the version
//! of the SBI.
//!
//! All functions in the base extension must be supported by all SBI implementations.
const ecall = @import("ecall.zig");
const is_64 = @import("root.zig").is_64;

/// Returns the current SBI specification version.
///
/// Available from SBI v0.2.
pub fn getSpecVersion() SpecVersion {
    return @bitCast(ecall.zeroArgsWithReturnNoError(
        .BASE,
        @backingInt(BASE_FID.GET_SPEC_VERSION),
    ));
}

/// Returns the current SBI implementation ID, which is different for every SBI implementation.
///
/// It is intended that this implementation ID allows software to probe for SBI implementation quirks
///
/// Available from SBI v0.2.
pub fn getImplementationId() ImplementationId {
    return @fromBackingInt(@intCast(ecall.zeroArgsWithReturnNoError(
        .BASE,
        @backingInt(BASE_FID.GET_IMP_ID),
    )));
}

/// Returns the current SBI implementation version.
///
/// The encoding of this version number is specific to the SBI implementation.
///
/// Available from SBI v0.2.
pub fn getImplementationVersion() isize {
    return ecall.zeroArgsWithReturnNoError(
        .BASE,
        @backingInt(BASE_FID.GET_IMP_VERSION),
    );
}

/// Returns `true` if the given SBI extension ID (EID) is available, or `false` if it is not available.
///
/// Available from SBI v0.2.
pub fn probeExtension(eid: EID) bool {
    return ecall.oneArgsWithReturnNoError(
        .BASE,
        @backingInt(BASE_FID.PROBE_EXT),
        @backingInt(eid),
    ) != 0;
}

/// Return a value that is legal for the `mvendorid` CSR and 0 is always a legal value for this CSR.
///
/// Available from SBI v0.2.
pub fn machineVendorId() isize {
    return ecall.zeroArgsWithReturnNoError(
        .BASE,
        @backingInt(BASE_FID.GET_MVENDORID),
    );
}

/// Return a value that is legal for the `marchid` CSR and 0 is always a legal value for this CSR.
///
/// Available from SBI v0.2.
pub fn machineArchId() isize {
    return ecall.zeroArgsWithReturnNoError(
        .BASE,
        @backingInt(BASE_FID.GET_MARCHID),
    );
}

/// Return a value that is legal for the `mimpid` CSR and 0 is always a legal value for this CSR.
///
/// Available from SBI v0.2.
pub fn machineImplementationId() isize {
    return ecall.zeroArgsWithReturnNoError(
        .BASE,
        @backingInt(BASE_FID.GET_MIMPID),
    );
}

pub const ImplementationId = enum(isize) {
    @"Berkeley Boot Loader (BBL)" = 0,
    OpenSBI = 1,
    Xvisor = 2,
    KVM = 3,
    RustSBI = 4,
    Diosix = 5,
    Coffer = 6,
    @"Xen Project" = 7,
    @"PolarFire Hart Software Services" = 8,
    coreboot = 9,
    oreboot = 10,
    bhyve = 11,

    _,
};

pub const SpecVersion = packed struct(usize) {
    minor: u24,
    major: u7,
    _reserved: u1,
    _: if (is_64) u32 else u0,
};

pub const EID = enum(i32) {
    LEGACY_SET_TIMER = 0x0,
    LEGACY_CONSOLE_PUTCHAR = 0x1,
    LEGACY_CONSOLE_GETCHAR = 0x2,
    LEGACY_CLEAR_IPI = 0x3,
    LEGACY_SEND_IPI = 0x4,
    LEGACY_REMOTE_FENCE_I = 0x5,
    LEGACY_REMOTE_SFENCE_VMA = 0x6,
    LEGACY_REMOTE_SFENCE_VMA_ASID = 0x7,
    LEGACY_SHUTDOWN = 0x8,

    BASE = 0x10,
    TIME = 0x54494D45,
    IPI = 0x735049,
    RFENCE = 0x52464E43,
    HSM = 0x48534D,
    SRST = 0x53525354,
    PMU = 0x504D55,
    DBCN = 0x4442434E,
    SUSP = 0x53555350,
    CPPC = 0x43505043,
    NACL = 0x4E41434C,
    STA = 0x535441,

    _,
};

const BASE_FID = enum(i32) {
    GET_SPEC_VERSION = 0x0,
    GET_IMP_ID = 0x1,
    GET_IMP_VERSION = 0x2,
    PROBE_EXT = 0x3,
    GET_MVENDORID = 0x4,
    GET_MARCHID = 0x5,
    GET_MIMPID = 0x6,
};
