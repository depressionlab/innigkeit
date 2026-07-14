const SourceOverride = @This();

const innigkeit = @import("innigkeit");
const IOAPIC = @import("IOAPIC.zig");
const std = @import("std");

gsi: u32,
polarity: IOAPIC.Polarity,
trigger_mode: IOAPIC.TriggerMode,

pub fn fromMADT(source_override: innigkeit.acpi.tables.MADT.InterruptControllerEntry.InterruptSourceOverride) SourceOverride {
    const polarity: IOAPIC.Polarity = switch (source_override.flags.polarity) {
        .conforms => .active_high,
        .active_high => .active_high,
        .active_low => .active_low,
        else => std.debug.panic(
            "unsupported polarity: {}!",
            .{source_override.flags.polarity},
        ),
    };

    const trigger_mode: IOAPIC.TriggerMode = switch (source_override.flags.trigger_mode) {
        .conforms => .edge,
        .edge_triggered => .edge,
        .level_triggered => .level,
        else => std.debug.panic(
            "unsupported trigger mode: {}!",
            .{source_override.flags.trigger_mode},
        ),
    };

    return .{
        .gsi = source_override.global_system_interrupt,
        .polarity = polarity,
        .trigger_mode = trigger_mode,
    };
}

pub inline fn format(self: SourceOverride, writer: *std.Io.Writer) !void {
    try writer.print("SourceOverride{{ .gsi = {d}, .polarity = {t}, .trigger_mode = {t} }}", .{
        self.gsi,
        self.polarity,
        self.trigger_mode,
    });
}
