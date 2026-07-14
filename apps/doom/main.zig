//! DOOM for Innigkeit entry point.
//!
//! Calls doomgeneric_Create (C) then loops on doomgeneric_Tick (C).
//! All C sources in `doomgeneric/` are compiled as part of this module
//! via the custom App configuration in `apps/root.zig`.

const builtin = @import("builtin");

// Pull in the C syscall exports so they are linked.
const _syscalls = @import("syscalls.zig");
// libc.zig uses std.builtin.VaList which is disabled on non-x86_64 in stage2_llvm.
// On other architectures doom uses doom_stub.c so the C-level libc exports aren't needed.
const _libc = if (builtin.cpu.arch == .x86_64) @import("libc.zig") else struct {};
comptime {
    _ = _syscalls;
    _ = _libc;
}

// Forward declarations for the C functions we call.
extern fn doomgeneric_Create(argc: c_int, argv: [*][*:0]u8) callconv(.c) void;
extern fn doomgeneric_Tick() callconv(.c) void;

pub fn main() void {
    // Build a minimal argv: ["doom", "-iwad", "/doom1.wad"]
    var arg0: [5:0]u8 = "doom\x00".*;
    var arg1: [6:0]u8 = "-iwad\x00".*;
    var arg2: [11:0]u8 = "/doom1.wad\x00".*;
    var argv = [_][*:0]u8{ &arg0, &arg1, &arg2 };

    doomgeneric_Create(argv.len, &argv);

    while (true) {
        doomgeneric_Tick();
    }
}
