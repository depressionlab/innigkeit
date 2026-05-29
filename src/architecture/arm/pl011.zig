//! PL011 UART driver for early kernel output.
//!
//! The PL011 UART is the standard serial device on the QEMU virt machine for
//! aarch64. It is located at physical address 0x09000000.

const architecture = @import("architecture");

/// Default PL011 base address on the QEMU `virt` machine.
pub const UART_BASE: u64 = 0x09000000;

// PL011 register offsets from base.
const DR: u64 = 0x000; // Data register
const FR: u64 = 0x018; // Flag register
const IBRD: u64 = 0x024; // Integer baud rate divisor
const FBRD: u64 = 0x028; // Fractional baud rate divisor
const LCR_H: u64 = 0x02C; // Line control
const CR: u64 = 0x030; // Control register
const IMSC: u64 = 0x038; // Interrupt mask set/clear

// Flag register bits.
const FR_TXFF: u32 = 1 << 5; // TX FIFO full
const FR_RXFE: u32 = 1 << 4; // RX FIFO empty

// LCR_H bits: 8-bit data, no parity, 1 stop bit, FIFO enabled.
const LCR_H_WLEN_8: u32 = 0b11 << 5; // 8-bit words
const LCR_H_FEN: u32 = 1 << 4; // FIFO enable

// CR bits.
const CR_UARTEN: u32 = 1 << 0; // UART enable
const CR_TXE: u32 = 1 << 8; // TX enable
const CR_RXE: u32 = 1 << 9; // RX enable

inline fn reg(base: u64, offset: u64) *volatile u32 {
    return @ptrFromInt(base + offset);
}

/// Initialise the PL011 UART at `base`.
///
/// Sets 115200 baud (assuming a 24 MHz UART clock as used by QEMU virt),
/// 8N1, FIFOs enabled.
pub fn init(base: u64) void {
    // Disable the UART while we configure it.
    reg(base, CR).* = 0;

    // Mask all interrupts.
    reg(base, IMSC).* = 0x7FF;

    // Baud rate: 115200 with a 24 MHz UART clock.
    // Divisor = 24_000_000 / (16 * 115200) = 13.020833...
    // IBRD = 13, FBRD = round(0.020833 * 64) = 1
    reg(base, IBRD).* = 13;
    reg(base, FBRD).* = 1;

    // 8N1, FIFOs on.
    reg(base, LCR_H).* = LCR_H_WLEN_8 | LCR_H_FEN;

    // Enable UART, TX, RX.
    reg(base, CR).* = CR_UARTEN | CR_TXE | CR_RXE;
}

/// Write a single byte to the UART, spinning until the TX FIFO has room.
pub fn putChar(base: u64, ch: u8) void {
    while ((reg(base, FR).* & FR_TXFF) != 0) {}
    reg(base, DR).* = ch;
}

/// Read a byte from the UART without blocking.
///
/// Returns `null` if the RX FIFO is empty.
pub fn getChar(base: u64) ?u8 {
    if ((reg(base, FR).* & FR_RXFE) != 0) return null;
    return @truncate(reg(base, DR).*);
}

const static = struct {
    /// Static base address kept so the function pointer can reference it.
    var uart_base: u64 = UART_BASE;
};

fn writeStr(ctx: *anyopaque, str: []const u8) void {
    const base: u64 = @intFromPtr(ctx);
    for (str) |b| putChar(base, b);
}

fn splatStr(ctx: *anyopaque, str: []const u8, splat: usize) void {
    for (0..splat) |_| {
        architecture.init.InitOutput.Output.writeWithCarridgeReturns(
            ctx,
            struct {
                fn w(c: *anyopaque, s: []const u8) void {
                    writeStr(c, s);
                }
            }.w,
            str,
        );
    }
}

/// Returns an `architecture.init.InitOutput` that writes to the PL011 at
/// `base`.
///
/// The returned value borrows `static.uart_base`; it must not outlive that
/// variable (which has static storage duration, so it is fine in practice).
pub fn getInitOutput(base: u64) architecture.init.InitOutput {
    static.uart_base = base;
    return .{
        .output = .{
            .name = architecture.init.InitOutput.Output.Name.fromSlice("pl011") catch unreachable,
            .writeFn = struct {
                fn writeFn(ctx: *anyopaque, str: []const u8) void {
                    architecture.init.InitOutput.Output.writeWithCarridgeReturns(
                        ctx,
                        struct {
                            fn w(c: *anyopaque, s: []const u8) void {
                                writeStr(c, s);
                            }
                        }.w,
                        str,
                    );
                }
            }.writeFn,
            .splatFn = splatStr,
            .state = @ptrFromInt(static.uart_base),
        },
        .preference = .use,
    };
}
