const std = @import("std");
const innigkeit = @import("innigkeit");

const HIST_MAX = 50;
const LINE_MAX = 255;
const ENV_MAX = 32;

const EnvEntry = struct {
    key: [32]u8,
    klen: u8,
    val: [128]u8,
    vlen: u8,
};
var env_table: [ENV_MAX]EnvEntry = undefined;
var env_count: usize = 0;

fn envGet(key: []const u8) ?[]const u8 {
    for (env_table[0..env_count]) |*e| {
        if (std.mem.eql(u8, e.key[0..e.klen], key)) return e.val[0..e.vlen];
    }
    return null;
}

fn envSet(key: []const u8, val: []const u8) void {
    for (env_table[0..env_count]) |*e| {
        if (std.mem.eql(u8, e.key[0..e.klen], key)) {
            const vl = @min(val.len, 127);
            @memcpy(e.val[0..vl], val[0..vl]);
            e.vlen = @intCast(vl);
            return;
        }
    }
    if (env_count >= ENV_MAX) return;
    var e = &env_table[env_count];
    const kl = @min(key.len, 31);
    const vl = @min(val.len, 127);
    @memcpy(e.key[0..kl], key[0..kl]);
    e.klen = @intCast(kl);
    @memcpy(e.val[0..vl], val[0..vl]);
    e.vlen = @intCast(vl);
    env_count += 1;
}

var hist_entries: [HIST_MAX][LINE_MAX + 1]u8 = undefined;
var hist_lens: [HIST_MAX]usize = [_]usize{0} ** HIST_MAX;
var hist_count: usize = 0;
var hist_total: usize = 0;

fn histPush(line: []const u8) void {
    if (line.len == 0) return;
    if (hist_total > 0 and std.mem.eql(u8, line, hist_entries[(hist_count - 1) % HIST_MAX][0..hist_lens[(hist_count - 1) % HIST_MAX]])) return;
    const idx = hist_count % HIST_MAX;
    const l = @min(line.len, LINE_MAX);
    @memcpy(hist_entries[idx][0..l], line[0..l]);
    hist_lens[idx] = l;
    hist_count += 1;
    if (hist_total < HIST_MAX) hist_total += 1;
}

fn histGet(n: usize) ?[]const u8 {
    if (n == 0 or n > hist_total) return null;
    const idx = (hist_count -% n) % HIST_MAX;
    return hist_entries[idx][0..hist_lens[idx]];
}

const SC_NORMAL = buildSCNormal();
const SC_SHIFT = buildSCShift();

fn buildSCNormal() [128]u8 {
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
    t[0x0E] = '\x08';
    t[0x0F] = '\t';
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
    t[0x1C] = '\n';
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

fn buildSCShift() [128]u8 {
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

/// Return the most recent history entry that starts with `current`, or null.
fn getSuggestion(current: []const u8) ?[]const u8 {
    if (current.len == 0) return null;
    var n: usize = 1;
    while (n <= hist_total) : (n += 1) {
        if (histGet(n)) |entry| {
            if (entry.len > current.len and std.mem.startsWith(u8, entry, current))
                return entry;
        }
    }
    return null;
}

const BUILTIN_NAMES = [_][]const u8{
    "cd",     "clear", "cpuinfo", "echo",     "env", "exit",
    "export", "help",  "history", "ifconfig", "ls",  "meminfo",
    "ping",   "pwd",   "time",    "uname",
};

const KNOWN_PROGRAMS = [_][]const u8{
    "calculator",  "doom",   "gfx_demo", "hello_world",
    "installer",   "pixels", "rust_cat", "rust_hello",
    "shader_demo", "shell",  "wm",
};

const ALL_COMPLETIONS = BUILTIN_NAMES ++ KNOWN_PROGRAMS;

const LineEditor = struct {
    buf: [LINE_MAX]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    hist_pos: usize = 0,
    saved: [LINE_MAX]u8 = undefined,
    saved_len: usize = 0,
    /// Set when Tab was the last key: tracks the word prefix used so a second
    /// Tab with no edit shows the full match list again rather than completing.
    last_was_tab: bool = false,

    fn reset(self: *LineEditor) void {
        self.len = 0;
        self.cursor = 0;
        self.hist_pos = 0;
        self.last_was_tab = false;
    }

    fn redraw(self: *const LineEditor) void {
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
                for (ALL_COMPLETIONS) |name| {
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
        if (getSuggestion(self.buf[0..self.len])) |full| {
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

    fn insert(self: *LineEditor, ch: u8) void {
        if (self.len >= LINE_MAX) return;
        var i = self.len;
        while (i > self.cursor) : (i -= 1) self.buf[i] = self.buf[i - 1];
        self.buf[self.cursor] = ch;
        self.len += 1;
        self.cursor += 1;
    }

    fn deleteBack(self: *LineEditor) void {
        if (self.cursor == 0) return;
        var i = self.cursor - 1;
        while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
        self.len -= 1;
        self.cursor -= 1;
    }

    fn deleteFwd(self: *LineEditor) void {
        if (self.cursor >= self.len) return;
        var i = self.cursor;
        while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
        self.len -= 1;
    }

    fn killToEnd(self: *LineEditor) void {
        self.len = self.cursor;
    }

    fn killToStart(self: *LineEditor) void {
        const remaining = self.len - self.cursor;
        if (self.cursor > 0) {
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.cursor..self.len]);
        }
        self.len = remaining;
        self.cursor = 0;
    }

    fn histUp(self: *LineEditor) void {
        if (self.hist_pos == 0) {
            @memcpy(self.saved[0..self.len], self.buf[0..self.len]);
            self.saved_len = self.len;
        }
        const next = self.hist_pos + 1;
        if (histGet(next)) |entry| {
            self.hist_pos = next;
            @memcpy(self.buf[0..entry.len], entry);
            self.len = entry.len;
            self.cursor = self.len;
        }
    }

    fn histDown(self: *LineEditor) void {
        if (self.hist_pos == 0) return;
        self.hist_pos -= 1;
        if (self.hist_pos == 0) {
            @memcpy(self.buf[0..self.saved_len], self.saved[0..self.saved_len]);
            self.len = self.saved_len;
        } else if (histGet(self.hist_pos)) |entry| {
            @memcpy(self.buf[0..entry.len], entry);
            self.len = entry.len;
        }
        self.cursor = self.len;
    }

    fn line(self: *const LineEditor) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Handle Tab key: complete command name prefix or show matches.
fn tabComplete(ed: *LineEditor) void {
    // Find the start of the word immediately before the cursor.
    var word_start: usize = 0;
    var i: usize = 0;
    while (i < ed.cursor) : (i += 1) {
        if (ed.buf[i] == ' ' or ed.buf[i] == '\t') word_start = i + 1;
    }

    // Only complete the first word (command name).
    // If there's already a space before the cursor the word isn't the first token.
    var has_earlier_word = false;
    for (ed.buf[0..word_start]) |c| {
        if (c != ' ' and c != '\t') {
            has_earlier_word = true;
            break;
        }
    }
    if (has_earlier_word) {
        write("\x07"); // bell: no argument completion
        return;
    }

    const prefix = ed.buf[word_start..ed.cursor];

    var matches: [ALL_COMPLETIONS.len][]const u8 = undefined;
    var n_matches: usize = 0;
    for (ALL_COMPLETIONS) |name| {
        if (std.mem.startsWith(u8, name, prefix)) {
            matches[n_matches] = name;
            n_matches += 1;
        }
    }

    if (n_matches == 0) {
        write("\x07");
        return;
    }

    if (n_matches == 1) {
        // Complete to the unique match + trailing space.
        const rest = matches[0][prefix.len..];
        for (rest) |c| ed.insert(c);
        ed.insert(' ');
        return;
    }

    // Multiple matches: complete to longest common prefix.
    const lcp = longestCommonPrefix(matches[0..n_matches]);
    if (lcp.len > prefix.len) {
        // There's more to complete without ambiguity.
        const rest = lcp[prefix.len..];
        for (rest) |c| ed.insert(c);
        return;
    }

    // Ambiguous even at the current cursor: show the list if Tab was not
    // already pressed on this exact input (avoid flooding on every Tab).
    if (!ed.last_was_tab) {
        write("\n");
        for (matches[0..n_matches]) |m| {
            innigkeit.io.stdout.print("  {s}", .{m}) catch {};
        }
        write("\n");
        writePrompt();
    } else {
        write("\x07");
    }
}

fn longestCommonPrefix(names: []const []const u8) []const u8 {
    if (names.len == 0) return "";
    var len = names[0].len;
    for (names[1..]) |name| {
        var j: usize = 0;
        while (j < len and j < name.len and names[0][j] == name[j]) : (j += 1) {}
        len = j;
    }
    return names[0][0..len];
}

fn write(s: []const u8) void {
    innigkeit.io.stdout.print("{s}", .{s}) catch {};
}

fn writeln(s: []const u8) void {
    innigkeit.io.stdout.print("{s}\n", .{s}) catch {};
}

fn writePrompt() void {
    const cwd = envGet("PWD") orelse "/";
    innigkeit.io.stdout.print("{s}$ ", .{cwd}) catch {};
}

/// Ctrl+R incremental reverse history search.
/// Loads the accepted entry into `ed` on Enter; cancels on Escape.
fn searchHistory(ed: *LineEditor) void {
    var query: [LINE_MAX]u8 = undefined;
    var query_len: usize = 0;
    var shift2 = false;
    var ctrl2 = false;
    var raw: [32]u8 = undefined;

    const drawSearch = struct {
        fn draw(q: []const u8) void {
            write("\r\x1b[K(reverse-i-search)'");
            innigkeit.io.stdout.print("{s}", .{q}) catch {};
            write("': ");
            var n: usize = 1;
            while (n <= hist_total) : (n += 1) {
                if (histGet(n)) |entry| {
                    if (std.mem.indexOf(u8, entry, q) != null) {
                        innigkeit.io.stdout.print("{s}", .{entry}) catch {};
                        break;
                    }
                }
            }
            write("\x1b[K");
        }
    }.draw;

    drawSearch(query[0..0]);

    outer: while (true) {
        const n = innigkeit.display.kbdRead(&raw);
        if (n == 0) {
            innigkeit.sleep(5 * std.time.ns_per_ms);
            continue;
        }
        for (raw[0..n]) |sc| {
            if (sc == 0xE0) continue;
            if (sc & 0x80 != 0) {
                const base = sc & 0x7F;
                if (base == 0x2A or base == 0x36) shift2 = false;
                if (base == 0x1D) ctrl2 = false;
                continue;
            }
            if (sc == 0x2A or sc == 0x36) {
                shift2 = true;
                continue;
            }
            if (sc == 0x1D) {
                ctrl2 = true;
                continue;
            }

            // Escape or Ctrl+C: cancel
            if (sc == 0x01 or (ctrl2 and sc == 0x2E)) {
                write("\r\x1b[K");
                break :outer;
            }

            const table = if (shift2) &SC_SHIFT else &SC_NORMAL;
            if (sc >= table.len) continue;
            const ch = table[sc];
            if (ch == 0) continue;

            if (ch == '\n') {
                // Accept: find match and load into editor
                const q = query[0..query_len];
                var i: usize = 1;
                while (i <= hist_total) : (i += 1) {
                    if (histGet(i)) |entry| {
                        if (std.mem.indexOf(u8, entry, q) != null) {
                            const cl = @min(entry.len, LINE_MAX);
                            @memcpy(ed.buf[0..cl], entry[0..cl]);
                            ed.len = cl;
                            ed.cursor = cl;
                            break;
                        }
                    }
                }
                write("\n");
                break :outer;
            }

            if (ch == '\x08') {
                if (query_len > 0) query_len -= 1;
            } else if (ch >= 0x20 and ch < 0x7F) {
                if (query_len < LINE_MAX) {
                    query[query_len] = ch;
                    query_len += 1;
                }
            } else continue;

            drawSearch(query[0..query_len]);
        }
    }
}

/// Read a line with full editing support. Returns null on Ctrl+D with empty line.
/// `ed` must be owned by the caller so the returned slice stays valid after return.
fn readline(ed: *LineEditor) ?[]const u8 {
    ed.reset();
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
                ed.last_was_tab = false;
                switch (sc) {
                    0x48 => {
                        ed.histUp();
                        ed.redraw();
                    },
                    0x50 => {
                        ed.histDown();
                        ed.redraw();
                    },
                    0x4B => {
                        if (ed.cursor > 0) {
                            ed.cursor -= 1;
                            ed.redraw();
                        }
                    },
                    0x4D => { // Right arrow: move or accept autosuggestion
                        if (ed.cursor < ed.len) {
                            ed.cursor += 1;
                            ed.redraw();
                        } else if (getSuggestion(ed.buf[0..ed.len])) |full| {
                            const copy_len = @min(full.len, LINE_MAX);
                            @memcpy(ed.buf[0..copy_len], full[0..copy_len]);
                            ed.len = copy_len;
                            ed.cursor = ed.len;
                            ed.redraw();
                        }
                    },
                    0x47 => {
                        ed.cursor = 0;
                        ed.redraw();
                    },
                    0x4F => {
                        ed.cursor = ed.len;
                        ed.redraw();
                    },
                    0x53 => {
                        ed.deleteFwd();
                        ed.redraw();
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
                ed.last_was_tab = false;
                switch (sc) {
                    0x1E => {
                        ed.cursor = 0;
                        ed.redraw();
                    }, // Ctrl+A
                    0x12 => {
                        ed.cursor = ed.len;
                        ed.redraw();
                    }, // Ctrl+E
                    0x25 => {
                        ed.killToEnd();
                        ed.redraw();
                    }, // Ctrl+K
                    0x16 => {
                        ed.killToStart();
                        ed.redraw();
                    }, // Ctrl+U
                    0x26 => { // Ctrl+L
                        write("\x1b[2J\x1b[H");
                        writePrompt();
                        ed.redraw();
                    },
                    0x2E => { // Ctrl+C
                        write("^C\n");
                        writePrompt();
                        ed.reset();
                        ed.redraw();
                    },
                    0x20 => { // Ctrl+D: EOF only on empty line
                        if (ed.len == 0) {
                            write("\n");
                            return null;
                        }
                    },
                    0x13 => { // Ctrl+R: reverse history search
                        searchHistory(ed);
                        writePrompt();
                        ed.redraw();
                    },
                    else => {},
                }
                continue;
            }

            // Escape key (scancode 0x01): clear line
            if (sc == 0x01) {
                ed.last_was_tab = false;
                ed.reset();
                write("\r\x1b[K");
                writePrompt();
                ed.redraw();
                continue;
            }

            const table = if (shift) &SC_SHIFT else &SC_NORMAL;
            if (sc >= table.len) continue;
            const ch = table[sc];
            if (ch == 0) continue;

            if (ch == '\n') {
                ed.last_was_tab = false;
                write("\n");
                return ed.line();
            } else if (ch == '\x08') {
                ed.last_was_tab = false;
                ed.deleteBack();
                ed.redraw();
            } else if (ch == '\t') {
                tabComplete(ed);
                ed.last_was_tab = true;
                ed.redraw();
            } else if (ch >= 0x20 and ch < 0x7F) {
                ed.last_was_tab = false;
                ed.insert(ch);
                ed.redraw();
            }
        }
    }
}

/// True for chars that may appear in a shell variable name: [A-Za-z0-9_].
fn isIdentChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_' => true,
        else => false,
    };
}

/// Expand $VARNAME at `input[pos]` (pos points at '$'). Copies the value into
/// storage[spos..], advances *pos past the name, advances *spos past the value.
fn expandVar(input: []const u8, pos: *usize, storage: []u8, spos: *usize) void {
    pos.* += 1; // skip '$'
    const vstart = pos.*;
    while (pos.* < input.len and isIdentChar(input[pos.*])) pos.* += 1;
    const varval = envGet(input[vstart..pos.*]) orelse "";
    const copy_len = @min(varval.len, storage.len - spos.*);
    @memcpy(storage[spos.*..][0..copy_len], varval[0..copy_len]);
    spos.* += copy_len;
}

/// Split `input` into up to `argv.len` tokens, writing token bytes into
/// `storage`. Handles single- and double-quoted strings (spaces inside
/// quotes become part of the token). Expands $VAR in unquoted and
/// double-quoted contexts. Sets `*background` if a bare `&` is found.
/// Returns token count.
fn tokenize(
    input: []const u8,
    argv: [][]const u8,
    storage: []u8,
    background: *bool,
) usize {
    var argc: usize = 0;
    var spos: usize = 0;
    background.* = false;

    var pos: usize = 0;
    while (pos < input.len and argc < argv.len) {
        // Skip whitespace between tokens.
        while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t')) pos += 1;
        if (pos >= input.len) break;

        // Bare `&` (standalone) = background flag.
        if (input[pos] == '&') {
            background.* = true;
            pos += 1;
            continue;
        }

        // Collect one token (may be multiple adjacent quoted/unquoted segments).
        const tok_start = spos;
        while (pos < input.len) {
            const c = input[pos];

            if (c == ' ' or c == '\t') break; // unquoted whitespace ends token

            if (c == '\'') {
                // Single-quoted: all chars literal until closing '.
                pos += 1;
                while (pos < input.len and input[pos] != '\'') {
                    if (spos < storage.len) {
                        storage[spos] = input[pos];
                        spos += 1;
                    }
                    pos += 1;
                }
                if (pos < input.len) pos += 1; // skip closing '
                continue;
            }

            if (c == '"') {
                // Double-quoted: $VAR expansion, everything else literal.
                pos += 1;
                while (pos < input.len and input[pos] != '"') {
                    if (input[pos] == '$') {
                        expandVar(input, &pos, storage, &spos);
                    } else {
                        if (spos < storage.len) {
                            storage[spos] = input[pos];
                            spos += 1;
                        }
                        pos += 1;
                    }
                }
                if (pos < input.len) pos += 1; // skip closing "
                continue;
            }

            if (c == '&') { // trailing unquoted &
                background.* = true;
                pos += 1;
                break;
            }

            if (c == '$') {
                // Unquoted $VAR expansion.
                expandVar(input, &pos, storage, &spos);
                continue;
            }

            if (spos < storage.len) {
                storage[spos] = c;
                spos += 1;
            }
            pos += 1;
        }

        const tok_len = spos - tok_start;
        if (tok_len > 0) {
            argv[argc] = storage[tok_start..spos];
            argc += 1;
        }
    }

    return argc;
}

fn cmdHelp() void {
    write(
        \\Built-in commands:
        \\  help               this message
        \\  echo <text>        print text (supports $VAR)
        \\  clear              clear screen
        \\  exit [n]           exit shell with status n (default 0)
        \\  cd [dir]           change directory (updates $PWD)
        \\  uname              OS info
        \\  pwd                print working directory
        \\  ls                 list available programs
        \\  env                print environment variables
        \\  export KEY=VALUE   set environment variable
        \\  history [n]        show history (last n entries)
        \\  meminfo            uptime and memory info
        \\  cpuinfo            CPU information
        \\  time <cmd> [args]  time a command
        \\  ifconfig [ip]      show or set the network IP address
        \\  ping <ip>          send ICMP echo to IP (default gateway: 10.0.2.2)
        \\  <prog> [args] [&]  run a program (& = background)
        \\
        \\Command chaining:
        \\  cmd1 ; cmd2        run cmd2 unconditionally after cmd1
        \\  cmd1 && cmd2       run cmd2 only if cmd1 succeeds (exit 0)
        \\
        \\Quoting:
        \\  "arg with spaces"  double-quoted: preserves spaces, expands $VAR
        \\  'literal string'   single-quoted: no expansion
        \\
        \\Line editing:
        \\  Tab                complete command name
        \\  Left/Right         move cursor       Up/Down    history
        \\  Home/End           line start/end    Del        delete forward
        \\  Right (at end)     accept autosuggestion (shown in gray)
        \\  Ctrl+A/E           home/end          Ctrl+K     kill to end
        \\  Ctrl+U             kill to start     Ctrl+L     clear screen
        \\  Ctrl+R             reverse history search
        \\  Ctrl+C             cancel line       Ctrl+D     exit (empty line)
        \\  Esc                clear line
        \\
    );
}

fn cmdHistory(args: []const u8) void {
    const limit: usize = if (args.len > 0) (std.fmt.parseInt(usize, trimRight(args), 10) catch 20) else 20;
    const show = @min(limit, hist_total);
    var i: usize = show;
    while (i > 0) : (i -= 1) {
        if (histGet(i)) |entry| {
            innigkeit.io.stdout.print("{d:>4}  {s}\n", .{ hist_count - i + 1, entry }) catch {};
        }
    }
}

fn cmdMeminfo() void {
    const ms = innigkeit.display.uptimeMs();
    innigkeit.io.stdout.print(
        "Uptime:  {d:0>2}:{d:0>2}:{d:0>2}\nMemory:  (physical page stats via cap_invoke pending)\n",
        .{ ms / 3600000, (ms / 60000) % 60, (ms / 1000) % 60 },
    ) catch {};
}

fn cmdCpuinfo() void {
    write("Architecture: x86_64\nOS: Innigkeit 0.1.0\nScheduler: EEVDF fair + RT\n");
}

fn cmdEnv() void {
    for (env_table[0..env_count]) |*e| {
        innigkeit.io.stdout.print("{s}={s}\n", .{ e.key[0..e.klen], e.val[0..e.vlen] }) catch {};
    }
}

fn cmdExport(args: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, args, '=') orelse {
        writeln("export: usage: export KEY=VALUE");
        return;
    };
    const key = trimRight(args[0..eq]);
    const val = args[eq + 1 ..];
    if (key.len == 0) {
        writeln("export: empty key");
        return;
    }
    envSet(key, val);
}

fn cmdCd(args: []const u8) void {
    const target = trimRight(trimLeft(args));
    if (target.len == 0) {
        envSet("PWD", "/");
        return;
    }
    // Absolute path: use as-is. Relative: append to current PWD.
    if (target[0] == '/') {
        envSet("PWD", target);
    } else {
        const cwd = envGet("PWD") orelse "/";
        var buf: [256]u8 = undefined;
        const result = if (std.mem.eql(u8, cwd, "/"))
            std.fmt.bufPrint(&buf, "/{s}", .{target}) catch {
                writeln("cd: path too long");
                return;
            }
        else
            std.fmt.bufPrint(&buf, "{s}/{s}", .{ cwd, target }) catch {
                writeln("cd: path too long");
                return;
            };
        envSet("PWD", result);
    }
}

fn cmdLs() void {
    write("Built-ins:\n  cd clear cpuinfo echo env exit export help history ls meminfo pwd time uname\n");
    write("Programs (initfs):\n ");
    for (KNOWN_PROGRAMS) |p| {
        innigkeit.io.stdout.print("  {s}", .{p}) catch {};
    }
    write("\n");
}

/// Run a single command and return exit status (0 = success).
fn runCommand(cmd: []const u8) u8 {
    const trimmed = trimRight(trimLeft(cmd));
    if (trimmed.len == 0) return 0;

    if (std.mem.startsWith(u8, trimmed, "export ")) {
        cmdExport(trimLeft(trimmed[7..]));
        return 0;
    }

    var argv_strs: [64][]const u8 = undefined;
    var argv_storage: [LINE_MAX * 2]u8 = undefined;
    var background = false;
    const argc = tokenize(trimmed, &argv_strs, &argv_storage, &background);
    if (argc == 0) return 0;

    const verb = argv_strs[0];
    const args = if (argc > 1) std.mem.trimStart(u8, trimmed[verb.len..], " \t") else "";

    if (std.mem.eql(u8, verb, "help")) {
        cmdHelp();
        return 0;
    } else if (std.mem.eql(u8, verb, "echo")) {
        innigkeit.io.stdout.print("{s}\n", .{args}) catch {};
        return 0;
    } else if (std.mem.eql(u8, verb, "uname")) {
        write("Innigkeit 0.1.0 x86_64\n");
        return 0;
    } else if (std.mem.eql(u8, verb, "clear")) {
        write("\x1b[2J\x1b[H");
        return 0;
    } else if (std.mem.eql(u8, verb, "exit")) {
        const code = if (args.len > 0) (std.fmt.parseInt(u8, trimRight(args), 10) catch 0) else 0;
        innigkeit.process.exit(code);
    } else if (std.mem.eql(u8, verb, "cd")) {
        cmdCd(args);
        return 0;
    } else if (std.mem.eql(u8, verb, "pwd")) {
        writeln(envGet("PWD") orelse "/");
        return 0;
    } else if (std.mem.eql(u8, verb, "ls")) {
        cmdLs();
        return 0;
    } else if (std.mem.eql(u8, verb, "env")) {
        cmdEnv();
        return 0;
    } else if (std.mem.eql(u8, verb, "history")) {
        cmdHistory(args);
        return 0;
    } else if (std.mem.eql(u8, verb, "meminfo")) {
        cmdMeminfo();
        return 0;
    } else if (std.mem.eql(u8, verb, "cpuinfo")) {
        cmdCpuinfo();
        return 0;
    } else if (std.mem.eql(u8, verb, "time")) {
        return cmdTime(argv_strs[1..argc], background);
    } else if (std.mem.eql(u8, verb, "ifconfig")) {
        return cmdIfconfig(argc, argv_strs[0..argc]);
    } else if (std.mem.eql(u8, verb, "ping")) {
        return cmdPing(args);
    } else {
        return spawnProgram(verb, argv_strs[1..argc], background);
    }
    return 0;
}

fn parseIp4(s: []const u8) ?innigkeit.net.Ip4 {
    var ip: innigkeit.net.Ip4 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&ip) |*b| {
        const tok = it.next() orelse return null;
        b.* = std.fmt.parseInt(u8, tok, 10) catch return null;
    }
    if (it.next() != null) return null;
    return ip;
}

fn cmdIfconfig(argc: usize, argv: [][]const u8) u8 {
    if (argc < 2) {
        if (innigkeit.net.getMac()) |mac| {
            innigkeit.io.stdout.print("eth0: mac={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] }) catch {};
        } else {
            writeln("eth0: no NIC");
        }
        return 0;
    }
    const ip = parseIp4(argv[1]) orelse {
        writeln("ifconfig: bad address (use A.B.C.D)");
        return 1;
    };
    innigkeit.net.setIp(ip);
    innigkeit.io.stdout.print("eth0: ip set to {d}.{d}.{d}.{d}\n", .{ ip[0], ip[1], ip[2], ip[3] }) catch {};
    return 0;
}

fn cmdPing(args: []const u8) u8 {
    const target = std.mem.trimStart(u8, args, " \t");
    if (target.len == 0) {
        writeln("ping: usage: ping <ip>");
        return 1;
    }
    const ip = parseIp4(target) orelse {
        writeln("ping: bad address (use A.B.C.D)");
        return 1;
    };
    innigkeit.io.stdout.print("PING {d}.{d}.{d}.{d}\n", .{ ip[0], ip[1], ip[2], ip[3] }) catch {};
    const rtt = innigkeit.net.ping(ip, 2000) catch {
        writeln("ping: no reply (timeout 2s)");
        return 1;
    };
    innigkeit.io.stdout.print("reply from {d}.{d}.{d}.{d}: time={d}ms\n", .{ ip[0], ip[1], ip[2], ip[3], rtt }) catch {};
    return 0;
}

fn cmdTime(argv: [][]const u8, background: bool) u8 {
    if (argv.len == 0) {
        writeln("time: usage: time <command> [args]");
        return 1;
    }
    const t0 = innigkeit.display.uptimeMs();
    const status = spawnProgram(argv[0], argv[1..], background);
    const elapsed = innigkeit.display.uptimeMs() - t0;
    innigkeit.io.stdout.print("real {d}.{d:0>3}s\n", .{ elapsed / 1000, elapsed % 1000 }) catch {};
    return status;
}

fn spawnProgram(verb: []const u8, args: [][]const u8, background: bool) u8 {
    var path_buf: [256]u8 = undefined;
    if (verb.len >= path_buf.len) {
        writeln("command too long");
        return 127;
    }
    @memcpy(path_buf[0..verb.len], verb);
    path_buf[verb.len] = 0;
    const path: [:0]const u8 = path_buf[0..verb.len :0];

    const handle = innigkeit.process.spawnArgs(path, args) catch |err| {
        const msg = if (err == error.NotFound) "command not found" else "spawn failed";
        innigkeit.io.stdout.print("{s}: {s}\n", .{ msg, verb }) catch {};
        return if (err == error.NotFound) 127 else 1;
    };

    if (background) {
        innigkeit.io.stdout.print("[bg pid={d}]\n", .{handle}) catch {};
        return 0;
    }

    var kbd: [8]u8 = undefined;
    var kill_ctrl = false;
    const status: u8 = blk: {
        while (true) {
            if (innigkeit.process.waitProcessNb(handle)) |s| break :blk s else |err| {
                if (err != error.WouldBlock) break :blk 0;
            }
            const n = innigkeit.display.kbdRead(&kbd);
            for (kbd[0..n]) |b| {
                if (b == 0x9D) {
                    kill_ctrl = false;
                    continue;
                } // ctrl release
                if (b == 0x1D) {
                    kill_ctrl = true;
                    continue;
                } // ctrl press
                if (b & 0x80 != 0) continue; // other releases
                if (kill_ctrl and b == 0x2E) { // ctrl+c ('c' make = 0x2E)
                    innigkeit.process.killProcess(handle) catch {};
                    break :blk @as(u8, 130);
                }
            }
            innigkeit.sleep(10 * std.time.ns_per_ms);
        }
    };

    if (status != 0) {
        innigkeit.io.stdout.print("{s}: exited {d}\n", .{ verb, status }) catch {};
    }
    return status;
}

/// Execute `line`, handling `;` and `&&` operators at the top level
/// (outside quotes). Returns the last command's exit status.
fn runLine(line: []const u8) u8 {
    var rest = trimLeft(trimRight(line));
    var last_status: u8 = 0;
    var require_success = false; // true after `&&`

    while (rest.len > 0) {
        // Locate the next unquoted `;` or `&&`.
        var in_sq = false;
        var in_dq = false;
        var sep_pos: ?usize = null;
        var sep_len: usize = 1;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const c = rest[i];
            if (c == '\'' and !in_dq) {
                in_sq = !in_sq;
                continue;
            }
            if (c == '"' and !in_sq) {
                in_dq = !in_dq;
                continue;
            }
            if (in_sq or in_dq) continue;
            if (c == ';') {
                sep_pos = i;
                sep_len = 1;
                break;
            }
            if (c == '&' and i + 1 < rest.len and rest[i + 1] == '&') {
                sep_pos = i;
                sep_len = 2;
                break;
            }
        }

        const cmd_end = sep_pos orelse rest.len;
        const cmd = trimRight(trimLeft(rest[0..cmd_end]));

        if (!require_success or last_status == 0) {
            if (cmd.len > 0) last_status = runCommand(cmd);
        }

        if (sep_pos) |pos| {
            require_success = (sep_len == 2); // `&&` -> next cmd needs success
            rest = trimLeft(rest[pos + sep_len ..]);
        } else {
            break;
        }
    }
    return last_status;
}

fn trimRight(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and (s[e - 1] == ' ' or s[e - 1] == '\t' or s[e - 1] == '\r')) e -= 1;
    return s[0..e];
}

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

pub fn main() void {
    envSet("PWD", "/");
    envSet("SHELL", "shell");
    envSet("TERM", "ansi");

    write("\x1b[2J\x1b[H");
    write(
        "Innigkeit OS shell  (type 'help' for commands, Tab to complete)\n" ++
            "────────────────────────────────────────────────────────────────\n",
    );

    var ed: LineEditor = .{};
    while (true) {
        writePrompt();
        const line = readline(&ed) orelse break;
        const trimmed = trimRight(line);
        if (trimmed.len > 0) {
            histPush(trimmed);
            _ = runLine(trimmed);
        }
    }

    write("logout\n");
    innigkeit.process.exit(0);
}
