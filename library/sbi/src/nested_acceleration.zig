//! Nested virtualization is the ability of a hypervisor to run another hypervisor as a guest. RISC-V nested
//! virtualization requires an L0 hypervisor (running in hypervisor-mode) to trap-and-emulate the RISC-V H-extension
//! functionality (such as CSR accesses, HFENCE instructions, HLV/HSV instructions, etc.) for the L1 hypervisor (running
//! in virtualized supervisor-mode).
//!
//! The SBI nested acceleration extension defines a shared memory based interface between the SBI implementation (or L0
//! hypervisor) and the supervisor software (or L1 hypervisor) which allows both to collaboratively reduce traps taken
//! by the L0 hypervisor for emulating RISC-V H-extension functionality.
//!
//! The nested acceleration shared memory allows the L1 hypervisor to batch multiple RISC-V H-extension CSR accesses and
//! HFENCE requests which are then emulated by the L0 hypervisor upon an explicit synchronization SBI call.
//!
//! This SBI extension defines optional features which MUST be discovered by the supervisor software (or L1 hypervisor)
//! before using the corresponding SBI functions.
//!
//! To use the SBI nested acceleration extension, the supervisor software (or L1 hypervisor) MUST set up a nested
//! acceleration shared memory physical address for each virtual hart at boot-time.
//! The physical base address of the nested acceleration shared memory MUST be 4096 bytes (i.e. page) aligned and the
//! size of the nested acceleration shared memory must be `4096 + (1024 * (XLEN / 8))` bytes.
const base = @import("base.zig");
const ecall = @import("ecall.zig");
const std = @import("std");

pub fn available() bool {
    return base.probeExtension(.NACL);
}

/// Probe a nested acceleration feature. This is a mandatory function of the SBI nested acceleration extension.
///
/// Available from SBI v2.0.
pub fn probe(feature_id: FeatureId) bool {
    return ecall.oneArgsWithReturnNoError(
        .NACL,
        @backingInt(NACL_FID.PROBE_FEATURE),
        @bitCast(@as(usize, @backingInt(feature_id))),
    ) != 0;
}

pub const SetSharedMemoryError = error{
    /// The `flags` parameter is not zero or or the `shared_memory.enable.physical_address_low` parameter is not
    /// 4096 bytes aligned.
    InvalidParameter,

    /// The `shared_memory` parameter does not satisfy the requirements
    InvalidAddress,

    ///  The request failed for unspecified or unknown other reasons.
    Failed,
};

/// Enable or disable the shared memory for nested acceleration on the calling hart.
///
/// This is a mandatory function of the SBI nested acceleration extension.
///
/// Available from SBI v2.0.
pub fn setSharedMemory(shared_memory: SharedMemory, flags: SharedMemoryFlags) SetSharedMemoryError!void {
    const physical_address_low, const physical_address_high = shared_memory.toRaw();

    try ecall.threeArgsNoReturnWithError(
        .NACL,
        @backingInt(NACL_FID.SET_SHMEM),
        @bitCast(physical_address_low),
        @bitCast(physical_address_high),
        @bitCast(flags),
        SetSharedMemoryError,
    );
}

pub const SyncCsrError = error{
    /// The `FeatureId.sync_csr` feature is not available.
    NotSupported,

    /// `csr` is not all-ones bitwise and either:
    /// - `(csr.num & 0x300) != 0x200`
    /// - `csr.num >= 0x1000`
    /// - `csr.num` is not implemented by the SBI implementation
    InvalidParameter,

    /// Nested acceleration shared memory not available.
    NoSharedMemory,
};

/// Synchronize CSRs in the nested acceleration shared memory.
///
/// This is an optional function which is only available if the `FeatureId.sync_csr` feature is available.
///
/// The parameter `csr` specifies the set of RISC-V H-extension CSRs to be synchronized.
///
/// Available from SBI v2.0.
pub fn syncCsr(csr: Csr) SyncCsrError!void {
    try ecall.oneArgsNoReturnWithError(
        .NACL,
        @backingInt(NACL_FID.SYNC_CSR),
        @bitCast(csr.toRaw()),
        SyncCsrError,
    );
}

pub const SyncHfenceError = error{
    /// `FeatureId.sync_hfence` feature is not available.
    NotSupported,

    /// `entry` is not all-ones bitwise and `entry.index >= (3840 / XLEN)`.
    InvalidParameter,

    /// Nested acceleration shared memory not available.
    NoSharedMemory,
};

/// Synchronize HFENCEs in the nested acceleration shared memory.
///
/// This is an optional function which is only available if the `FeatureId.sync_hfence` feature is available.
///
/// The parameter `entry` specifies the set of nested HFENCE entries to be synchronized.
///
/// Available from SBI v2.0.
fn syncHfence(entry: HfenceEntry) SyncHfenceError!void {
    try ecall.oneArgsNoReturnWithError(
        .NACL,
        @backingInt(NACL_FID.SYNC_HFENCE),
        @bitCast(entry.toRaw()),
        SyncHfenceError,
    );
}

pub const SyncSretError = error{
    /// `FeatureId.sync_sret` feature is not available.
    NotSupported,

    /// Nested acceleration shared memory not available.
    NoSharedMemory,
};

/// Synchronize CSRs and HFENCEs in the nested acceleration shared memory and emulate the SRET instruction.
///
/// This is an optional function which is only available if the `FeatureId.sync_sret` feature is available.
///
/// This function is used by supervisor software (or L1 hypervisor) to do a synchronize SRET request and the SBI
/// implementation (or L0 hypervisor) MUST handle it as described in the SBI specification section 15.3.
///
/// This function does not return upon success.
///
/// Available from SBI v2.0.
pub fn syncSret() SyncSretError!noreturn {
    try ecall.zeroArgsNoReturnWithError(
        .NACL,
        @backingInt(NACL_FID.SYNC_SRET),
        SyncSretError,
    );
    unreachable;
}

pub const HfenceEntry = union(enum) {
    /// All nested HFENCE entries
    all,
    /// Encoding described in SBI specification section 15.2.
    index: usize,

    fn toRaw(self: HfenceEntry) usize {
        return switch (self) {
            .all => std.math.maxInt(usize),
            .index => |index| index,
        };
    }
};

pub const Csr = union(enum) {
    /// All RISC-V H-extension CSRs implemented by the SBI implementation (or L0 hypervisor)
    all,
    /// Encoding described in SBI specification section 15.1.
    num: usize,

    fn toRaw(self: Csr) usize {
        return switch (self) {
            .all => std.math.maxInt(usize),
            .num => |num| num,
        };
    }
};

pub const SharedMemory = union(enum) {
    disable,
    /// The size of the shared memory must be `4096 + (XLEN * 128)` bytes.
    enable: struct {
        /// MUST be 4096 bytes (i.e. page) aligned
        physical_address_low: usize,
        physical_address_high: usize,
    },

    fn toRaw(self: SharedMemory) struct { usize, usize } {
        return switch (self) {
            .disable => .{ 0, 0 },
            .enable => |enable| .{ enable.physical_address_low, enable.physical_address_high },
        };
    }
};

pub const SharedMemoryFlags = packed struct(usize) {
    _: usize = 0,
};

pub const FeatureId = enum(u32) {
    /// Synchronize CSR
    sync_csr = 0x00000000,

    /// Synchronize HFENCE
    sync_hfence = 0x00000001,

    /// Synchronize SRET
    sync_sret = 0x00000002,

    /// Autoswap CSR
    autoswap_csr = 0x00000003,

    /// 0x00000004 - 0xFFFFFFFF Reserved for future use
    _,
};

const NACL_FID = enum(i32) {
    PROBE_FEATURE = 0x0,
    SET_SHMEM = 0x1,
    SYNC_CSR = 0x2,
    SYNC_HFENCE = 0x3,
    SYNC_SRET = 0x4,
};
