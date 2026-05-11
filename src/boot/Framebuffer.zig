//! Each pixel of the framebuffer is a 32-bit RGB value.

ptr: [*]volatile u32,
/// Width of the framebuffer in pixels
width: u64,
/// Height of the framebuffer in pixels
height: u64,
/// Pitch in bytes
pitch: u64,

red_mask_size: u8,
red_mask_shift: u8,
green_mask_size: u8,
green_mask_shift: u8,
blue_mask_size: u8,
blue_mask_shift: u8,
