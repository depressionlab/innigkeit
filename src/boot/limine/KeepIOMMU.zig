//! If this feature is requested, the bootloader will not disable IOMMUs (Intel VT-d, AMD-Vi) that were left enabled by the firmware at
//! hand-off. This is intended for security-conscious executables that wish to preserve DMA protection set up by firmware.
//!
//! If this feature is not requested, the bootloader reserves the right to disable any active IOMMUs before handing control to the
//! executable. This is especially of note for base revisions 5 and greater, where the bootloader is mandated to disable VT-d and AMD-Vi
//! IOMMUs, unless this feature is requested.
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
