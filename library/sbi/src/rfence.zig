const base = @import("base.zig");
const HartMask = @import("HartMask.zig").HartMask;
const ecall = @import("ecall.zig");

pub fn available() bool {
    return base.probeExtension(.RFENCE);
}

pub const RemoteFenceIError = error{
    /// Either hart_mask_base or at least one hartid from hart_mask is not valid, i.e., either the hartid is not
    /// enabled by the platform or is not available to the supervisor.
    InvalidParameter,

    /// The request failed for unspecified or unknown other reasons.
    Failed,
};

/// Instructs remote harts to execute `FENCE.I` instruction.
///
/// Available from SBI v0.2.
pub fn remoteFenceI(hart_mask: HartMask) RemoteFenceIError!void {
    const mask, const mask_base = hart_mask.toMaskAndBase();

    return ecall.twoArgsNoReturnWithError(
        .RFENCE,
        @backingInt(RFENCE_FID.FENCE_I),
        mask,
        mask_base,
        RemoteFenceIError,
    );
}

pub const RemoteSFenceVMAError = error{
    /// Either hart_mask_base or at least one hartid from hart_mask is not valid, i.e., either the hartid is not
    /// enabled by the platform or is not available to the supervisor.
    InvalidParameter,

    /// start_addr or size is not valid.
    InvalidAddress,

    /// The request failed for unspecified or unknown other reasons.
    Failed,
};

/// Instructs the remote harts to execute one or more `SFENCE.VMA` instructions, covering the range of
/// virtual addresses between `start_addr` and `start_addr + size`.
///
/// The remote fence operation applies to the entire address space if either:
///  - `start_addr` and `size` are both `0`
///  - `size` is equal to `2^XLEN-1`
///
/// Available from SBI v0.2.
pub fn remoteSFenceVMA(
    hart_mask: HartMask,
    start_addr: usize,
    size: usize,
) RemoteSFenceVMAError!void {
    const mask, const mask_base = hart_mask.toMaskAndBase();

    return ecall.fourArgsNoReturnWithError(
        .RFENCE,
        @backingInt(RFENCE_FID.SFENCE_VMA),
        mask,
        mask_base,
        @bitCast(start_addr),
        @bitCast(size),
        RemoteSFenceVMAError,
    );
}

pub const RemoteSFenceVMAWithASIDError = error{
    /// Either asid, hart_mask_base, or at least one hartid from hart_mask is not valid, i.e., either the hartid is
    /// not enabled by the platform or is not available to the supervisor.
    InvalidParameter,

    /// start_addr or size is not valid.
    InvalidAddress,

    /// The request failed for unspecified or unknown other reasons.
    Failed,
};

/// Instructs the remote harts to execute one or more `SFENCE.VMA` instructions, covering the range of virtual
/// addresses between `start_addr` and `start_addr + size`.
///
/// This covers only the given ASID.
///
/// The remote fence operation applies to the entire address space if either:
///  - `start_addr` and `size` are both `0`
///  - `size` is equal to `2^XLEN-1`
///
/// Available from SBI v0.2.
pub fn remoteSFenceVMAWithASID(
    hart_mask: HartMask,
    start_addr: usize,
    size: usize,
    asid: usize,
) RemoteSFenceVMAWithASIDError!void {
    const mask, const mask_base = hart_mask.toMaskAndBase();

    return ecall.fiveArgsNoReturnWithError(
        .RFENCE,
        @backingInt(RFENCE_FID.SFENCE_VMA_ASID),
        mask,
        mask_base,
        @bitCast(start_addr),
        @bitCast(size),
        @bitCast(asid),
        RemoteSFenceVMAWithASIDError,
    );
}

pub const RemoteHFenceGVMAWithVMIDError = error{
    /// This function is not supported as it is not implemented or one of the target hart doesn’t support
    /// hypervisor extension.
    NotSupported,

    /// Either vmid, hart_mask_base, or at least one hartid from hart_mask is not valid, i.e., either the hartid is
    /// not enabled by the platform or is not available to the supervisor.
    InvalidParameter,

    /// start_addr or size is not valid.
    InvalidAddress,

    /// The request failed for unspecified or unknown other reasons.
    Failed,
};

/// Instruct the remote harts to execute one or more `HFENCE.GVMA` instructions, covering the range of guest physical
/// addresses between `start_addr` and `start_addr + size` only for the given VMID.
///
/// The remote fence operation applies to the entire address space if either:
///  - `start_addr` and `size` are both `0`
///  - `size` is equal to `2^XLEN-1`
///
/// This function call is only valid for harts implementing hypervisor extension.
///
/// Available from SBI v0.2.
pub fn remoteHFenceGVMAWithVMID(
    hart_mask: HartMask,
    start_addr: usize,
    size: usize,
    vmid: usize,
) RemoteHFenceGVMAWithVMIDError!void {
    const mask, const mask_base = hart_mask.toMaskAndBase();

    return ecall.fiveArgsNoReturnWithError(
        .RFENCE,
        @backingInt(RFENCE_FID.HFENCE_GVMA_VMID),
        mask,
        mask_base,
        @bitCast(start_addr),
        @bitCast(size),
        @bitCast(vmid),
        RemoteHFenceGVMAWithVMIDError,
    );
}

pub const RemoteHFenceGVMAError = error{
    /// This function is not supported as it is not implemented or one of the target hart doesn’t support
    /// hypervisor extension.
    NotSupported,

    /// Either hart_mask_base or at least one hartid from hart_mask is not valid, i.e., either the hartid is
    /// not enabled by the platform or is not available to the supervisor.
    InvalidParameter,

    /// start_addr or size is not valid.
    InvalidAddress,

    /// The request failed for unspecified or unknown other reasons.
    Failed,
};

/// Instruct the remote harts to execute one or more `HFENCE.GVMA` instructions, covering the range of guest physical
/// addresses between `start_addr` and `start_addr + size` for all guests.
///
/// The remote fence operation applies to the entire address space if either:
///  - `start_addr` and `size` are both `0`
///  - `size` is equal to `2^XLEN-1`
///
/// This function call is only valid for harts implementing hypervisor extension.
///
/// Available from SBI v0.2.
pub fn remoteHFenceGVMA(
    hart_mask: HartMask,
    start_addr: usize,
    size: usize,
) RemoteHFenceGVMAError!void {
    const mask, const mask_base = hart_mask.toMaskAndBase();

    return ecall.fourArgsNoReturnWithError(
        .RFENCE,
        @backingInt(RFENCE_FID.HFENCE_GVMA),
        mask,
        mask_base,
        @bitCast(start_addr),
        @bitCast(size),
        RemoteHFenceGVMAError,
    );
}

pub const RemoteHFenceVVMAWithASIDError = error{
    /// This function is not supported as it is not implemented or one of the target hart doesn’t support
    /// hypervisor extension.
    NotSupported,

    /// Either asid, hart_mask_base, or at least one hartid from hart_mask is not valid, i.e., either the hartid is
    /// not enabled by the platform or is not available to the supervisor.
    InvalidParameter,

    /// start_addr or size is not valid.
    InvalidAddress,

    /// The request failed for unspecified or unknown other reasons.
    Failed,
};

/// Instruct the remote harts to execute one or more `HFENCE.VVMA` instructions, covering the range of guest virtual
/// addresses between `start_addr` and `start_addr + size` for the given ASID and current VMID (in hgatp CSR) of
/// calling hart.
///
/// The remote fence operation applies to the entire address space if either:
///  - `start_addr` and `size` are both `0`
///  - `size` is equal to `2^XLEN-1`
///
/// This function call is only valid for harts implementing hypervisor extension.
///
/// Available from SBI v0.2.
pub fn remoteHFenceVVMAWithASID(
    hart_mask: HartMask,
    start_addr: usize,
    size: usize,
    asid: usize,
) RemoteHFenceVVMAWithASIDError!void {
    const mask, const mask_base = hart_mask.toMaskAndBase();

    return ecall.fiveArgsNoReturnWithError(
        .RFENCE,
        @backingInt(RFENCE_FID.HFENCE_VVMA_ASID),
        mask,
        mask_base,
        @bitCast(start_addr),
        @bitCast(size),
        @bitCast(asid),
        RemoteHFenceVVMAWithASIDError,
    );
}

pub const RemoteHFenceVVMAError = error{
    /// This function is not supported as it is not implemented or one of the target hart doesn’t support
    /// hypervisor extension.
    NotSupported,

    /// Either hart_mask_base or at least one hartid from hart_mask is not valid, i.e., either the hartid is
    /// not enabled by the platform or is not available to the supervisor.
    InvalidParameter,

    /// start_addr or size is not valid.
    InvalidAddress,

    /// The request failed for unspecified or unknown other reasons.
    Failed,
};

/// Instruct the remote harts to execute one or more `HFENCE.VVMA` instructions, covering the range of guest virtual
/// addresses between `start_addr` and `start_addr + size` for current VMID (in hgatp CSR) of calling hart.
///
/// The remote fence operation applies to the entire address space if either:
///  - `start_addr` and `size` are both `0`
///  - `size` is equal to `2^XLEN-1`
///
/// This function call is only valid for harts implementing hypervisor extension.
///
/// Available from SBI v0.2.
pub fn remoteHFenceVVMA(
    hart_mask: HartMask,
    start_addr: usize,
    size: usize,
) RemoteHFenceVVMAError!void {
    const mask, const mask_base = hart_mask.toMaskAndBase();

    return ecall.fourArgsNoReturnWithError(
        .RFENCE,
        @backingInt(RFENCE_FID.HFENCE_VVMA),
        mask,
        mask_base,
        @bitCast(start_addr),
        @bitCast(size),
        RemoteHFenceVVMAError,
    );
}

const RFENCE_FID = enum(i32) {
    FENCE_I = 0x0,
    SFENCE_VMA = 0x1,
    SFENCE_VMA_ASID = 0x2,
    HFENCE_GVMA_VMID = 0x3,
    HFENCE_GVMA = 0x4,
    HFENCE_VVMA_ASID = 0x5,
    HFENCE_VVMA = 0x6,
};
