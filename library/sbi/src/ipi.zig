const base = @import("base.zig");
const HartMask = @import("HartMask.zig").HartMask;
const ecall = @import("ecall.zig");

pub fn available() bool {
    return base.probeExtension(.IPI);
}

pub const SendIPIError = error{
    /// Either hart_mask_base or at least one hartid from hart_mask is not valid, i.e., either the hartid is not
    /// enabled by the platform or is not available to the supervisor.
    InvalidParameter,

    /// The request failed for unspecified or unknown other reasons.
    Failed,
};

/// Send an inter-processor interrupt to all the harts defined in `hart_mask`.
///
/// Interprocessor interrupts manifest at the receiving harts as supervisor software interrupts.
///
/// Available from SBI v0.2.
pub fn sendIPI(hart_mask: HartMask) SendIPIError!void {
    const mask, const mask_base = hart_mask.toMaskAndBase();

    return ecall.twoArgsNoReturnWithError(
        .IPI,
        @backingInt(IPI_FID.SEND_IPI),
        mask,
        mask_base,
        SendIPIError,
    );
}

const IPI_FID = enum(i32) {
    SEND_IPI = 0x0,
};
