const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const Function = extern struct {
    full_configuration_space: [enhanced_configuration_space_size.value]u8 align(enhanced_configuration_space_size.value),

    pub const enhanced_configuration_space_size: core.Size = .from(4096, .byte);

    pub inline fn read(self: *const Function, comptime T: type, offset: usize) T {
        const size_offset: core.Size = .from(offset, .byte);

        if (core.is_debug) {
            std.debug.assert(size_offset.aligned(.of(T)));
            std.debug.assert(enhanced_configuration_space_size.greaterThanOrEqual(size_offset.add(.of(T))));
        }

        return architecture.io.readPci(
            T,
            innigkeit.KernelVirtualAddress.fromPtr(self).moveForward(size_offset),
        );
    }

    pub inline fn write(self: *Function, comptime T: type, offset: usize, value: T) void {
        const size_offset: core.Size = .from(offset, .byte);

        if (core.is_debug) {
            std.debug.assert(size_offset.aligned(.of(T)));
            std.debug.assert(enhanced_configuration_space_size.greaterThanOrEqual(size_offset.add(.of(T))));
        }

        return architecture.io.writePci(
            T,
            innigkeit.KernelVirtualAddress.fromPtr(self).moveForward(size_offset),
            value,
        );
    }

    /// PCI configuration "Interrupt Line" register (offset 0x3c).
    ///
    /// On QEMU q35 firmware programs this with the GSI the function's INTx
    /// pin is routed to (16-23 for PCI slots).
    pub inline fn interruptLine(self: *const Function) u8 {
        return self.read(u8, 0x3c);
    }

    /// PCI configuration "Interrupt Pin" register (offset 0x3d).
    ///
    /// 0 = the function does not use an interrupt pin, 1-4 = INTA#-INTD#.
    pub inline fn interruptPin(self: *const Function) u8 {
        return self.read(u8, 0x3d);
    }

    comptime {
        core.testing.expectSize(Function, enhanced_configuration_space_size);
    }
};
