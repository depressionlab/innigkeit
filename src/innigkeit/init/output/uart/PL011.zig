//! A basic write only PrimeCell PL011 UART.
//!
//! 24 Mhz?
//!
//! [Technical Reference Manual](https://developer.arm.com/documentation/ddi0183/latest/)
const PL011 = @This();

const root = @import("root.zig");
const core = @import("core");
const innigkeit = @import("innigkeit");

write_register: [*]volatile u32,
flag_register: [*]volatile u32,

pub fn create(base: [*]volatile u32, baud: ?root.Baud) root.CreateError!PL011 {
    const identification =
        readRegister(base + @intFromEnum(RegisterOffset.PrimeCellIdentification3)) << 24 |
        readRegister(base + @intFromEnum(RegisterOffset.PrimeCellIdentification2)) << 16 |
        readRegister(base + @intFromEnum(RegisterOffset.PrimeCellIdentification1)) << 8 |
        readRegister(base + @intFromEnum(RegisterOffset.PrimeCellIdentification0));

    if (identification != 0xB105F00D) return error.IdentificationMismatch;

    // disable UART
    {
        var control: ControlRegister = @bitCast(readRegister(base + @intFromEnum(RegisterOffset.Control)));
        control.enable = false;
        control.transmit_enable = false;
        control.receive_enable = false;
        writeRegister(base + @intFromEnum(RegisterOffset.Control), @bitCast(control));
    }

    // disable interrupts
    {
        var interrupt_mask: InterruptMaskRegister = @bitCast(readRegister(base + @intFromEnum(RegisterOffset.InterruptMask)));
        interrupt_mask.masks = 0;
        writeRegister(base + @intFromEnum(RegisterOffset.InterruptMask), @bitCast(interrupt_mask));
    }

    // set baudrate
    if (baud) |b| {
        const divisor = try b.fractionalDivisor();

        writeRegister(
            base + @intFromEnum(RegisterOffset.IntegerBaudRate),
            @bitCast(IntegerBaudRateRegister{
                .integer = divisor.integer,
            }),
        );
        writeRegister(
            base + @intFromEnum(RegisterOffset.FractionalBaudRate),
            @bitCast(FractionalBaudRateRegister{
                .fractional = divisor.fractional,
            }),
        );
    }

    // 8 bits, no parity, one stop bit
    {
        var line_control: LineControlRegister = @bitCast(readRegister(base + @intFromEnum(RegisterOffset.LineControl)));
        line_control.word_length = .@"8";
        line_control.two_stop_bits = false;
        line_control.parity = false;
        line_control.enable_fifo = false; // clear fifo
        writeRegister(base + @intFromEnum(RegisterOffset.LineControl), @bitCast(line_control));

        line_control.enable_fifo = true; // enable fifo
        writeRegister(base + @intFromEnum(RegisterOffset.LineControl), @bitCast(line_control));
    }

    // enable UART with loopback
    {
        var control: ControlRegister = @bitCast(readRegister(base + @intFromEnum(RegisterOffset.Control)));
        control.enable = true;
        control.loopback = true;
        control.transmit_enable = true;
        writeRegister(base + @intFromEnum(RegisterOffset.Control), @bitCast(control));
    }

    // send `\r` to the UART
    writeRegister(base + @intFromEnum(RegisterOffset.Write), '\r');

    // check that the `\r` was received due to loopback
    if (readRegister(base + @intFromEnum(RegisterOffset.Read)) != '\r') return error.LoopbackTestFailed;

    // disable loopback
    {
        var control: ControlRegister = @bitCast(readRegister(base + @intFromEnum(RegisterOffset.Control)));
        control.loopback = false;
        writeRegister(base + @intFromEnum(RegisterOffset.Control), @bitCast(control));
    }

    return .{
        .write_register = base + @intFromEnum(RegisterOffset.Write),
        .flag_register = base + @intFromEnum(RegisterOffset.Flag),
    };
}

fn writeStr(pl011: PL011, str: []const u8) void {
    var i: usize = 0;

    while (i < str.len) {
        pl011.waitForOutputReady();

        // FIFO is empty meaning we can write 32 bytes
        var bytes_to_write = @min(str.len - i, 32);

        while (bytes_to_write > 0) {
            writeRegister(pl011.write_register, str[i]);
            bytes_to_write -= 1;
            i += 1;
        }
    }
}

pub fn output(pl011: *PL011) innigkeit.init.Output {
    return .{
        .name = innigkeit.init.Output.Name.fromSlice("pl011") catch unreachable,
        .writeFn = struct {
            fn writeFn(state: *anyopaque, str: []const u8) void {
                const uart_ptr: *PL011 = @ptrCast(@alignCast(state));
                innigkeit.init.Output.writeWithCarridgeReturns(uart_ptr.*, writeStr, str);
            }
        }.writeFn,
        .splatFn = struct {
            fn splatFn(state: *anyopaque, str: []const u8, splat: usize) void {
                const uart_ptr: *PL011 = @ptrCast(@alignCast(state));
                const uart = uart_ptr.*;
                for (0..splat) |_| innigkeit.init.Output.writeWithCarridgeReturns(uart, writeStr, str);
            }
        }.splatFn,
        .state = pl011,
    };
}

inline fn waitForOutputReady(pl011: PL011) void {
    while (true) {
        const flags: FlagRegister = @bitCast(readRegister(pl011.flag_register));
        if (flags.transmit_fifo_empty) return;
        // TODO: should there be a spinloop hint here?
    }
}

inline fn writeRegister(target: [*]volatile u32, value: u32) void {
    target[0] = value;
}

inline fn readRegister(target: [*]volatile u32) u32 {
    return target[0];
}

pub const register_region_size: core.Size = .from(@intFromEnum(RegisterOffset.PrimeCellIdentification3) + 1, .byte);

const RegisterOffset = enum(usize) {
    ReadWrite = 0x000 / 4,
    Flag = 0x018 / 4,
    IntegerBaudRate = 0x024 / 4,
    FractionalBaudRate = 0x028 / 4,
    LineControl = 0x02c / 4,
    Control = 0x030 / 4,
    InterruptMask = 0x038 / 4,
    PrimeCellIdentification0 = 0xFF0 / 4,
    PrimeCellIdentification1 = 0xFF4 / 4,
    PrimeCellIdentification2 = 0xFF8 / 4,
    PrimeCellIdentification3 = 0xFFC / 4,

    pub const Read: RegisterOffset = .ReadWrite;
    pub const Write: RegisterOffset = .ReadWrite;
};

const ControlRegister = packed struct(u32) {
    enable: bool,

    _1: u6,

    loopback: bool,

    transmit_enable: bool,
    receive_enable: bool,

    _2: u22,
};

const InterruptMaskRegister = packed struct(u32) {
    masks: u10,
    _: u22,
};

const LineControlRegister = packed struct(u32) {
    _1: u1,
    parity: bool,
    _2: u1,
    two_stop_bits: bool,
    enable_fifo: bool,
    word_length: WordLength,
    _3: u25,

    pub const WordLength = enum(u2) {
        @"5" = 0b00,
        @"6" = 0b01,
        @"7" = 0b10,
        @"8" = 0b11,
    };
};

const IntegerBaudRateRegister = packed struct(u32) {
    integer: u16,
    _: u16 = 0,
};

const FractionalBaudRateRegister = packed struct(u32) {
    fractional: u6,
    _: u26 = 0,
};

const FlagRegister = packed struct(u32) {
    _1: u7,

    transmit_fifo_empty: bool,

    _2: u24,
};
