const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const Function = extern struct {
    full_configuration_space: [enhanced_configuration_space_size.value]u8 align(enhanced_configuration_space_size.value),

    pub const enhanced_configuration_space_size: core.Size = .from(4096, .byte);

    pub inline fn read(function: *const Function, comptime T: type, offset: usize) T {
        const size_offset: core.Size = .from(offset, .byte);

        if (core.is_debug) {
            std.debug.assert(size_offset.aligned(.of(T)));
            std.debug.assert(enhanced_configuration_space_size.greaterThanOrEqual(size_offset.add(.of(T))));
        }

        return architecture.io.readPci(
            T,
            innigkeit.KernelVirtualAddress.fromPtr(function).moveForward(size_offset),
        );
    }

    pub inline fn write(function: *Function, comptime T: type, offset: usize, value: T) void {
        const size_offset: core.Size = .from(offset, .byte);

        if (core.is_debug) {
            std.debug.assert(size_offset.aligned(.of(T)));
            std.debug.assert(enhanced_configuration_space_size.greaterThanOrEqual(size_offset.add(.of(T))));
        }

        return architecture.io.writePci(
            T,
            innigkeit.KernelVirtualAddress.fromPtr(function).moveForward(size_offset),
            value,
        );
    }

    comptime {
        core.testing.expectSize(Function, enhanced_configuration_space_size);
    }
};
