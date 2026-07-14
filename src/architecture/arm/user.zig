//! AArch64 userspace support: per-thread FP/SIMD state, thread lifecycle, and
//! first entry into EL0.

const architecture = @import("architecture");
const arm = @import("arm.zig");
const innigkeit = @import("innigkeit");

pub const PerThread = @import("PerThread.zig");
pub const SyscallFrame = @import("SyscallFrame.zig").SyscallFrame;

pub const init = struct {
    /// Perform any per-architecture initialization needed for userspace
    /// processes/threads.
    ///
    /// On x86-64 this allocates the variable-sized XSAVE area cache. On
    /// AArch64 the FP/SIMD state (`PerThread.FpsimdState`) is a fixed-size
    /// struct embedded directly in the thread, so no global cache is needed.
    pub fn initialize() !void {}
};

/// Create the `PerThread` data of a thread.
///
/// The AArch64 `PerThread` is an embedded fixed-size struct (no out-of-line
/// allocations), so creation just zero-initializes it.
pub fn createThread(thread: *innigkeit.user.Thread) innigkeit.memory.cache.ConstructorError!void {
    const per_thread: *PerThread = .from(thread);
    per_thread.* = .{};
}

/// Destroy the `PerThread` data of a thread.
///
/// Nothing to free: the state is embedded in the thread.
pub fn destroyThread(thread: *innigkeit.user.Thread) void {
    _ = thread;
}

/// Initialize the `PerThread` data of a thread.
pub fn initializeThread(thread: *innigkeit.user.Thread) void {
    const per_thread: *PerThread = .from(thread);
    per_thread.* = .{};
}

/// Enter userspace (EL0) for the first time in the current task.
///
/// Sets up SP_EL0, ELR_EL1 (entry PC) and SPSR_EL1 (target EL0, interrupts
/// enabled) then `eret`s into EL0. All general-purpose registers are cleared
/// except x0, which carries the entry argument.
pub fn enterUserspace(options: architecture.user.EnterUserspaceOptions) noreturn {
    arm.instructions.disableInterrupts();

    const per_thread: *PerThread = .from(.from(innigkeit.Task.Current.get().task));
    // Restore the user thread's thread-pointer register. FP/SIMD control
    // (fpsr/fpcr) is not restored here: a freshly created thread's
    // `fpsimd_state` defaults to zero, matching the CPU's own reset state, so
    // first entry needs no explicit FP/SIMD restore.
    arm.registers.TPIDR_EL0.write(per_thread.tpidr_el0);

    // SPSR_EL1 for an EL0t target: M[3:0] = 0b0000 (EL0, SP_EL0), DAIF clear
    // so the user runs with interrupts enabled.
    const spsr: u64 = 0;

    arm.registers.SP_EL0.write(options.stack_pointer.value);
    arm.registers.ELR_EL1.write(options.entry_point.value);
    arm.registers.SPSR_EL1.write(spsr);

    asm volatile (
        \\.cfi_sections .debug_frame
        \\.cfi_undefined lr
        \\ mov x0, %[arg]
        \\ mov x1, xzr
        \\ mov x2, xzr
        \\ mov x3, xzr
        \\ mov x4, xzr
        \\ mov x5, xzr
        \\ mov x6, xzr
        \\ mov x7, xzr
        \\ mov x8, xzr
        \\ mov x9, xzr
        \\ mov x10, xzr
        \\ mov x11, xzr
        \\ mov x12, xzr
        \\ mov x13, xzr
        \\ mov x14, xzr
        \\ mov x15, xzr
        \\ mov x16, xzr
        \\ mov x17, xzr
        \\ mov x18, xzr
        \\ mov x29, xzr
        \\ mov x30, xzr
        \\ eret
        :
        : [arg] "r" (options.arg),
    );

    unreachable;
}
