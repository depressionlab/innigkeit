//! PS/2 aux port (8042) mouse driver.
//!
//! Enables the auxiliary interface on the 8042 controller, configures the
//! PS/2 mouse for standard 3-byte streaming packets, and routes IRQ 12 to a
//! handler that assembles packets and pushes decoded MouseEvents to `raw_mouse`.
const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");

const log = innigkeit.debug.log.scoped(.ps2_mouse);

const PORT_DATA: u16 = 0x60;
const PORT_CMD: u16 = 0x64;
const STATUS_OBF: u8 = 0x01; // Output Buffer Full: data available
const STATUS_IBF: u8 = 0x02; // Input Buffer Full: controller busy
const STATUS_AUX: u8 = 0x20; // Byte in OBF is from aux (mouse) port

const MOUSE_GSI: u32 = 12;

/// Decoded PS/2 mouse event, 4 bytes, ABI-stable.
pub const MouseEvent = extern struct {
    /// Button state: bit 0=left, bit 1=right, bit 2=middle.
    buttons: u8,
    /// Signed X movement (positive = right).
    dx: i8,
    /// Signed Y movement (positive = up in PS/2 coords; screen Y is inverted).
    dy: i8,
    _pad: u8 = 0,
};

/// SPSC ring of decoded mouse events (64 slots). Fed by IRQ, drained by syscall.
pub const RawMouseBuffer = struct {
    buf: [64]MouseEvent = [_]MouseEvent{.{ .buttons = 0, .dx = 0, .dy = 0 }} ** 64,
    read_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    write_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Called from IRQ context (interrupts disabled). Drops on overflow.
    pub fn push(self: *RawMouseBuffer, ev: MouseEvent) void {
        const w = self.write_pos.load(.monotonic);
        const next = (w + 1) % self.buf.len;
        if (next == self.read_pos.load(.monotonic)) return;
        self.buf[w] = ev;
        self.write_pos.store(next, .release);
    }

    /// Called from syscall context. Returns events drained into out[].
    pub fn drain(self: *RawMouseBuffer, out: []MouseEvent) usize {
        var count: usize = 0;
        while (count < out.len) {
            const r = self.read_pos.load(.acquire);
            if (r == self.write_pos.load(.acquire)) break;
            out[count] = self.buf[r];
            self.read_pos.store((r + 1) % self.buf.len, .release);
            count += 1;
        }
        return count;
    }
};

pub var raw_mouse: RawMouseBuffer = .{};

/// 3-byte packet accumulator (interrupt context only: single writer).
var pkt: [3]u8 = .{0} ** 3;
var pkt_idx: u8 = 0;

/// Initialize the PS/2 mouse.
///
/// Enables the 8042 aux interface, sets IRQ12, resets the mouse, applies
/// default settings, and starts streaming. Safe to call once from stage 4.
pub fn init() !void {
    const cmd_port = architecture.io.Port.from(PORT_CMD) catch unreachable;
    const data_port = architecture.io.Port.from(PORT_DATA) catch unreachable;

    // 1. Enable aux interface.
    waitInputReady(cmd_port);
    cmd_port.write(u8, 0xA8);

    // 2. Read and modify controller command byte: enable IRQ12, un-clock-gate aux.
    waitInputReady(cmd_port);
    cmd_port.write(u8, 0x20);
    waitOutputReady(cmd_port);
    var cmd_byte = data_port.read(u8);
    cmd_byte |= 0x02; // enable aux interrupt (IRQ12)
    cmd_byte &= ~@as(u8, 0x20); // clear aux clock disable
    waitInputReady(cmd_port);
    cmd_port.write(u8, 0x60);
    waitInputReady(cmd_port);
    data_port.write(u8, cmd_byte);

    // 3. Reset mouse, drain ACK + BAT result.
    sendToMouse(cmd_port, data_port, 0xFF);
    drainOutput(cmd_port, data_port);

    // 4. Set defaults, drain ACK.
    sendToMouse(cmd_port, data_port, 0xF6);
    drainOutput(cmd_port, data_port);

    // 5. Enable streaming, drain ACK.
    sendToMouse(cmd_port, data_port, 0xF4);
    drainOutput(cmd_port, data_port);

    // 6. Install IRQ12 handler.
    const handler: architecture.interrupts.Interrupt.Handler = .{
        .eoi = .edge,
        .call = .prepare(onInterrupt, .{}),
    };
    const vector = try architecture.interrupts.Interrupt.allocate(handler);
    try vector.route(MOUSE_GSI);

    log.info("PS/2 mouse initialized", .{});
}

fn onInterrupt(
    _: architecture.interrupts.InterruptFrame,
    _: innigkeit.Task.Current.StateBeforeInterrupt,
) void {
    const cmd_port = architecture.io.Port.from(PORT_CMD) catch unreachable;
    const data_port = architecture.io.Port.from(PORT_DATA) catch unreachable;

    const status = cmd_port.read(u8);
    if (status & STATUS_OBF == 0) return;
    // Safety: consume keyboard data that arrived on our interrupt by mistake.
    if (status & STATUS_AUX == 0) {
        _ = data_port.read(u8);
        return;
    }

    const byte = data_port.read(u8);

    // Synchronize on packet start: byte 0 always has bit 3 set.
    if (pkt_idx == 0 and byte & 0x08 == 0) return;

    pkt[pkt_idx] = byte;
    pkt_idx += 1;
    if (pkt_idx < 3) return;
    pkt_idx = 0;

    // Discard overflowed packets.
    if (pkt[0] & 0xC0 != 0) return;

    // 9-bit signed decode: sign bit in status byte, magnitude in data byte.
    const raw_dx: i16 = blk: {
        const mag: i16 = pkt[1];
        break :blk if (pkt[0] & 0x10 != 0) mag - 256 else mag;
    };
    const raw_dy: i16 = blk: {
        const mag: i16 = pkt[2];
        break :blk if (pkt[0] & 0x20 != 0) mag - 256 else mag;
    };

    raw_mouse.push(.{
        .buttons = pkt[0] & 0x07,
        .dx = @intCast(std.math.clamp(raw_dx, -128, 127)),
        .dy = @intCast(std.math.clamp(raw_dy, -128, 127)),
    });
}

fn waitInputReady(cmd_port: architecture.io.Port) void {
    var i: usize = 0;
    while (cmd_port.read(u8) & STATUS_IBF != 0 and i < 10_000) : (i += 1) {
        architecture.spinLoopHint();
    }
}

fn waitOutputReady(cmd_port: architecture.io.Port) void {
    var i: usize = 0;
    while (cmd_port.read(u8) & STATUS_OBF == 0 and i < 10_000) : (i += 1) {
        architecture.spinLoopHint();
    }
}

/// Forward a byte to the mouse through the 8042 mux.
fn sendToMouse(cmd_port: architecture.io.Port, data_port: architecture.io.Port, byte: u8) void {
    waitInputReady(cmd_port);
    cmd_port.write(u8, 0xD4); // next write goes to aux port
    waitInputReady(cmd_port);
    data_port.write(u8, byte);
}

/// Consume any pending output-buffer bytes (ACK / BAT result from mouse).
fn drainOutput(cmd_port: architecture.io.Port, data_port: architecture.io.Port) void {
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        var j: usize = 0;
        while (cmd_port.read(u8) & STATUS_OBF == 0 and j < 1000) : (j += 1) {
            architecture.spinLoopHint();
        }
        if (cmd_port.read(u8) & STATUS_OBF == 0) break;
        _ = data_port.read(u8);
    }
}
