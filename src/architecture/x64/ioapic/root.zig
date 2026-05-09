const std = @import("std");
const architecture = @import("architecture");
const x64 = @import("../x64.zig");

const SourceOverride = @import("SourceOverride.zig");
const globals = @import("globals.zig");
pub const init = @import("init.zig");
const IOAPIC = @import("IOAPIC.zig");

/// Get the EOI type for the given external interrupt if known.
pub fn eoiType(external_interrupt: u32) ?architecture.interrupts.Interrupt.Handler.EOI {
    const mapping = getMapping(@intCast(external_interrupt));
    return switch (mapping.trigger_mode) {
        .edge => .edge,
        .level => .level,
    };
}

pub fn routeInterrupt(
    interrupt: u8,
    vector: x64.interrupts.Interrupt,
) architecture.interrupts.Interrupt.RouteError!void {
    const mapping = getMapping(interrupt);
    const ioapic = getIOAPIC(mapping.gsi) catch return error.UnableToRouteExternalInterrupt;

    ioapic.setRedirectionTableEntry(
        @intCast(mapping.gsi - ioapic.gsi_base),
        vector,
        .fixed,
        .{ .physical = 0 }, // TODO: support routing to other/multiple processors
        mapping.polarity,
        mapping.trigger_mode,
        false,
    ) catch |err| {
        // TODO: return error
        std.debug.panic("failed to route interrupt {}: {t}!", .{ interrupt, err });
    };
}

fn getMapping(interrupt: u8) SourceOverride {
    return globals.source_overrides[interrupt] orelse .{
        .gsi = interrupt,
        .polarity = .active_high,
        .trigger_mode = .edge,
    };
}

fn getIOAPIC(gsi: u32) !IOAPIC {
    for (globals.io_apics.constSlice()) |io_apic| {
        if (gsi >= io_apic.gsi_base and gsi < (io_apic.gsi_base + io_apic.number_of_redirection_entries)) {
            return io_apic;
        }
    }
    return error.NoIOAPICForGSI;
}
