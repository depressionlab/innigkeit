const root = @import("root.zig");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

/// A basic write only 16550/16450 UART.
///
/// Assumes the UART clock is 115200 Hz matching the PC serial port clock.
///
/// Always sets 8 bits, no parity, one stop bit and disables interrupts.
///
/// [UART 16550](https://caro.su/msx/ocm_de1/16550.pdf)
/// [PC16550D Universal Asynchronous Receiver/Transmitter with FIFOs](https://media.digikey.com/pdf/Data%20Sheets/Texas%20Instruments%20PDFs/PC16550D.pdf)
pub fn Uart16X50(comptime mode: root.Mode, comptime fifo_mode: enum { disabled, enabled }) type {
    return struct {
        write_register: AddressT,
        line_status_register: AddressT,

        const UartT = @This();

        pub const AddressT = switch (mode) {
            .memory => [*]volatile u8,
            .io_port => u16,
        };

        pub fn create(base: AddressT, baud: ?root.Baud) root.CreateError!UartT {
            // write to scratch register to check if the UART is connected
            writeRegister(base + @intFromEnum(RegisterOffset.scratch), 0xBA);

            // if the scratch register is not `0xBA` then the UART is not connected
            if (readRegister(base + @intFromEnum(RegisterOffset.scratch)) != 0xBA) return error.NotConnected;

            // disable UART
            {
                var modem_control: ModemControlRegister = @bitCast(readRegister(
                    base + @intFromEnum(RegisterOffset.modem_control),
                ));

                modem_control.dtr = false;
                modem_control.rts = false;
                modem_control.out1 = false;
                modem_control.out2 = false;
                modem_control.loopback = false;

                writeRegister(base + @intFromEnum(RegisterOffset.modem_control), @bitCast(modem_control));
            }

            // disable interrupts
            {
                var interrupt_enable: InterruptEnableRegister = @bitCast(readRegister(
                    base + @intFromEnum(RegisterOffset.interrupt_enable),
                ));

                interrupt_enable.received_data_available = false;
                interrupt_enable.transmit_holding_register_empty = false;
                interrupt_enable.receive_line_status = false;
                interrupt_enable.modem_status = false;

                writeRegister(base + @intFromEnum(RegisterOffset.interrupt_enable), @bitCast(interrupt_enable));
            }

            // set baudrate
            if (baud) |b| {
                writeRegister(
                    base + @intFromEnum(RegisterOffset.line_control),
                    @bitCast(LineControlRegister{
                        .word_length = .@"8",
                        .stop_bits = .@"1",
                        .parity = false,
                        .even_parity = false,
                        .stick_parity = false,
                        .set_break = false,
                        .divisor_latch_access = true,
                    }),
                );

                const divisor = try b.integerDivisor();

                writeRegister(
                    base + @intFromEnum(RegisterOffset.divisor_latch_lsb),
                    @truncate(divisor),
                );
                writeRegister(
                    base + @intFromEnum(RegisterOffset.divisor_latch_msb),
                    @truncate(divisor >> 8),
                );
            }

            // 8 bits, no parity, one stop bit
            writeRegister(
                base + @intFromEnum(RegisterOffset.line_control),
                @bitCast(LineControlRegister{
                    .word_length = .@"8",
                    .stop_bits = .@"1",
                    .parity = false,
                    .even_parity = false,
                    .stick_parity = false,
                    .set_break = false,
                    .divisor_latch_access = false,
                }),
            );

            if (fifo_mode == .enabled) {
                // enable FIFO
                {
                    var fifo_control: FIFOControlRegister = @bitCast(readRegister(
                        base + @intFromEnum(RegisterOffset.fifo_control),
                    ));

                    fifo_control.enable_fifo = true;
                    fifo_control.clear_receive_fifo = true;
                    fifo_control.clear_transmit_fifo = true;
                    fifo_control.rxrdy_txrdy = false;
                    fifo_control.trigger_level = .@"1";

                    writeRegister(base + @intFromEnum(RegisterOffset.fifo_control), @bitCast(fifo_control));
                }
            }

            // enable UART with loopback
            {
                var modem_control: ModemControlRegister = @bitCast(readRegister(
                    base + @intFromEnum(RegisterOffset.modem_control),
                ));

                modem_control.dtr = true;
                modem_control.rts = true;
                modem_control.out1 = true;
                modem_control.out2 = true;
                modem_control.loopback = true;

                writeRegister(base + @intFromEnum(RegisterOffset.modem_control), @bitCast(modem_control));
            }

            // send `0xAE` to the UART
            writeRegister(base, 0xAE);

            // check that the `0xAE` was received due to loopback
            if (readRegister(base) != 0xAE) return error.LoopbackTestFailed;

            // disable loopback
            {
                var modem_control: ModemControlRegister = @bitCast(readRegister(
                    base + @intFromEnum(RegisterOffset.modem_control),
                ));

                modem_control.loopback = false;

                writeRegister(base + @intFromEnum(RegisterOffset.modem_control), @bitCast(modem_control));
            }

            return .{
                .write_register = base + @intFromEnum(RegisterOffset.write),
                .line_status_register = base + @intFromEnum(RegisterOffset.line_status),
            };
        }

        fn writeStr(uart: UartT, str: []const u8) void {
            switch (fifo_mode) {
                .enabled => {
                    var i: usize = 0;

                    while (i < str.len) {
                        uart.waitForOutputReady();

                        // FIFO is empty meaning we can write 16 bytes
                        var bytes_to_write = @min(str.len - i, 16);

                        while (bytes_to_write > 0) {
                            writeRegister(uart.write_register, str[i]);
                            bytes_to_write -= 1;
                            i += 1;
                        }
                    }
                },
                .disabled => {
                    for (str) |byte| {
                        uart.waitForOutputReady();
                        writeRegister(uart.write_register, byte);
                    }
                },
            }
        }

        pub fn output(uart: *UartT) innigkeit.init.Output {
            return .{
                .name = innigkeit.init.Output.Name.fromSlice("uart16X50") catch unreachable,
                .writeFn = struct {
                    fn writeFn(state: *anyopaque, str: []const u8) void {
                        const inner_uart: *UartT = @ptrCast(@alignCast(state));
                        innigkeit.init.Output.writeWithCarridgeReturns(inner_uart.*, writeStr, str);
                    }
                }.writeFn,
                .splatFn = struct {
                    fn splatFn(state: *anyopaque, str: []const u8, splat: usize) void {
                        const inner_uart_ptr: *UartT = @ptrCast(@alignCast(state));
                        const inner_uart: UartT = inner_uart_ptr.*;
                        for (0..splat) |_| innigkeit.init.Output.writeWithCarridgeReturns(inner_uart, writeStr, str);
                    }
                }.splatFn,
                .state = uart,
            };
        }

        inline fn waitForOutputReady(uart: UartT) void {
            while (true) {
                const line_status: LineStatusRegister = @bitCast(readRegister(uart.line_status_register));
                if (line_status.transmitter_holding_register_empty) return;
                architecture.spinLoopHint();
            }
        }

        inline fn writeRegister(target: AddressT, byte: u8) void {
            switch (mode) {
                .io_port => {
                    const port = architecture.io.Port.from(target) catch unreachable;
                    port.write(u8, byte);
                },
                .memory => target[0] = byte,
            }
        }

        inline fn readRegister(target: AddressT) u8 {
            switch (mode) {
                .io_port => {
                    const port = architecture.io.Port.from(target) catch unreachable;
                    return port.read(u8);
                },
                .memory => return target[0],
            }
        }

        pub const register_region_size: core.Size = .from(@as(usize, @intFromEnum(RegisterOffset.scratch)) + 1, .byte);

        const RegisterOffset = enum(u3) {
            read_write_divisor_latch_lsb = 0,
            interrupt_enable_divisor_latch_msb = 1,
            interrupt_identification_fifo_control = 2,
            line_control = 3,
            modem_control = 4,
            line_status = 5,
            modem_status = 6,
            scratch = 7,

            pub const read: RegisterOffset = .read_write_divisor_latch_lsb;
            pub const write: RegisterOffset = .read_write_divisor_latch_lsb;
            pub const divisor_latch_lsb: RegisterOffset = .read_write_divisor_latch_lsb;
            pub const interrupt_enable: RegisterOffset = .interrupt_enable_divisor_latch_msb;
            pub const divisor_latch_msb: RegisterOffset = .interrupt_enable_divisor_latch_msb;
            pub const interrupt_identification: RegisterOffset = .interrupt_identification_fifo_control;
            pub const fifo_control: RegisterOffset = .interrupt_identification_fifo_control;
        };

        const InterruptEnableRegister = packed struct(u8) {
            received_data_available: bool,
            transmit_holding_register_empty: bool,
            receive_line_status: bool,
            modem_status: bool,

            _reserved: u4,
        };

        const LineControlRegister = packed struct(u8) {
            word_length: WordLength,
            stop_bits: StopBits,
            parity: bool,
            even_parity: bool,
            stick_parity: bool,
            set_break: bool,
            divisor_latch_access: bool,

            pub const WordLength = enum(u2) {
                @"5" = 0b00,
                @"6" = 0b01,
                @"7" = 0b10,
                @"8" = 0b11,
            };

            pub const StopBits = enum(u1) {
                /// One stop bit is generated in the transmitted data.
                @"1" = 0,

                /// When 5-bit word length is selected one and a half stop bits are generated.
                ///
                /// When either a 6-, 7-, or 8-bit word length is selected, two stop bits are generated.
                @"1.5 / 2" = 1,
            };
        };

        const FIFOControlRegister = packed struct(u8) {
            enable_fifo: bool,
            clear_receive_fifo: bool,
            clear_transmit_fifo: bool,
            rxrdy_txrdy: bool,
            _reserved: u2,
            trigger_level: TriggerLevel,

            pub const TriggerLevel = enum(u2) {
                @"1" = 0b00,
                @"4" = 0b01,
                @"8" = 0b10,
                @"14" = 0b11,
            };
        };

        const ModemControlRegister = packed struct(u8) {
            dtr: bool,
            rts: bool,
            out1: bool,
            out2: bool,
            loopback: bool,
            _reserved: u3,
        };

        const LineStatusRegister = packed struct(u8) {
            data_ready: bool,
            overrun_error: bool,
            parity_error: bool,
            framing_error: bool,
            break_interrupt: bool,
            transmitter_holding_register_empty: bool,
            transmitter_empty: bool,
            _: u1,
        };
    };
}
