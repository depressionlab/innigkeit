//! The bootloader can be told to start and/or stop searching for requests (including base revision tags) in an executable's loaded image
//! by placing start and/or end markers, on an 8-byte aligned boundary.
//!
//! The bootloader will only accept requests placed between the last start marker found (if there happen to be more than 1, which there
//! should not, ideally) and the first end marker found.
//!
//! For base revisions 0 and 1, the requests delimiters are *hints*. The bootloader can still search for requests and base revision tags
//! outside the delimited area if it doesn't support the hints.
//!
//! Base revision 2's sole difference compared to base revision 1 is that support for request delimiters has to be provided and the
//! delimiters must be honoured, if present, rather than them just being a hint.

const std = @import("std");

pub const start_marker = extern struct {
    id: [4]u64 = [_]u64{
        0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf,
        0x785c6ed015d3e316, 0x181e920a7852b9d9,
    },
};

pub const end_marker = extern struct {
    id: [2]u64 = [_]u64{
        0xadc0e0531bb10d03, 0x9572709f31764c62,
    },
};

comptime {
    std.testing.refAllDecls(@This());
}
