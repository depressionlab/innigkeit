const std = @import("std");

const globals = @import("globals.zig");
pub const Address = @import("Address.zig").Address;
pub const VendorID = @import("VendorID.zig").VendorID;
pub const DeviceID = @import("DeviceID.zig").DeviceID;
pub const Function = @import("Function.zig").Function;
pub const ECAM = @import("ECAM.zig");
pub const init = @import("init.zig");

/// Returns a `Function` representing the PCI function at 'address'.
pub fn getFunction(address: Address) ?*Function {
    for (globals.ecams) |ecam| {
        if (ecam.segment_group != address.segment) continue;
        if (ecam.start_bus < address.bus or address.bus >= ecam.end_bus) continue;

        const bus_offset: usize = address.bus - ecam.start_bus;

        const config_space_offset: usize = bus_offset << 20 |
            @as(usize, address.device) << 15 |
            @as(usize, address.function) << 12;

        std.debug.assert(ecam.config_space.size.value >= config_space_offset + @sizeOf(Function));

        return ecam.config_space.address
            .moveForward(.from(config_space_offset, .byte))
            .toPtr(*Function);
    }

    return null;
}
