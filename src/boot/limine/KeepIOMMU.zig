//! If this feature is requested, the bootloader will not disable IOMMUs (Intel VT-d, AMD-Vi) that were left enabled by the firmware at
//! hand-off. This is intended for security-conscious executables that wish to preserve DMA protection set up by firmware.
//!
//! If this feature is not requested, the bootloader reserves the right to disable any active IOMMUs before handing control to the
//! executable, for compatibility with executables that do not support these.
//!
//! Note: Not passing this request does not imply that the bootloader is mandated to disable the IOMMUs, though newly implemented
//! bootloaders are strongly recommended to, and should, disable them.
//!
//! Note: On non-x86 platforms, no response will be provided.

const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x8ebaabe51f490179, 0x2aa86a59ffb4ab0f),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,
};
