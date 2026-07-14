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
        0xF6B8F4B39DE7D1AE, 0xFAB91A6940FCB9CF,
        0x785C6ED015D3E316, 0x181E920A7852B9D9,
    },
};

pub const end_marker = extern struct {
    id: [2]u64 = [_]u64{
        0xADC0E0531BB10D03, 0x9572709F31764C62,
    },
};

comptime {
    std.testing.refAllDecls(@This());
}
