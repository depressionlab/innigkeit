// zlinter-disable no_swallow_error - every catch here is a shell console
// print with no meaningful recovery path.
const innigkeit = @import("innigkeit");
const std = @import("std");

const LineEditor = @import("LineEditor.zig");
const write = @import("main.zig").write;
const writePrompt = @import("main.zig").writePrompt;
const scancode = @import("scancode.zig");

// TODO: automatically generate these
pub const BUILTIN_NAMES = [_][]const u8{
    "cat",     "cd",     "clear", "cpuinfo", "echo",     "env",
    "exit",    "export", "help",  "history", "ifconfig", "ls",
    "meminfo", "ping",   "pwd",   "time",    "uname",
};

pub const KNOWN_PROGRAMS = [_][]const u8{
    "calculator",  "doom",   "gfx_demo", "hello_world",
    "installer",   "pixels", "rust_cat", "rust_hello",
    "shader_demo", "shell",  "wm",
};

pub const ALL_COMPLETIONS = BUILTIN_NAMES ++ KNOWN_PROGRAMS;
pub const MAX = 50;

var entries: [MAX][LineEditor.MAX + 1]u8 = undefined;
var lens: [MAX]usize = [_]usize{0} ** MAX;
pub var count: usize = 0;
pub var total: usize = 0;

pub fn push(line: []const u8) void {
    if (line.len == 0) return;
    if (total > 0 and std.mem.eql(u8, line, entries[(count - 1) % MAX][0..lens[(count - 1) % MAX]])) return;
    const idx = count % MAX;
    const l = @min(line.len, LineEditor.MAX);
    @memcpy(entries[idx][0..l], line[0..l]);
    lens[idx] = l;
    count += 1;
    if (total < MAX) total += 1;
}

pub fn get(n: usize) ?[]const u8 {
    if (n == 0 or n > total) return null;
    const idx = (count -% n) % MAX;
    return entries[idx][0..lens[idx]];
}

/// Return the most recent history entry that starts with `current`, or null.
pub fn suggest(current: []const u8) ?[]const u8 {
    if (current.len == 0) return null;
    var n: usize = 1;
    while (n <= total) : (n += 1) {
        if (get(n)) |entry| {
            if (entry.len > current.len and std.mem.startsWith(u8, entry, current))
                return entry;
        }
    }
    return null;
}

/// Handle Tab key: complete command name prefix or show matches.
pub fn tabComplete(ed: *LineEditor) void {
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

/// Ctrl+R incremental reverse history search.
/// Loads the accepted entry into `ed` on Enter; cancels on Escape.
pub fn search(ed: *LineEditor) void {
    var query: [LineEditor.MAX]u8 = undefined;
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
            while (n <= total) : (n += 1) {
                if (get(n)) |entry| {
                    if (std.mem.find(u8, entry, q) != null) {
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

            const table = scancode.get(shift2);
            if (sc >= table.len) continue;
            const ch = table[sc];
            if (ch == 0) continue;

            if (ch == '\n') {
                // Accept: find match and load into editor
                const q = query[0..query_len];
                var i: usize = 1;
                while (i <= total) : (i += 1) {
                    if (get(i)) |entry| {
                        if (std.mem.find(u8, entry, q) != null) {
                            const cl = @min(entry.len, LineEditor.MAX);
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
                if (query_len < LineEditor.MAX) {
                    query[query_len] = ch;
                    query_len += 1;
                }
            } else continue;

            drawSearch(query[0..query_len]);
        }
    }
}
