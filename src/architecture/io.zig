const innigkeit = @import("innigkeit");
const core = @import("core");
const architecture = @import("architecture");

/// Read a value from PCI enhanced configuration space.
pub fn readPci(comptime T: type, address: innigkeit.KernelVirtualAddress) callconv(core.inline_in_non_debug) T {
    return switch (T) {
        u8 => architecture.getFunction(
            architecture.current_functions.io,
            "readPciU8",
        )(address),
        u16 => architecture.getFunction(
            architecture.current_functions.io,
            "readPciU16",
        )(address),
        u32 => architecture.getFunction(
            architecture.current_functions.io,
            "readPciU32",
        )(address),
        else => @compileError("unsupported pci read size"),
    };
}

/// Write a value to PCI enhanced configuration space.
pub fn writePci(comptime T: type, address: innigkeit.KernelVirtualAddress, value: T) callconv(core.inline_in_non_debug) void {
    switch (T) {
        u8 => architecture.getFunction(
            architecture.current_functions.io,
            "writePciU8",
        )(address, value),
        u16 => architecture.getFunction(
            architecture.current_functions.io,
            "writePciU16",
        )(address, value),
        u32 => architecture.getFunction(
            architecture.current_functions.io,
            "writePciU32",
        )(address, value),
        else => @compileError("unsupported pci write size"),
    }
}

pub const Port = struct {
    arch_specific: architecture.current_decls.io.Port,

    pub const FromError = error{InvalidPort};

    pub fn from(port: usize) FromError!Port {
        return .{
            .arch_specific = @enumFromInt(@import("std").math.cast(
                @typeInfo(architecture.current_decls.io.Port).@"enum".tag_type,
                port,
            ) orelse return error.InvalidPort),
        };
    }

    pub fn read(port: Port, comptime T: type) callconv(core.inline_in_non_debug) T {
        return switch (T) {
            u8 => architecture.getFunction(
                architecture.current_functions.io,
                "readPortU8",
            )(port.arch_specific),
            u16 => architecture.getFunction(
                architecture.current_functions.io,
                "readPortU16",
            )(port.arch_specific),
            u32 => architecture.getFunction(
                architecture.current_functions.io,
                "readPortU32",
            )(port.arch_specific),
            else => @compileError("unsupported port size"),
        };
    }

    pub fn write(port: Port, comptime T: type, value: T) callconv(core.inline_in_non_debug) void {
        switch (T) {
            u8 => architecture.getFunction(
                architecture.current_functions.io,
                "writePortU8",
            )(port.arch_specific, value),
            u16 => architecture.getFunction(
                architecture.current_functions.io,
                "writePortU16",
            )(port.arch_specific, value),
            u32 => architecture.getFunction(
                architecture.current_functions.io,
                "writePortU32",
            )(port.arch_specific, value),
            else => @compileError("unsupported port size"),
        }
    }
};
