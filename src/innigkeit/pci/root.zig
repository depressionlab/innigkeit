const core = @import("core");
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
        if (address.bus < ecam.start_bus or address.bus >= ecam.end_bus) continue;

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

// The size claimed below is metadata only (getFunction never dereferences the
// returned pointer in this test, only checks null vs. non-null), so it's safe
// to claim more than `scratch`'s real 4 KiB backs, as long as the address +
// claimed size still falls inside the kernel's virtual address window.
var pci_test_scratch: [4096]u8 align(4096) = undefined;

test "pci: getFunction matches any bus inside [start_bus, end_bus), not just start_bus" {
    const saved = globals.ecams;
    defer globals.ecams = saved;

    var ecams = [_]ECAM{.{
        .segment_group = 0,
        .start_bus = 5,
        .end_bus = 8,
        .config_space = .{
            .address = .fromPtr(&pci_test_scratch),
            .size = core.Size.from(1 << 21, .byte), // 2 MiB: covers bus_offset up to 1
        },
    }};
    globals.ecams = &ecams;

    // Bus 6 is inside [5, 8) but not equal to start_bus (5).
    try std.testing.expect(getFunction(.{ .segment = 0, .bus = 6, .device = 0, .function = 0 }) != null);

    // Bus 5 (== start_bus) still matches.
    try std.testing.expect(getFunction(.{ .segment = 0, .bus = 5, .device = 0, .function = 0 }) != null);

    // Bus 4 (before start_bus) and bus 8 (== end_bus, exclusive) do not match.
    try std.testing.expect(getFunction(.{ .segment = 0, .bus = 4, .device = 0, .function = 0 }) == null);
    try std.testing.expect(getFunction(.{ .segment = 0, .bus = 8, .device = 0, .function = 0 }) == null);
}
