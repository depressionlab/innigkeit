const LineEditor = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");

const write = @import("main.zig").write;
const writePrompt = @import("main.zig").writePrompt;
const scancode = @import("scancode.zig");
const completions = @import("completions.zig");

pub const MAX = 255;

buf: [MAX]u8 = undefined,
len: usize = 0,
cursor: usize = 0,
hist_pos: usize = 0,
saved: [MAX]u8 = undefined,
saved_len: usize = 0,
/// Set when Tab was the last key: tracks the word prefix used so a second
/// Tab with no edit shows the full match list again rather than completing.
last_was_tab: bool = false,

pub fn reset(self: *LineEditor) void {
    self.len = 0;
    self.cursor = 0;
    self.hist_pos = 0;
    self.last_was_tab = false;
}

pub fn redraw(self: *const LineEditor) void {
    write("\r");
    writePrompt();

    var suggestion_len: usize = 0;
    if (self.len > 0) {
        // Find end of verb (first word).
        var verb_end: usize = 0;
        while (verb_end < self.len and
            self.buf[verb_end] != ' ' and self.buf[verb_end] != '\t') : (verb_end += 1)
        {}

        // Color the verb: green if known, red if not.
        if (verb_end > 0) {
            var known = false;
            for (completions.ALL_COMPLETIONS) |name| {
                if (std.mem.eql(u8, name, self.buf[0..verb_end])) {
                    known = true;
                    break;
                }
            }
            write(if (known) "\x1b[32m" else "\x1b[31m");
            innigkeit.io.stdout.print("{s}", .{self.buf[0..verb_end]}) catch {};
            write("\x1b[0m");
        }

        // Rest of the line (after verb).
        if (self.len > verb_end)
            innigkeit.io.stdout.print("{s}", .{self.buf[verb_end..self.len]}) catch {};
    }

    // Erase old content, then draw the autosuggestion suffix in dim gray.
    write("\x1b[K");
    if (completions.suggest(self.buf[0..self.len])) |full| {
        write("\x1b[2;37m");
        innigkeit.io.stdout.print("{s}", .{full[self.len..]}) catch {};
        write("\x1b[0m");
        suggestion_len = full.len - self.len;
    }

    // Reposition cursor.
    const back = (self.len - self.cursor) + suggestion_len;
    if (back > 0)
        innigkeit.io.stdout.print("\x1b[{d}D", .{back}) catch {};
}

pub fn insert(self: *LineEditor, ch: u8) void {
    if (self.len >= MAX) return;
    var i = self.len;
    while (i > self.cursor) : (i -= 1) self.buf[i] = self.buf[i - 1];
    self.buf[self.cursor] = ch;
    self.len += 1;
    self.cursor += 1;
}

pub fn deleteBack(self: *LineEditor) void {
    if (self.cursor == 0) return;
    var i = self.cursor - 1;
    while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
    self.len -= 1;
    self.cursor -= 1;
}

pub fn deleteFwd(self: *LineEditor) void {
    if (self.cursor >= self.len) return;
    var i = self.cursor;
    while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
    self.len -= 1;
}

pub fn killToEnd(self: *LineEditor) void {
    self.len = self.cursor;
}

pub fn killToStart(self: *LineEditor) void {
    const remaining = self.len - self.cursor;
    if (self.cursor > 0) {
        std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.cursor..self.len]);
    }
    self.len = remaining;
    self.cursor = 0;
}

pub fn histUp(self: *LineEditor) void {
    if (self.hist_pos == 0) {
        @memcpy(self.saved[0..self.len], self.buf[0..self.len]);
        self.saved_len = self.len;
    }
    const next = self.hist_pos + 1;
    if (completions.get(next)) |entry| {
        self.hist_pos = next;
        @memcpy(self.buf[0..entry.len], entry);
        self.len = entry.len;
        self.cursor = self.len;
    }
}

pub fn histDown(self: *LineEditor) void {
    if (self.hist_pos == 0) return;
    self.hist_pos -= 1;
    if (self.hist_pos == 0) {
        @memcpy(self.buf[0..self.saved_len], self.saved[0..self.saved_len]);
        self.len = self.saved_len;
    } else if (completions.get(self.hist_pos)) |entry| {
        @memcpy(self.buf[0..entry.len], entry);
        self.len = entry.len;
    }
    self.cursor = self.len;
}

pub fn line(self: *const LineEditor) []const u8 {
    return self.buf[0..self.len];
}

/// Read a line with full editing support. Returns null on Ctrl+D with empty line.
/// `ed` must be owned by the caller so the returned slice stays valid after return.
pub fn readline(self: *LineEditor) ?[]const u8 {
    self.reset();
    var shift = false;
    var ctrl = false;
    var extended = false;
    var raw_buf: [32]u8 = undefined;

    while (true) {
        const n = innigkeit.display.kbdRead(&raw_buf);
        if (n == 0) {
            innigkeit.sleep(5 * std.time.ns_per_ms);
            continue;
        }

        for (raw_buf[0..n]) |sc| {
            if (sc == 0xE0) {
                extended = true;
                continue;
            }
            if (sc & 0x80 != 0) {
                const base = sc & 0x7F;
                if (base == 0x2A or base == 0x36) shift = false;
                if (base == 0x1D) ctrl = false;
                extended = false;
                continue;
            }

            if (extended) {
                extended = false;
                self.last_was_tab = false;
                switch (sc) {
                    0x48 => {
                        self.histUp();
                        self.redraw();
                    },
                    0x50 => {
                        self.histDown();
                        self.redraw();
                    },
                    0x4B => {
                        if (self.cursor > 0) {
                            self.cursor -= 1;
                            self.redraw();
                        }
                    },
                    0x4D => { // Right arrow: move or accept autosuggestion
                        if (self.cursor < self.len) {
                            self.cursor += 1;
                            self.redraw();
                        } else if (completions.suggest(self.buf[0..self.len])) |full| {
                            const copy_len = @min(full.len, LineEditor.MAX);
                            @memcpy(self.buf[0..copy_len], full[0..copy_len]);
                            self.len = copy_len;
                            self.cursor = self.len;
                            self.redraw();
                        }
                    },
                    0x47 => {
                        self.cursor = 0;
                        self.redraw();
                    },
                    0x4F => {
                        self.cursor = self.len;
                        self.redraw();
                    },
                    0x53 => {
                        self.deleteFwd();
                        self.redraw();
                    },
                    else => {},
                }
                continue;
            }

            if (sc == 0x2A or sc == 0x36) {
                shift = true;
                continue;
            }
            if (sc == 0x1D) {
                ctrl = true;
                continue;
            }

            if (ctrl) {
                self.last_was_tab = false;
                switch (sc) {
                    0x1E => {
                        self.cursor = 0;
                        self.redraw();
                    }, // Ctrl+A
                    0x12 => {
                        self.cursor = self.len;
                        self.redraw();
                    }, // Ctrl+E
                    0x25 => {
                        self.killToEnd();
                        self.redraw();
                    }, // Ctrl+K
                    0x16 => {
                        self.killToStart();
                        self.redraw();
                    }, // Ctrl+U
                    0x26 => { // Ctrl+L
                        write("\x1b[2J\x1b[H");
                        writePrompt();
                        self.redraw();
                    },
                    0x2E => { // Ctrl+C
                        write("^C\n");
                        writePrompt();
                        self.reset();
                        self.redraw();
                    },
                    0x20 => { // Ctrl+D: EOF only on empty line
                        if (self.len == 0) {
                            write("\n");
                            return null;
                        }
                    },
                    0x13 => { // Ctrl+R: reverse history search
                        completions.search(self);
                        writePrompt();
                        self.redraw();
                    },
                    else => {},
                }
                continue;
            }

            // Escape key (scancode 0x01): clear line
            if (sc == 0x01) {
                self.last_was_tab = false;
                self.reset();
                write("\r\x1b[K");
                writePrompt();
                self.redraw();
                continue;
            }

            const table = scancode.get(shift);
            if (sc >= table.len) continue;
            const ch = table[sc];
            if (ch == 0) continue;

            if (ch == '\n') {
                self.last_was_tab = false;
                write("\n");
                return self.line();
            } else if (ch == '\x08') {
                self.last_was_tab = false;
                self.deleteBack();
                self.redraw();
            } else if (ch == '\t') {
                completions.tabComplete(self);
                self.last_was_tab = true;
                self.redraw();
            } else if (ch >= 0x20 and ch < 0x7F) {
                self.last_was_tab = false;
                self.insert(ch);
                self.redraw();
            }
        }
    }
}
