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
    var icr = globals.lapic.readInterruptCommandRegister();

    icr.vector = .flush_request;
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
