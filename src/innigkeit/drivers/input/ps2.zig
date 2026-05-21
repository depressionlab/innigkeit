//! PS/2 I8042 keyboard driver.
//!
//! Allocates a dynamic IOAPIC interrupt vector for IRQ 1, routes it, and
//! translates scan-code set 1 make codes to ASCII bytes pushed to
//! `keyboard_buffer`. The BIOS has already reset and enabled the keyboard,
//! so init only flushes stale bytes and installs the IRQ handler.
const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");

const log = innigkeit.debug.log.scoped(.ps2);

const PORT_DATA: u16 = 0x60;
const PORT_STATUS: u16 = 0x64;
const STATUS_OUTPUT_FULL: u8 = 0x01;

/// PS/2 keyboard IOAPIC GSI.
const KEYBOARD_GSI: u32 = 1;

/// The keyboard input buffer, fed by the IRQ handler and consumed by read().
pub var keyboard_buffer: innigkeit.init.KeyboardInputBuffer = .{};

/// Modifier state tracked across interrupts.
var shift_held: bool = false;
var ctrl_held: bool = false;
/// Set when a 0xE0 extended-code prefix was received.
var extended: bool = false;

/// Initialize the PS/2 keyboard driver.
///
/// Flushes the I8042 output buffer, then allocates and routes an interrupt
/// vector for IRQ 1. Safe to call once during kernel init (stage 4).
pub fn init() !void {
    flushOutputBuffer();

    const handler: architecture.interrupts.Interrupt.Handler = .{
        .eoi = .edge,
        .call = .prepare(onInterrupt, .{}),
    };
    const kbd_vector = try architecture.interrupts.Interrupt.allocate(handler);
    try kbd_vector.route(KEYBOARD_GSI);

    log.info("PS/2 keyboard initialized", .{});
}

fn flushOutputBuffer() void {
    const data_port = architecture.io.Port.from(PORT_DATA) catch unreachable;
    const status_port = architecture.io.Port.from(PORT_STATUS) catch unreachable;
    var i: usize = 0;
    while (status_port.read(u8) & STATUS_OUTPUT_FULL != 0 and i < 16) : (i += 1) {
        _ = data_port.read(u8);
    }
}

fn onInterrupt(
    _: architecture.interrupts.InterruptFrame,
    _: innigkeit.Task.Current.StateBeforeInterrupt,
) void {
    const data_port = architecture.io.Port.from(PORT_DATA) catch unreachable;
    const status_port = architecture.io.Port.from(PORT_STATUS) catch unreachable;

    if (status_port.read(u8) & STATUS_OUTPUT_FULL == 0) return;
    const scancode = data_port.read(u8);

    // Extended-key prefix: set flag and wait for the real scan code.
    if (scancode == 0xE0) {
        extended = true;
        return;
    }

    const is_break = (scancode & 0x80) != 0;
    const make: u8 = scancode & 0x7F;

    if (extended) {
        extended = false;
        return; // arrows/ins/del/home/end/pgup/pgdn, ignored for now
    }

    // Track modifier keys.
    switch (make) {
        0x2A, 0x36 => {
            shift_held = !is_break;
            return;
        }, // L/R shift
        0x1D => {
            ctrl_held = !is_break;
            return;
        }, // L ctrl
        else => {},
    }

    if (is_break) return;

    // Ctrl+C → push ASCII ETX.
    if (ctrl_held and make == 0x2E) {
        keyboard_buffer.push('\x03');
        return;
    }

    const ascii = if (shift_held) sc_shifted[make] else sc_normal[make];
    if (ascii != 0) keyboard_buffer.push(ascii);
}

// ---------------------------------------------------------------------------
// Scan-code set 1 → ASCII translation tables (make codes 0x00–0x7F).
// A zero entry means "no character" (modifier, function key, etc.).
// ---------------------------------------------------------------------------

const sc_normal: [128]u8 = buildNormal();
const sc_shifted: [128]u8 = buildShifted();

fn buildNormal() [128]u8 {
    var t = [_]u8{0} ** 128;
    t[0x02] = '1';
    t[0x03] = '2';
    t[0x04] = '3';
    t[0x05] = '4';
    t[0x06] = '5';
    t[0x07] = '6';
    t[0x08] = '7';
    t[0x09] = '8';
    t[0x0A] = '9';
    t[0x0B] = '0';
    t[0x0C] = '-';
    t[0x0D] = '=';
    t[0x0E] = '\x08'; // backspace
    t[0x0F] = '\t'; // tab
    t[0x10] = 'q';
    t[0x11] = 'w';
    t[0x12] = 'e';
    t[0x13] = 'r';
    t[0x14] = 't';
    t[0x15] = 'y';
    t[0x16] = 'u';
    t[0x17] = 'i';
    t[0x18] = 'o';
    t[0x19] = 'p';
    t[0x1A] = '[';
    t[0x1B] = ']';
    t[0x1C] = '\n'; // enter
    t[0x1E] = 'a';
    t[0x1F] = 's';
    t[0x20] = 'd';
    t[0x21] = 'f';
    t[0x22] = 'g';
    t[0x23] = 'h';
    t[0x24] = 'j';
    t[0x25] = 'k';
    t[0x26] = 'l';
    t[0x27] = ';';
    t[0x28] = '\'';
    t[0x29] = '`';
    t[0x2B] = '\\';
    t[0x2C] = 'z';
    t[0x2D] = 'x';
    t[0x2E] = 'c';
    t[0x2F] = 'v';
    t[0x30] = 'b';
    t[0x31] = 'n';
    t[0x32] = 'm';
    t[0x33] = ',';
    t[0x34] = '.';
    t[0x35] = '/';
    t[0x37] = '*';
    t[0x39] = ' ';
    return t;
}

fn buildShifted() [128]u8 {
    var t = [_]u8{0} ** 128;
    t[0x02] = '!';
    t[0x03] = '@';
    t[0x04] = '#';
    t[0x05] = '$';
    t[0x06] = '%';
    t[0x07] = '^';
    t[0x08] = '&';
    t[0x09] = '*';
    t[0x0A] = '(';
    t[0x0B] = ')';
    t[0x0C] = '_';
    t[0x0D] = '+';
    t[0x0E] = '\x08';
    t[0x0F] = '\t';
    t[0x10] = 'Q';
    t[0x11] = 'W';
    t[0x12] = 'E';
    t[0x13] = 'R';
    t[0x14] = 'T';
    t[0x15] = 'Y';
    t[0x16] = 'U';
    t[0x17] = 'I';
    t[0x18] = 'O';
    t[0x19] = 'P';
    t[0x1A] = '{';
    t[0x1B] = '}';
    t[0x1C] = '\n';
    t[0x1E] = 'A';
    t[0x1F] = 'S';
    t[0x20] = 'D';
    t[0x21] = 'F';
    t[0x22] = 'G';
    t[0x23] = 'H';
    t[0x24] = 'J';
    t[0x25] = 'K';
    t[0x26] = 'L';
    t[0x27] = ':';
    t[0x28] = '"';
    t[0x29] = '~';
    t[0x2B] = '|';
    t[0x2C] = 'Z';
    t[0x2D] = 'X';
    t[0x2E] = 'C';
    t[0x2F] = 'V';
    t[0x30] = 'B';
    t[0x31] = 'N';
    t[0x32] = 'M';
    t[0x33] = '<';
    t[0x34] = '>';
    t[0x35] = '?';
    t[0x37] = '*';
    t[0x39] = ' ';
    return t;
}
