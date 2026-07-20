//! AArch64 exception vector table.
//!
//! The ARM Architecture Reference Manual requires the vector table base
//! (VBAR_EL1) to be aligned to 2 KiB (2^11); VBAR_EL1[10:0] are RES0, so an
//! unaligned table silently truncates and the CPU vectors into garbage. Each
//! of the 16 vectors occupies exactly 0x80 (128) bytes.
//!
//! A full register save/restore does NOT fit in 128 bytes, so each vector slot
//! is a tiny trampoline (allocate the frame, stash x0/x1, load the vector
//! index, branch to a shared out-of-line `vector_common`). `vector_common`
//! performs the full save, calls the Zig handler, restores, and `eret`s.
//!
//! The table lives in its own `.text.vectors` section which the arm linker
//! script places 2 KiB-aligned at the very start of `.text`, guaranteeing the
//! `vector_table` symbol address is a legal VBAR_EL1 value.

const arm = @import("arm.zig");
const gic = @import("gic.zig");
const innigkeit = @import("innigkeit");
const std = @import("std");

/// sizeof(InterruptFrame) = 31*8 + 8 + 8 + 8 = 272
const FRAME_SIZE = @sizeOf(arm.InterruptFrame);

comptime {
    if (FRAME_SIZE != 0x110) @compileError("InterruptFrame size changed. Update FRAME_SIZE");
}

/// Called from every exception vector entry with a pointer to the saved frame
/// and the vector index (0–15).
export fn arm_handle_exception(frame: *arm.InterruptFrame, vector_idx: u8) callconv(.c) void {
    // IRQ vectors (indices 1, 5, 9, 13) are dispatched through the GIC.
    // Vectors 4 (current-EL `SP_EL1` synchronous, i.e. a fault taken while
    // the kernel itself was running) and 8 (lower-EL AArch64 synchronous,
    // i.e. a fault or SVC taken from a user task) get a data-abort sub-dispatch.
    // Anything that isn't a recognized data abort falls through to the diagnostic
    // panic below. All other exceptions still panic until full handlers are implemented.
    switch (vector_idx) {
        1, 5, 9, 13 => {
            // Bracket IRQ dispatch with the generic interrupt-entry/exit hooks
            // (mirroring x64's interruptDispatch). onInterruptEntry bumps the
            // current task's interrupt_disable_count so that any lock/unlock
            // cycle inside the handler (e.g. the scheduler tick) cannot reach
            // count 0 and trigger maybePreempt(), but preempting here would run a
            // context switch on the IRQ entry stack, mid-exception-frame, and
            // corrupt the saved x30/elr restored at `eret`. Preemption is
            // instead deferred to the next decrementInterruptDisable(1->0) on
            // the task stack, after this exception returns.
            const state_before_interrupt = innigkeit.Task.Current.onInterruptEntry();
            defer state_before_interrupt.onInterruptExit();
            gic.handleIrq(frame, state_before_interrupt);
        },
        4, 8 => {
            const esr: arm.EsrEl1 = .read();
            switch (esr.ec) {
                .data_abort_lower_el, .data_abort_same_el => {
                    if (handleDataAbort(frame, esr, vector_idx == 8)) return;
                },
                else => {},
            }
            // Not a recognized or routable data abort (SVC, illegal instruction,
            // an `ESR.EC` we don't decode yet, or a data abort with FnV set/an
            // unmapped DFSC class). We fall through to the diagnostic panic below.
            dumpAndPanic(frame, vector_idx);
        },
        else => dumpAndPanic(frame, vector_idx),
    }
}

/// Dump fault state via semihosting and panic. Shared tail for every
/// exception vector not otherwise handled above.
fn dumpAndPanic(frame: *arm.InterruptFrame, vector_idx: u8) noreturn {
    // Dump fault state via semihosting first: during early init no output
    // device is registered yet, so a bare @panic would be silent. ESR/FAR/ELR
    // are the minimum needed to classify the fault (EC field of ESR, faulting
    // address, faulting PC).
    arm.semihost.write("\narm64 EXCEPTION vector=");
    arm.semihost.writeHex(vector_idx);
    arm.semihost.write(" ESR=");
    arm.semihost.writeHex(arm.registers.ESR_EL1.read());
    arm.semihost.write(" FAR=");
    arm.semihost.writeHex(arm.registers.FAR_EL1.read());
    arm.semihost.write(" ELR=");
    arm.semihost.writeHex(frame.elr);
    arm.semihost.write("\n");
    @panic(switch (vector_idx) {
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
    });
}

/// Decodes and, if possible, routes a data-abort exception to
/// `innigkeit.memory.onPageFault`.
///
/// Returns `true` if the fault was routed (caller returns from the
/// exception normally); `false` if this fault isn't one the kernel's fault
/// handler knows how to satisfy (an unrecognised `DataAbortIss.FaultClass`,
/// or `FnV` set so `FAR_EL1` can't be trusted) — the caller falls back to
/// the diagnostic panic exactly as before this routing existed.
///
/// `from_lower_el` is `true` for vector 8 (a fault taken from a user task
/// running at EL0), `false` for vector 4 (a fault taken while the kernel
/// itself was running at EL1 — e.g. `memory.safe.memcpy` touching a bad
/// user pointer).
fn handleDataAbort(frame: *arm.InterruptFrame, esr: arm.EsrEl1, from_lower_el: bool) bool {
    const iss = esr.dataAbort();
    if (iss.fnv) return false;

    const fault_class = iss.faultClass();
    if (fault_class == .other) return false;

    const state_before_interrupt = innigkeit.Task.Current.onInterruptEntry();
    defer state_before_interrupt.onInterruptExit();

    innigkeit.memory.onPageFault(.{
        .faulting_address = .from(arm.registers.FAR_EL1.read()),

        .access_type = if (iss.wnr) .write else .read,

        .fault_type = if (fault_class == .permission) .protection else .invalid,

        .faulting_context = if (from_lower_el)
            .user
        else
            .{
                .kernel = .{
                    .access_to_user_memory_enabled = state_before_interrupt.enable_access_to_user_memory_count != 0,
                },
            },
    }, .{ .arch_specific = frame });

    return true;
}

/// One 128-byte vector slot: allocate the frame, stash x0/x1 (so x1 can carry
/// the vector index as scratch), load the index, branch to `vector_common`.
///
/// This must assemble to <= 128 bytes; it is 4 instructions (16 bytes), leaving
/// the slot well within budget. The `.balign 0x80` aligns each slot to its
/// architectural 128-byte boundary relative to the 2 KiB-aligned table base.
fn vectorStub(comptime idx: u8) []const u8 {
    const idx_str = comptime std.fmt.comptimePrint("{d}", .{idx});
    return ".balign 0x80\n" ++
        \\ sub sp, sp, #272
        \\ stp x0, x1, [sp, #0]
        \\ mov x1, #
    ++ idx_str ++
        \\
        \\ b vector_common
        \\
    ;
}

// TODO: make sure all of this assembly is correct and the best way to do things

/// Shared out-of-line exception entry: completes the register save begun by the
/// stub (x0/x1 already stored at [sp,#0]), saves the remaining GPRs and the
/// system registers, calls `arm_handle_exception(frame, idx)`, then restores
/// and `eret`s.
export fn vector_common() callconv(.naked) noreturn {
    asm volatile (
    // x0/x1 already saved at [sp, #0] by the stub; x1 holds the vector index.
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
        \\ str x30, [sp, #240]
        // Save sp_el0, elr_el1, spsr_el1 (use x2 as scratch; already saved).
        \\ mrs x2, SP_EL0
        \\ str x2, [sp, #248]
        \\ mrs x2, ELR_EL1
        \\ str x2, [sp, #256]
        \\ mrs x2, SPSR_EL1
        \\ str x2, [sp, #264]
        // arm_handle_exception(frame = sp, vector_idx = x1).
        \\ mov x0, sp
        \\ bl arm_handle_exception
        // Restore spsr_el1, elr_el1, sp_el0.
        \\ ldr x2, [sp, #264]
        \\ msr SPSR_EL1, x2
        \\ ldr x2, [sp, #256]
        \\ msr ELR_EL1, x2
        \\ ldr x2, [sp, #248]
        \\ msr SP_EL0, x2
        // Restore x0–x30.
        \\ ldr x30, [sp, #240]
        \\ ldp x28, x29, [sp, #224]
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
    );
}

/// The AArch64 exception vector table.
///
/// Placed in the dedicated `.text.vectors` section (see the arm linker script),
/// which is 2 KiB-aligned at the start of `.text` so the `vector_table` symbol
/// is a legal VBAR_EL1 value. The 16 entries follow at their architectural
/// 128-byte offsets; each is a small stub that branches to `vector_common`.
pub export fn vector_table() linksection(".text.vectors") callconv(.naked) noreturn {
    asm volatile (
    // Entry 0x000: Current EL, SP_EL0, Synchronous
        vectorStub(0) ++
            // Entry 0x080: Current EL, SP_EL0, IRQ
            vectorStub(1) ++
            // Entry 0x100: Current EL, SP_EL0, FIQ
            vectorStub(2) ++
            // Entry 0x180: Current EL, SP_EL0, SError
            vectorStub(3) ++
            // Entry 0x200: Current EL, SP_EL1, Synchronous
            vectorStub(4) ++
            // Entry 0x280: Current EL, SP_EL1, IRQ
            vectorStub(5) ++
            // Entry 0x300: Current EL, SP_EL1, FIQ
            vectorStub(6) ++
            // Entry 0x380: Current EL, SP_EL1, SError
            vectorStub(7) ++
            // Entry 0x400: Lower EL (AArch64), Synchronous
            vectorStub(8) ++
            // Entry 0x480: Lower EL (AArch64), IRQ
            vectorStub(9) ++
            // Entry 0x500: Lower EL (AArch64), FIQ
            vectorStub(10) ++
            // Entry 0x580: Lower EL (AArch64), SError
            vectorStub(11) ++
            // Entry 0x600: Lower EL (AArch32), Synchronous
            vectorStub(12) ++
            // Entry 0x680: Lower EL (AArch32), IRQ
            vectorStub(13) ++
            // Entry 0x700: Lower EL (AArch32), FIQ
            vectorStub(14) ++
            // Entry 0x780: Lower EL (AArch32), SError
            vectorStub(15));
}
