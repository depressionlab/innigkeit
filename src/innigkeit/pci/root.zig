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

/// Call `callback(address, function)` for every present PCI function.
///
/// Skips buses covered by no ECAM, absent devices (vendor == `0xFFFF`), and
/// non-present functions on single-function devices
pub fn forEachFunction(callback: *const fn (Address, *Function) void) void {
    for (globals.ecams) |ecam| {
        var bus = ecam.start_bus;
        while (bus < ecam.end_bus) : (bus +%= 1) {
            var device: u8 = 0;
            while (device < 32) : (device += 1) {
                const addr0: Address = .{
                    .segment = ecam.segment_group,
                    .bus = bus,
                    .device = device,
                    .function = 0,
                };
                const f0 = getFunction(addr0) orelse continue;
                if (f0.read(u16, 0x00) == 0xFFFF) continue; // absent
                callback(addr0, f0);

                // header type bit 7 = multifunction
                const header_type = f0.read(u8, 0x0E);
                if (header_type & 0x80 == 0) continue;

                var function: u8 = 1;
                while (function < 8) : (function += 1) {
                    const addr: Address = .{
                        .segment = ecam.segment_group,
                        .bus = bus,
                        .device = device,
                        .function = function,
                    };
                    const f = getFunction(addr) orelse continue;
                    if (f.read(u16, 0x00) == 0xFFFF) continue;
                    callback(addr, f);
                }
            }
        }
    }
}
