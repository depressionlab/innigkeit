//! This feature provides the parameters used by the bootloader to initialise its [Flanterm](https://codeberg.org/Mintsuki/Flanterm)
//! framebuffer terminal instances.
//!
//! This allows the executable to initialise Flanterm in the same way as the bootloader, reproducing the same terminal appearance
//! (wallpaper, colours, font, etc.).
//!
//! Entries in this response correspond by index to framebuffers in the Framebuffer response.
//!
//! If a framebuffer does not support a Flanterm terminal (e.g. non-32bpp), its entry will be zeroed.
//!
//! This feature requires the Framebuffer Feature to also be requested. If no framebuffers are available, no response will be provided.

const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x3259399fe7c5f126, 0xe01c1c8c5db9d1a9),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    _init_params_count: u64,
    _init_params: [*]?*const FBInitParams,

    pub fn initParams(response: *const Response) []?*const FBInitParams {
        return response._init_params[0..response._init_params_count];
    }

    pub const FBInitParams = extern struct {
        /// Pointer to a pre-rendered background canvas buffer, or `null` if no wallpaper is configured.
        ///
        /// The buffer is `canvas_size` bytes and contains 32-bit pixels in the same format as the associated framebuffer, laid out at
        /// the framebuffer's width and height.
        canvas: ?[*]const u32,

        /// Size of the canvas buffer in bytes.
        canvas_size: u64,

        /// The 8 standard ANSI colours (black, red, green, brown, blue, magenta, cyan, grey).
        ansi_colors: [8]u32,

        /// The 8 bright ANSI colours.
        ansi_bright_colors: [8]u32,

        /// Default background colour.
        default_bg: u32,

        /// Default foreground colour.
        default_fg: u32,

        /// Default bright background colour.
        default_bg_bright: u32,

        /// Default bright foreground colour.
        default_fg_bright: u32,

        /// Pointer to VGA-style font bitmap data, with 256 glyphs. This points to
        /// the actual font data, including the built-in default font if no custom
        /// font is configured. Its size in bytes is `font_width * font_height * 256 / 8`.
        font: ?*const anyopaque,

        /// Font character width in pixels (always 8 for VGA fonts).
        font_width: u64,

        /// Font character height in pixels.
        font_height: u64,

        /// Extra horizontal spacing between characters in pixels.
        font_spacing: u64,

        /// Horizontal font scale factor.
        font_scale_x: u64,

        /// Vertical font scale factor.
        font_scale_y: u64,

        /// Terminal margin in pixels from the screen edge.
        margin: u64,

        /// Display rotation.
        rotation: Rotation,

        pub const Rotation = enum(u64) {
            @"0" = 0,
            @"90" = 1,
            @"180" = 2,
            @"270" = 3,
        };
    };
};
