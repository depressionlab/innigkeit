const innigkeit = @import("innigkeit");

pub const PL011 = @import("PL011.zig");
pub const Baud = @import("Baud.zig");
const Uart16X50 = @import("Uart16X50.zig").Uart16X50;

pub const Uart = union(enum) {
    io_port_16550: IoPort16550,
    memory_16550: Memory16550,
    io_port_16450: IoPort16450,
    memory_16450: Memory16450,

    pl011: PL011,

    pub fn output(uart: *Uart) innigkeit.init.Output {
        switch (uart.*) {
            inline else => |*u| return u.output(),
        }
    }
};

pub const IoPort16550 = Uart16X50(.io_port, .enabled);
pub const Memory16550 = Uart16X50(.memory, .enabled);
pub const IoPort16450 = Uart16X50(.io_port, .disabled);
pub const Memory16450 = Uart16X50(.memory, .disabled);

pub const Uart16X50Type = enum {
    @"16450",
    @"16550",
};

pub fn tryGetSerialOutput16X50(
    comptime uart_type: Uart16X50Type,
    base_address: u64,
    mode: Mode,
    baud_rate: ?Baud.BaudRate,
    memory_system_available: bool,
) !Uart {
    const baud: ?Baud = if (baud_rate) |br| .{
        .clock_frequency = .@"1.8432 MHz", // TODO: we assume the clock frequency is 1.8432 MHz
        .baud_rate = br,
    } else null;

    switch (mode) {
        .memory => {
            if (!memory_system_available) return error.RequiresMemorySystem; // TODO: early mmio pages

            const UartT = switch (uart_type) {
                .@"16450" => Memory16450,
                .@"16550" => Memory16550,
            };

            const register_range = try innigkeit.mem.heap.allocateSpecial(
                .{
                    .physical_range = .from(
                        .from(base_address),
                        UartT.register_region_size,
                    ),
                    .protection = .{ .read = true, .write = true },
                    .cache = .uncached,
                },
            );
            errdefer innigkeit.mem.heap.deallocateSpecial(register_range);

            const device = try UartT.create(
                register_range.address.toPtr([*]volatile u8),
                baud,
            );

            return switch (uart_type) {
                .@"16450" => .{ .memory_16450 = device },
                .@"16550" => .{ .memory_16550 = device },
            };
        },
        .io_port => {
            const UartT = switch (uart_type) {
                .@"16450" => IoPort16450,
                .@"16550" => IoPort16550,
            };

            const device = try UartT.create(
                @intCast(base_address),
                baud,
            );

            return switch (uart_type) {
                .@"16450" => .{ .io_port_16450 = device },
                .@"16550" => .{ .io_port_16550 = device },
            };
        },
    }
}

pub fn tryGetSerialOutputPL011(
    base_address: u64,
    baud_rate: ?Baud.BaudRate,
    memory_system_available: bool,
) !Uart {
    if (!memory_system_available) return error.RequiresMemorySystem; // TODO: early mmio pages

    const baud: ?Baud = if (baud_rate) |br| .{
        .clock_frequency = .@"24 MHz", // TODO: we assume the clock frequency is 24 MHz
        .baud_rate = br,
    } else null;

    const register_range = try innigkeit.mem.heap.allocateSpecial(
        .{
            .physical_range = .from(
                .from(base_address),
                PL011.register_region_size,
            ),
            .protection = .{ .read = true, .write = true },
            .cache = .uncached,
        },
    );
    errdefer innigkeit.mem.heap.deallocateSpecial(register_range);

    const device = try PL011.create(
        register_range.address.toPtr([*]volatile u32),
        baud,
    );

    return .{ .pl011 = device };
}

pub const CreateError = error{
    NotConnected,
    LoopbackTestFailed,
    IdentificationMismatch,
} || Baud.DivisorError;

pub const Mode = enum { memory, io_port };
