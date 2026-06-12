const innigkeit = @import("innigkeit");
const x64 = @import("../x64.zig");

/// Signal end of interrupt.
pub fn eoi() void {
    globals.lapic.eoi();
}

/// Send a panic IPI to all other executors.
pub fn sendPanicIPI() void {
    var icr = globals.lapic.readInterruptCommandRegister();

    icr.vector = .non_maskable_interrupt;
    icr.delivery_mode = .nmi;
    icr.destination_mode = .physical;
    icr.level = .assert;
    icr.trigger_mode = .edge;
    icr.destination_shorthand = .all_excluding_self;
    icr.destination_field = .{ .x2apic = 0 };

    globals.lapic.writeInterruptCommandRegister(icr);
}

/// Send a flush IPI to the given executor.
pub fn sendFlushIPI(executor: *innigkeit.Executor) void {
    sendFixedIPI(.flush_request, executor);
}

/// Send a reschedule IPI to the given executor.
///
/// The handler is (nearly) empty; the IPI exists only to break the target out
/// of its idle `hlt` so it re-checks its runqueue immediately.
pub fn sendRescheduleIPI(executor: *innigkeit.Executor) void {
    sendFixedIPI(.reschedule, executor);
}

/// Send a fixed-delivery, edge-triggered IPI to one executor.
///
/// Interrupts are disabled across the ICR read-modify-write: reschedule IPIs
/// can be sent from interrupt context (wakeFromBlocked runs in the periodic
/// tick), and in xAPIC mode the ICR is two 32-bit registers (writing the low
/// half fires the IPI). An interleaved send from a nested interrupt would
/// otherwise corrupt an in-progress task-level send.
fn sendFixedIPI(vector: x64.interrupts.Interrupt, executor: *innigkeit.Executor) void {
    const interrupts_were_enabled = x64.instructions.interruptsEnabled();
    x64.instructions.disableInterrupts();
    defer if (interrupts_were_enabled) x64.instructions.enableInterrupts();

    var icr = globals.lapic.readInterruptCommandRegister();

    icr.vector = vector;
    icr.delivery_mode = .fixed;
    icr.destination_mode = .physical;
    icr.level = .assert;
    icr.trigger_mode = .edge;
    icr.destination_shorthand = .no_shorthand;

    const per_executor: *x64.PerExecutor = .from(executor);

    switch (globals.lapic) {
        .xapic => icr.destination_field.xapic.destination = @intCast(per_executor.apic_id),
        .x2apic => icr.destination_field.x2apic = per_executor.apic_id,
    }

    globals.lapic.writeInterruptCommandRegister(icr);
}

const globals = @import("globals.zig");
pub const init = @import("init.zig");
pub const LAPIC = @import("LAPIC.zig").LAPIC;
