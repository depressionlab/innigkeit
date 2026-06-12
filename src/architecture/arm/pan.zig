//! FEAT_PAN (Privileged Access Never) support (AArch64's SMAP equivalent).
//!
//! When `PSTATE.PAN == 1` any privileged (EL1) load or store to memory that is
//! accessible from EL0 faults. The kernel keeps PAN set at all times except
//! inside the guarded windows driven by `enableAccessToUserMemory` /
//! `disableAccessToUserMemory` below.
//!
//! FEAT_PAN is an ARMv8.1 extension, so support is detected at boot via
//! `ID_AA64MMFR1_EL1.PAN` (bits [23:20]); on cores without it (or emulators
//! configured without it) the toggles degrade to no-ops.

const innigkeit = @import("innigkeit");
const arm = @import("arm.zig");

const log = innigkeit.debug.log.scoped(.arm_pan);

/// Whether FEAT_PAN was detected on this machine.
///
/// Written during `init` (once per executor, always to the same value, before
/// any user task can run) and read on every user-memory window toggle.
pub var pan_available: bool = false;

/// `SCTLR_EL1.SPAN` (bit 23): when clear, taking an exception to EL1
/// automatically sets `PSTATE.PAN`, so kernel entry paths never inherit an
/// open user-access window from the interrupted context. The interrupted
/// context's own PAN bit is preserved in `SPSR_EL1` and restored by `eret`.
const SCTLR_EL1_SPAN: u64 = 1 << 23;

/// Detect FEAT_PAN and, if present, engage it for this executor.
///
/// Both `SCTLR_EL1` and `PSTATE` are per-PE state, so this must run on every
/// executor; `initExecutor` is the call site.
pub fn init() void {
    // ID_AA64MMFR1_EL1.PAN, bits [23:20]: 0 = not implemented,
    // 1 = FEAT_PAN, 2 = +FEAT_PAN2, 3 = +FEAT_PAN3.
    const pan_field: u4 = @truncate(arm.registers.ID_AA64MMFR1_EL1.read() >> 20);

    if (pan_field == 0) {
        log.warn("FEAT_PAN not implemented; kernel access to user memory is unrestricted", .{});
        return;
    }

    // Clear SCTLR_EL1.SPAN so PSTATE.PAN is set automatically on every
    // exception taken to EL1.
    arm.registers.SCTLR_EL1.write(arm.registers.SCTLR_EL1.read() & ~SCTLR_EL1_SPAN);
    arm.instructions.isb();

    // Close the user-memory window now; it is only opened inside the guarded
    // enable/disable windows.
    setPan();

    pan_available = true;

    log.debug("PAN enabled (ID_AA64MMFR1_EL1.PAN = {d}, PSTATE.PAN = {d})", .{
        pan_field,
        readPanBit(),
    });
}

/// Open the user-memory access window (PSTATE.PAN = 0).
///
/// No-op when FEAT_PAN is unsupported.
pub fn enableAccessToUserMemory() void {
    if (!pan_available) return;
    clearPan();
}

/// Close the user-memory access window (PSTATE.PAN = 1).
///
/// No-op when FEAT_PAN is unsupported.
pub fn disableAccessToUserMemory() void {
    if (!pan_available) return;
    setPan();
}

/// `msr PAN, #1`
///
/// Encoded as a raw instruction (MSR (immediate): op1=0b000, op2=0b100,
/// CRm=imm) so the assembler does not need the `pan` target feature.
/// Writes to PSTATE.PAN via MSR (immediate) are self-synchronising. No ISB
/// is required.
inline fn setPan() void {
    asm volatile (".inst 0xd500419f" ::: .{ .memory = true });
}

/// `msr PAN, #0` (see `setPan` for the encoding notes).
inline fn clearPan() void {
    asm volatile (".inst 0xd500409f" ::: .{ .memory = true });
}

/// Read the current PSTATE.PAN bit (`mrs <Xt>, PAN`, S3_0_C4_C2_3).
pub inline fn readPanBit() u1 {
    const value = asm ("mrs %[out], s3_0_c4_c2_3"
        : [out] "=r" (-> u64),
    );
    return @truncate(value >> 22);
}
