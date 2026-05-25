//! Interrupt-driven keyboard input with POSIX canonical line discipline.
//!
//! `push()` is called from the PS/2 keyboard IRQ handler with interrupts
//! already disabled. `readLine()` is called from the `read()` syscall and
//! blocks the calling task until a newline-terminated line is available.
//!
//! Safety: `TicketSpinLock.lock()` disables interrupts, so the IRQ handler
//! can never interrupt a `readLine()` critical section, no deadlock is
//! possible between the producer and consumer paths.
const KeyboardInputBuffer = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");

/// Characters being assembled for the current line (not yet submitted).
line: [256]u8 = undefined,
line_len: usize = 0,

/// Ring buffer of bytes ready to be consumed by `readLine()`.
completed: [1024]u8 = undefined,
completed_read: usize = 0,
completed_write: usize = 0,

/// Protects all fields above; also used as the wait-queue's associated lock.
lock: innigkeit.sync.TicketSpinLock = .{},
wait_queue: innigkeit.sync.WaitQueue = .{},

/// Called from the PS/2 IRQ handler (interrupts already disabled on entry).
///
/// Line discipline:
///   printable byte  -> append to in-progress line; echo the character.
///   backspace/DEL   -> remove last character; echo visual erase.
///   CR or LF        -> submit line to the completed ring; wake any reader.
///   Ctrl-C (0x03)   -> discard in-progress line; echo "^C".
pub fn push(self: *KeyboardInputBuffer, byte: u8) void {
    self.lock.lock();
    defer self.lock.unlock();

    switch (byte) {
        '\r', '\n' => {
            self.submitLine();
            innigkeit.init.Output.writeRawImmediate("\r\n");
        },
        '\x08', '\x7f' => {
            if (self.line_len > 0) {
                self.line_len -= 1;
                innigkeit.init.Output.writeRawImmediate("\x08 \x08");
            }
        },
        '\x03' => {
            self.line_len = 0;
            innigkeit.init.Output.writeRawImmediate("^C\r\n");
        },
        else => {
            if (std.ascii.isPrint(byte) and self.line_len < self.line.len - 1) {
                self.line[self.line_len] = byte;
                self.line_len += 1;
                innigkeit.init.Output.writeRawImmediate(self.line[self.line_len - 1 .. self.line_len]);
            }
        },
    }
}

/// Block until a newline-terminated line is ready, then copy it into `buf`.
///
/// Returns the number of bytes written (including the trailing `\n`).
pub fn readLine(self: *KeyboardInputBuffer, buf: []u8) usize {
    self.lock.lock();

    while (!self.hasCompletedLine()) {
        self.wait_queue.wait(&self.lock);
        self.lock.lock();
    }

    var pos: usize = 0;
    while (pos < buf.len) {
        const byte = self.completedPop() orelse break;
        buf[pos] = byte;
        pos += 1;
        if (byte == '\n') break;
    }

    self.lock.unlock();
    return pos;
}

fn submitLine(self: *KeyboardInputBuffer) void {
    var i: usize = 0;
    while (i < self.line_len) : (i += 1) {
        self.completedAppend(self.line[i]);
    }
    self.completedAppend('\n');
    self.line_len = 0;
    self.wait_queue.wakeOne(&self.lock);
}

fn completedAppend(self: *KeyboardInputBuffer, byte: u8) void {
    const next = (self.completed_write + 1) % self.completed.len;
    if (next != self.completed_read) {
        self.completed[self.completed_write] = byte;
        self.completed_write = next;
    }
}

fn completedPop(self: *KeyboardInputBuffer) ?u8 {
    if (self.completed_read == self.completed_write) return null;
    const byte = self.completed[self.completed_read];
    self.completed_read = (self.completed_read + 1) % self.completed.len;
    return byte;
}

fn hasCompletedLine(self: *const KeyboardInputBuffer) bool {
    var i = self.completed_read;
    while (i != self.completed_write) : (i = (i + 1) % self.completed.len) {
        if (self.completed[i] == '\n') return true;
    }
    return false;
}
