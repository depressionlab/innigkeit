//! Paging Mode Feature
//!
//! The Paging Mode feature allows the executable to control which paging mode is enabled before control is passed to it.
//!
//! The response indicates which paging mode was actually enabled by the bootloader.
//!
//! Executables must be prepared to handle the case where the requested paging mode is not supported by the hardware.
//!
//! If no Paging Mode Request is provided, the values of `mode`, `max_mode`, and `min_mode` that the bootloader assumes are
//! `PagingMode.default_mode`, `PagingMode.max_mode`, and `PagingMode.min_mode`, respectively.
//!
//! If request revision 0 is used, the values of `max_mode` and `min_mode` that the bootloader assumes are the value of `mode` and
//! `PagingMode.min_mode`, respectively.

const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x95c1a0edab0944cb, 0xa4e5cb3842f7488a),
    revision: u64 = 0,

    response: ?*const Response = null,

    /// The preferred paging mode by the OS.
    ///
    /// The bootloader should always aim to pick this mode unless unavailable or overridden by the user in the bootloader's configuration
    /// file.
    mode: Mode = .default,

    // Request revision 1 and above

    /// The highest paging mode that the OS supports.
    ///
    /// The bootloader will refuse to boot the OS if no paging modes of this type or lower (but equal or greater than `min_mode`) are
    /// available.
    max_mode: Mode,

    /// The lowest paging mode that the OS supports.
    ///
    /// The bootloader will refuse to boot the OS if no paging modes of this type or greater (but equal or lower than `max_mode`) are
    /// available.
    min_mode: Mode = .default_min,
};

pub const Response = extern struct {
    revision: u64,

    /// Which paging mode was actually enabled by the bootloader.
    ///
    /// Executables must be prepared to handle the case where the requested paging mode is not supported by the hardware.
    mode: Mode,

    pub inline fn format(self: *const Response, writer: *std.Io.Writer) !void {
        try writer.print("PagingMode({t})", .{self.mode});
    }
};

pub const Mode = switch (root.arch) {
    .aarch64 => enum(u64) {
        four_level,
        five_level,
        _,

        pub const default: @This() = .four_level;
        pub const default_min: @This() = .four_level;
    },
    .loongarch64 => enum(u64) {
        four_level,
        _,

        pub const default: @This() = .four_level;
        pub const default_min: @This() = .four_level;
    },
    .riscv64 => enum(u64) {
        /// Three level paging
        sv39,

        /// Four level paging
        sv48,

        /// Five level paging
        sv57,

        _,

        pub const default: @This() = .sv48;
        pub const default_min: @This() = .sv39;
    },
    .x86_64 => enum(u64) {
        four_level,
        five_level,
        _,

        pub const default: @This() = .four_level;
        pub const default_min: @This() = .four_level;
    },
};
