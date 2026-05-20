const std = @import("std");
const innigkeit = @import("innigkeit");
const x64 = @import("../x64.zig");

pub const Interrupt = @import("Interrupt.zig").Interrupt;
pub const InterruptFrame = @import("InterruptFrame.zig").InterruptFrame;
pub const InterruptStackSelector = @import("InterruptStackSelector.zig").InterruptStackSelector;
pub const init = @import("init.zig");
const globals = @import("globals.zig");

/// Assembly trampoline called by every interrupt stub instead of `interruptDispatch` directly.
///
/// For ring3 -> ring0 interrupts the stub's frame is already on the dedicated IRQ
/// stack (the CPU used TSS.RSP0 which points there), so we tail-jump straight
/// to `interruptDispatch`.
///
/// For ring0 -> ring0 interrupts the stub's frame is on the task stack. We save
/// the original RSP, switch execution to the per-CPU IRQ stack (read via GS),
/// call `interruptDispatch`, restore RSP, and `ret` back into the stub so it
/// can pop the saved GPRs and execute `iretq`, all from the task stack.
export fn _interruptEntry() callconv(.naked) void {
    asm volatile (std.fmt.comptimePrint(
            // rdi = frame pointer (set by the stub: `mov %%rsp, %%rdi`).
            // Check CS bits 0-1 to distinguish ring0 from ring3.
            \\testl $3, {[cs_offset]}(%rdi)
            \\jnz 1f
            \\
            // ring0 -> ring0: frame is on the task stack; switch to IRQ stack.
            // rsp currently points at the return address the stub pushed with
            // `call _interruptEntry`.  Save that whole task-stack context by
            // stashing rsp on the IRQ stack, then call the real dispatcher.
            \\mov %rsp, %r10
            \\mov %gs:{[irq_top_offset]}, %rsp
            \\push %r10
            \\call interruptDispatch
            \\pop %rsp
            \\ret
            \\
            \\1:
            // ring3→ring0: frame is already on the IRQ stack (CPU used RSP0).
            // Tail-jump so interruptDispatch returns directly to the stub.
            \\jmp interruptDispatch
        , .{
            .cs_offset = @offsetOf(InterruptFrame, "cs"),
            .irq_top_offset = @offsetOf(innigkeit.Task, "arch_specific") +
                @offsetOf(x64.PerTask, "irq_stack_top"),
        }));
}

export fn interruptDispatch(interrupt_frame: *InterruptFrame) callconv(.c) void {
    const state_before_interrupt = innigkeit.Task.Current.onInterruptEntry();
    defer state_before_interrupt.onInterruptExit();

    switch (interrupt_frame.cs.selector) {
        .kernel_code => {},
        .user_code, .user_code_32bit => x64.instructions.disableSSEUsage(),
        else => unreachable,
    }
    defer switch (interrupt_frame.cs.selector) {
        .user_code, .user_code_32bit => {
            const per_thread: *x64.user.PerThread = .from(.from(innigkeit.Task.Current.get().task));
            x64.instructions.enableSSEUsage();
            per_thread.extended_state.load();
        },
        .kernel_code => {},
        else => unreachable,
    };

    var handler = globals.handlers[interrupt_frame.vector_number.full];
    handler.call.setTemplatedArgs(.{ .{ .arch_specific = interrupt_frame }, state_before_interrupt });

    switch (handler.eoi) {
        .none => handler.call.call(),
        .after => {
            handler.call.call();
            x64.apic.eoi();
        },
        .before => {
            x64.apic.eoi();
            handler.call.call();
        },
    }

    x64.instructions.disableInterrupts();
}
