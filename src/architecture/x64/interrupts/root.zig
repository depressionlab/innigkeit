const innigkeit = @import("innigkeit");
const x64 = @import("../x64.zig");

pub const Interrupt = @import("Interrupt.zig").Interrupt;
pub const InterruptFrame = @import("InterruptFrame.zig").InterruptFrame;
pub const InterruptStackSelector = @import("InterruptStackSelector.zig").InterruptStackSelector;
pub const init = @import("init.zig");
const globals = @import("globals.zig");

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
