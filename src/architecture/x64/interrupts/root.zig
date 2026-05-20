const std = @import("std");
const innigkeit = @import("innigkeit");
const x64 = @import("../x64.zig");

pub const Interrupt = @import("Interrupt.zig").Interrupt;
pub const InterruptFrame = @import("InterruptFrame.zig").InterruptFrame;
pub const InterruptStackSelector = @import("InterruptStackSelector.zig").InterruptStackSelector;
pub const init = @import("init.zig");
const globals = @import("globals.zig");

// See src/architecture/x64/asm for stupid implementation!

/// Assembly trampoline called by every interrupt stub instead of `interruptDispatch` directly.
///
/// For ring3 -> ring0 interrupts the stub's frame is already on the dedicated IRQ
/// stack (the CPU used TSS.RSP0 which points there).
///
/// For ring0 -> ring0 interrupts the stub's frame is on the task's kernel stack.
/// We do NOT switch to the shared IRQ stack here — doing so would require
/// saving the task RSP at a fixed per-CPU location (irq_top-8), which any
/// subsequent ring0 -> ring0 interrupt could overwrite, corrupting the saved RSP.
/// The task kernel stack is 32 KiB and can safely absorb the interrupt frame.
///
/// Both paths tail-jump to `interruptDispatch`, which returns directly to the stub.
export fn _interruptEntry() callconv(.naked) void {
    asm volatile (
        \\jmp interruptDispatch
    );
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
