//! A simple UART input handler and ring buffer.
const SerialInputBuffer = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

buffer: [256]u8 = undefined,
read_position: usize = 0,
write_position: usize = 0,
lock: innigkeit.sync.SingleSpinLock = .{},

pub fn push(self: *SerialInputBuffer, byte: u8) void {
    self.lock.lock();
    defer self.lock.unlock();

    const next_write = (self.write_position + 1) % self.buffer.len;
    if (next_write != self.read_position) {
        self.buffer[self.write_position] = byte;
        self.write_position = next_write;
    }
}

pub fn pop(self: *SerialInputBuffer) ?u8 {
    self.lock.lock();
    defer self.lock.unlock();

    if (self.read_position == self.write_position) return null;

    const byte = self.buffer[self.read_position];
    self.read_position = @mod((self.read_position + 1), self.buffer.len);
    return byte;
}

pub fn readUntilNewline(self: *SerialInputBuffer, output_buffer: []u8) usize {
    var pos: usize = 0;

    while (pos < output_buffer.len) {
        if (self.pop()) |byte| {
            output_buffer[pos] = byte;
            pos += 1;

            if (byte == '\n') {
                return pos;
            }
        } else {
            // No more data available
            if (pos > 0) return pos;
            // Busy wait for input (not ideal but simple)
            architecture.spinLoopHint();
        }
    }

    return pos;
}
