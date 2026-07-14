//! TPM Event Log Feature
//!
//! The bootloader captures the firmware event log via `EFI_TCG2_PROTOCOL.GetEventLog()` while boot services are alive and copies it into
//! memory that survives `ExitBootServices()`.
//!
//! The event stream covers all measurements made before handoff, including those performed by the bootloader itself.
//!
//! If a TPM is not available, or the firmware does not implement `EFI_TCG2_PROTOCOL`, or the event log retrieval fails, no response will be
//! provided.

const core = @import("core");
const innigkeit = @import("innigkeit");
const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x98E094FC7E76E979, 0xEE8D8775C54E1D1F),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    /// Format of the event log.
    format: Format,

    /// Size in bytes of the raw event data at `address`.
    size: core.Size,

    /// Address (HHDM, in bootloader reclaimable memory) of the captured TCG event log.
    ///
    /// The buffer holds the raw event stream as defined by the indicated `format`, with no additional framing.
    address: innigkeit.KernelVirtualAddress,

    pub const Format = enum(u64) {
        tcg_1_2 = 1,
        tcg_2 = 2,

        _,
    };
};
