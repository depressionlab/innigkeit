//! Firmware-interface layer (UEFI). Owns access to the EFI System Table the
//! bootloader hands us and, in later steps, the runtime-services calls used to
//! read the Secure Boot state.

pub const efi = @import("efi.zig");

/// Probe firmware interfaces at boot and log what we found. Safe on any
/// platform (no-op / log-only when not booted via EFI).
pub fn init() void {
    efi.init();
}
