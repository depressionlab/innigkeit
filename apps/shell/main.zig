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
var hist_count: usize = 0; // total ever pushed (mod HIST_MAX gives index)
var hist_total: usize = 0; // entries currently stored (<= HIST_MAX)

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

/// Get history entry n (1 = most recent). Returns null if n > hist_total.
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

const LineEditor = struct {
    buf: [LINE_MAX]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    hist_pos: usize = 0,
    saved: [LINE_MAX]u8 = undefined,
    saved_len: usize = 0,

    fn reset(self: *LineEditor) void {
        self.len = 0;
        self.cursor = 0;
        self.hist_pos = 0;
    }

    fn redraw(self: *const LineEditor) void {
        write("\r> ");
        if (self.len > 0) innigkeit.io.stdout.print("{s}", .{self.buf[0..self.len]}) catch {};
        write("\x1b[K"); // clear to EOL
        if (self.cursor < self.len) {
            // Move cursor back to position
            innigkeit.io.stdout.print("\x1b[{d}D", .{self.len - self.cursor}) catch {};
        }
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

/// Read a line with full editing support. Returns null on Ctrl+D with empty line.
fn readline() ?[]const u8 {
    var ed: LineEditor = .{};
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
            // Break codes (key release): high bit set (except 0xE0)
            if (sc == 0xE0) {
                extended = true;
                continue;
            }
            if (sc & 0x80 != 0) {
                const base = sc & 0x7F;
                if (base == 0x2A or base == 0x36) shift = false; // shift release
                if (base == 0x1D) ctrl = false; // ctrl release
                extended = false;
                continue;
            }

            if (extended) {
                extended = false;
                switch (sc) {
                    0x48 => {
                        ed.histUp();
                        ed.redraw();
                    }, // up
                    0x50 => {
                        ed.histDown();
                        ed.redraw();
                    }, // down
                    0x4B => {
                        if (ed.cursor > 0) {
                            ed.cursor -= 1;
                            ed.redraw();
                        }
                    }, // left
                    0x4D => {
                        if (ed.cursor < ed.len) {
                            ed.cursor += 1;
                            ed.redraw();
                        }
                    }, // right
                    0x47 => {
                        ed.cursor = 0;
                        ed.redraw();
                    }, // home
                    0x4F => {
                        ed.cursor = ed.len;
                        ed.redraw();
                    }, // end
                    0x53 => {
                        ed.deleteFwd();
                        ed.redraw();
                    }, // del
                    else => {},
                }
                continue;
            }

            // Modifier keys
            if (sc == 0x2A or sc == 0x36) {
                shift = true;
                continue;
            } // shift
            if (sc == 0x1D) {
                ctrl = true;
                continue;
            } // ctrl

            if (ctrl) {
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
                    0x26 => {
                        write("\x1b[2J\x1b[H");
                        writePrompt();
                        ed.redraw();
                    }, // Ctrl+L clear
                    0x2E => {
                        write("^C\n");
                        writePrompt();
                        ed.reset();
                        ed.redraw();
                    }, // Ctrl+C
                    0x20 => { // Ctrl+D on empty -> EOF
                        if (ed.len == 0) {
                            write("\n");
                            return null;
                        }
                    },
                    else => {},
                }
                continue;
            }

            const table = if (shift) &SC_SHIFT else &SC_NORMAL;
            if (sc >= table.len) continue;
            const ch = table[sc];
            if (ch == 0) continue;

            if (ch == '\n') {
                write("\n");
                return ed.line();
            } else if (ch == '\x08') {
                ed.deleteBack();
                ed.redraw();
            } else if (ch >= 0x20 and ch < 0x7F) {
                ed.insert(ch);
                ed.redraw();
            }
        }
    }
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

/// Split line into up to 64 tokens. Expands $VAR references.
/// Sets `background` if trailing `&` found. Returns token count.
fn tokenize(
    line: []const u8,
    argv: [][]const u8,
    storage: []u8,
    background: *bool,
) usize {
    var argc: usize = 0;
    var spos: usize = 0;
    var rest = trimLeft(line);
    background.* = false;

    while (rest.len > 0 and argc < argv.len) {
        rest = trimLeft(rest);
        if (rest.len == 0) break;

        // Detect trailing `&`
        if (rest[0] == '&') {
            background.* = true;
            break;
        }

        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        var token = rest[0..end];

        // Strip trailing `&`
        if (token.len > 0 and token[token.len - 1] == '&') {
            background.* = true;
            token = token[0 .. token.len - 1];
        }

        if (token.len == 0) {
            rest = rest[end..];
            continue;
        }

        // $VAR expansion
        if (token.len > 1 and token[0] == '$') {
            const varname = token[1..];
            token = envGet(varname) orelse "";
        }

        if (spos + token.len > storage.len) break;
        @memcpy(storage[spos..][0..token.len], token);
        argv[argc] = storage[spos..][0..token.len];
        spos += token.len;
        argc += 1;

        rest = rest[end..];
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
        \\  uname              OS info
        \\  pwd                print working directory
        \\  ls                 list available programs
        \\  env                print environment variables
        \\  export KEY=VALUE   set environment variable
        \\  history [n]        show history (last n entries)
        \\  meminfo            physical memory usage
        \\  cpuinfo            CPU information
        \\  time <cmd> [args]  time a command
        \\  <prog> [args] [&]  run a program (& = background)
        \\
        \\Line editing:
        \\  Left/Right         move cursor    Up/Down   history
        \\  Home/End           line start/end  Del       delete forward
        \\  Ctrl+A/E           home/end       Ctrl+K    kill to end
        \\  Ctrl+U             kill to start  Ctrl+L    clear screen
        \\  Ctrl+C             cancel line    Ctrl+D    exit (empty line)
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

const KNOWN_PROGRAMS = [_][]const u8{
    "shell", "wm", "pixels", "gfx_demo", "shader_demo", "doom",
};

fn cmdLs() void {
    write("Built-ins:\n  help echo clear exit uname pwd ls env export history meminfo cpuinfo time\n");
    write("Programs (initfs):\n ");
    for (KNOWN_PROGRAMS) |p| {
        innigkeit.io.stdout.print("  {s}", .{p}) catch {};
    }
    write("\n");
}

fn runCommand(line: []const u8) void {
    const cmd = trimRight(line);
    if (cmd.len == 0) return;

    // Check for `export KEY=VALUE` first (special syntax)
    if (std.mem.startsWith(u8, cmd, "export ")) {
        cmdExport(trimLeft(cmd[7..]));
        return;
    }

    var argv_strs: [64][]const u8 = undefined;
    var argv_storage: [LINE_MAX * 2]u8 = undefined;
    var background = false;
    const argc = tokenize(cmd, &argv_strs, &argv_storage, &background);
    if (argc == 0) return;

    const verb = argv_strs[0];
    const args = if (argc > 1) std.mem.trimStart(u8, cmd[verb.len..], " \t") else "";

    if (std.mem.eql(u8, verb, "help")) {
        cmdHelp();
    } else if (std.mem.eql(u8, verb, "echo")) {
        innigkeit.io.stdout.print("{s}\n", .{args}) catch {};
    } else if (std.mem.eql(u8, verb, "uname")) {
        write("Innigkeit 0.1.0 x86_64\n");
    } else if (std.mem.eql(u8, verb, "clear")) {
        write("\x1b[2J\x1b[H");
    } else if (std.mem.eql(u8, verb, "exit")) {
        const code = if (args.len > 0) (std.fmt.parseInt(u8, trimRight(args), 10) catch 0) else 0;
        innigkeit.process.exit(code);
    } else if (std.mem.eql(u8, verb, "pwd")) {
        writeln(envGet("PWD") orelse "/");
    } else if (std.mem.eql(u8, verb, "ls")) {
        cmdLs();
    } else if (std.mem.eql(u8, verb, "env")) {
        cmdEnv();
    } else if (std.mem.eql(u8, verb, "history")) {
        cmdHistory(args);
    } else if (std.mem.eql(u8, verb, "meminfo")) {
        cmdMeminfo();
    } else if (std.mem.eql(u8, verb, "cpuinfo")) {
        cmdCpuinfo();
    } else if (std.mem.eql(u8, verb, "time")) {
        cmdTime(argv_strs[1..argc], &background);
    } else {
        spawnProgram(verb, argv_strs[1..argc], background);
    }
}

fn cmdTime(argv: [][]const u8, background: *bool) void {
    if (argv.len == 0) {
        writeln("time: usage: time <command> [args]");
        return;
    }
    const t0 = innigkeit.display.uptimeMs();
    spawnProgram(argv[0], argv[1..], background.*);
    background.* = false; // time always foreground
    const elapsed = innigkeit.display.uptimeMs() - t0;
    innigkeit.io.stdout.print("real {d}.{d:0>3}s\n", .{ elapsed / 1000, elapsed % 1000 }) catch {};
}

fn spawnProgram(verb: []const u8, args: [][]const u8, background: bool) void {
    var path_buf: [256]u8 = undefined;
    if (verb.len >= path_buf.len) {
        writeln("command too long");
        return;
    }
    @memcpy(path_buf[0..verb.len], verb);
    path_buf[verb.len] = 0;
    const path: [:0]const u8 = path_buf[0..verb.len :0];

    const handle = innigkeit.process.spawnArgs(path, args) catch |err| {
        const msg = if (err == error.NotFound) "command not found" else "spawn failed";
        innigkeit.io.stdout.print("{s}: {s}\n", .{ msg, verb }) catch {};
        return;
    };

    if (background) {
        innigkeit.io.stdout.print("[bg pid={d}]\n", .{handle}) catch {};
        return;
    }

    // Foreground: poll for exit, check Ctrl+C.
    const status: u8 = blk: {
        var kbd: [8]u8 = undefined;
        while (true) {
            if (innigkeit.process.waitProcessNb(handle)) |s| break :blk s else |err| {
                if (err != error.WouldBlock) break :blk 0;
            }
            const n = innigkeit.display.kbdRead(&kbd);
            for (kbd[0..n]) |b| {
                if (b == 0x03) {
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

// TODO: make this not terrible
pub fn main() void {
    envSet("PWD", "/");
    envSet("SHELL", "shell");
    envSet("TERM", "ansi");

    write("\x1b[2J\x1b[H");
    write(
        "Innigkeit OS shell  (type 'help' for commands)\n" ++
            "────────────────────────────────────────────────\n",
    );

    while (true) {
        writePrompt();
        const line = readline() orelse break; // Ctrl+D on empty = exit
        const trimmed = trimRight(line);
        if (trimmed.len > 0) {
            histPush(trimmed);
            runCommand(trimmed);
        }
    }

    write("logout\n");
    innigkeit.process.exit(0);
}
