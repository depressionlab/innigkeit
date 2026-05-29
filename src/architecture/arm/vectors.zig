//! AArch64 exception vector table.
//!
//! The ARM Architecture Reference Manual requires the vector table to be
//! aligned to 2 KiB (2^11). Each of the 16 vectors occupies exactly 0x80
//! (128) bytes. We implement them as `naked` Zig functions placed in a
//! dedicated section and referenced by a linker symbol; `VBAR_EL1` is then
//! set to the address of that section during `initExecutor`.

const std = @import("std");
const arm = @import("arm.zig");
const InterruptFrame = @import("InterruptFrame.zig").InterruptFrame;
const gic = @import("gic.zig");

/// sizeof(InterruptFrame) = 31*8 + 8 + 8 + 8 = 272
const FRAME_SIZE = @sizeOf(InterruptFrame);

comptime {
    if (FRAME_SIZE != 272) @compileError("InterruptFrame size changedk. Update FRAME_SIZE");
}

/// Called from every exception vector entry with a pointer to the saved frame
/// and the vector index (0–15).
///
/// For now this just panics; a real kernel would dispatch to IRQ, syscall,
/// and fault handlers here.
export fn arm_handle_exception(frame: *InterruptFrame, vector_idx: u8) callconv(.c) void {
    _ = frame;
    // IRQ vectors (indices 1, 5, 9, 13) are dispatched through the GIC.
    // All other exceptions still panic until full handlers are implemented.
    switch (vector_idx) {
        1, 5, 9, 13 => gic.handleIrq(),
        else => @panic(switch (vector_idx) {
            0 => "arm64: exception: current-EL SP_EL0 synchronous",
            2 => "arm64: exception: current-EL SP_EL0 FIQ",
            3 => "arm64: exception: current-EL SP_EL0 SError",
            4 => "arm64: exception: current-EL SP_EL1 synchronous",
            6 => "arm64: exception: current-EL SP_EL1 FIQ",
            7 => "arm64: exception: current-EL SP_EL1 SError",
            8 => "arm64: exception: lower-EL AArch64 synchronous",
            10 => "arm64: exception: lower-EL AArch64 FIQ",
            11 => "arm64: exception: lower-EL AArch64 SError",
            12 => "arm64: exception: lower-EL AArch32 synchronous",
            14 => "arm64: exception: lower-EL AArch32 FIQ",
            15 => "arm64: exception: lower-EL AArch32 SError",
            else => "arm64: exception: unknown vector",
        }),
    }
}

/// Generates the save/call/restore assembly for one exception vector entry.
///
/// Layout of InterruptFrame on the stack (SP points to x[0]):
///   [sp +   0] x0  ... x[29]   (30x8 = 240 bytes, stored as 15 pairs)
///   [sp + 240] x30            (8 bytes / link register)
///   [sp + 248] sp_el0         (8 bytes)
///   [sp + 256] elr            (8 bytes)
///   [sp + 264] spsr           (8 bytes)
///   total = 272 bytes
fn vectorAsm(comptime idx: u8) []const u8 {
    const idx_str = comptime std.fmt.comptimePrint("{d}", .{idx});
    return
    // Allocate frame
    \\ sub sp, sp, #272
    // Save x0–x29 as pairs
    \\ stp x0,  x1,  [sp, #0]
    \\ stp x2,  x3,  [sp, #16]
    \\ stp x4,  x5,  [sp, #32]
    \\ stp x6,  x7,  [sp, #48]
    \\ stp x8,  x9,  [sp, #64]
    \\ stp x10, x11, [sp, #80]
    \\ stp x12, x13, [sp, #96]
    \\ stp x14, x15, [sp, #112]
    \\ stp x16, x17, [sp, #128]
    \\ stp x18, x19, [sp, #144]
    \\ stp x20, x21, [sp, #160]
    \\ stp x22, x23, [sp, #176]
    \\ stp x24, x25, [sp, #192]
    \\ stp x26, x27, [sp, #208]
    \\ stp x28, x29, [sp, #224]
    // Save x30 (link register)
    \\ str x30, [sp, #240]
    // Save sp_el0, elr_el1, spsr_el1
    \\ mrs x0, SP_EL0
    \\ str x0, [sp, #248]
    \\ mrs x0, ELR_EL1
    \\ str x0, [sp, #256]
    \\ mrs x0, SPSR_EL1
    \\ str x0, [sp, #264]
    // Call Zig handler: arm_handle_exception(frame: *InterruptFrame, vector_idx: u8)
    \\ mov x0, sp
    \\ mov x1, #
    ++ idx_str ++
        \\
        \\ bl arm_handle_exception
        // Restore spsr_el1, elr_el1, sp_el0
        \\ ldr x0, [sp, #264]
        \\ msr SPSR_EL1, x0
        \\ ldr x0, [sp, #256]
        \\ msr ELR_EL1, x0
        \\ ldr x0, [sp, #248]
        \\ msr SP_EL0, x0
        // Restore x0–x30
        \\ ldp x28, x29, [sp, #224]
        \\ ldr x30, [sp, #240]
        \\ ldp x26, x27, [sp, #208]
        \\ ldp x24, x25, [sp, #192]
        \\ ldp x22, x23, [sp, #176]
        \\ ldp x20, x21, [sp, #160]
        \\ ldp x18, x19, [sp, #144]
        \\ ldp x16, x17, [sp, #128]
        \\ ldp x14, x15, [sp, #112]
        \\ ldp x12, x13, [sp, #96]
        \\ ldp x10, x11, [sp, #80]
        \\ ldp x8,  x9,  [sp, #64]
        \\ ldp x6,  x7,  [sp, #48]
        \\ ldp x4,  x5,  [sp, #32]
        \\ ldp x2,  x3,  [sp, #16]
        \\ ldp x0,  x1,  [sp, #0]
        \\ add sp, sp, #272
        \\ eret
    ;
}

// The vector table label
//
// We need the label `vector_table` to be at 2 KiB alignment. The linker
// script for arm places `.text.vectors` first and the section itself carries
// .p2align 11. All 16 entry stubs follow in order so each one lands at its
// correct offset (vec_N at offset N*0x80).
//
// Because we cannot guarantee that the Zig compiler will place 16 separate
// export functions contiguously and aligned, we implement the entire vector
// table as a single naked function that contains all 16 0x80-byte stubs via
// inline assembly. The first stub IS the vector table; VBAR_EL1 is set to
// its address.

/// The AArch64 exception vector table.
/// Must be aligned to 2 KiB (2^11). VBAR_EL1 is set to the address of this
/// symbol during `initExecutor`.
///
/// The table has 16 entries of 128 bytes each. Each entry saves the full
/// register state, calls `arm_handle_exception`, then restores and returns
/// via `eret`.
pub export fn vector_table() callconv(.naked) noreturn {
    // Entry 0x000: Current EL, SP_EL0, Synchronous
    asm volatile (".p2align 11\n" ++ vectorAsm(0));
    // Entry 0x080: Current EL, SP_EL0, IRQ
    asm volatile (".p2align 7\n" ++ vectorAsm(1));
    // Entry 0x100: Current EL, SP_EL0, FIQ
    asm volatile (".p2align 7\n" ++ vectorAsm(2));
    // Entry 0x180: Current EL, SP_EL0, SError
    asm volatile (".p2align 7\n" ++ vectorAsm(3));
    // Entry 0x200: Current EL, SP_EL1, Synchronous
    asm volatile (".p2align 7\n" ++ vectorAsm(4));
    // Entry 0x280: Current EL, SP_EL1, IRQ
    asm volatile (".p2align 7\n" ++ vectorAsm(5));
    // Entry 0x300: Current EL, SP_EL1, FIQ
    asm volatile (".p2align 7\n" ++ vectorAsm(6));
    // Entry 0x380: Current EL, SP_EL1, SError
    asm volatile (".p2align 7\n" ++ vectorAsm(7));
    // Entry 0x400: Lower EL (AArch64), Synchronous
    asm volatile (".p2align 7\n" ++ vectorAsm(8));
    // Entry 0x480: Lower EL (AArch64), IRQ
    asm volatile (".p2align 7\n" ++ vectorAsm(9));
    // Entry 0x500: Lower EL (AArch64), FIQ
    asm volatile (".p2align 7\n" ++ vectorAsm(10));
    // Entry 0x580: Lower EL (AArch64), SError
    asm volatile (".p2align 7\n" ++ vectorAsm(11));
    // Entry 0x600: Lower EL (AArch32), Synchronous
    asm volatile (".p2align 7\n" ++ vectorAsm(12));
    // Entry 0x680: Lower EL (AArch32), IRQ
    asm volatile (".p2align 7\n" ++ vectorAsm(13));
    // Entry 0x700: Lower EL (AArch32), FIQ
    asm volatile (".p2align 7\n" ++ vectorAsm(14));
    // Entry 0x780: Lower EL (AArch32), SError
    asm volatile (".p2align 7\n" ++ vectorAsm(15));
}
