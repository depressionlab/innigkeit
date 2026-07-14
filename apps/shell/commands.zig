// zlinter-disable no_swallow_error - every catch here is a shell console
// print with no meaningful recovery path.
const innigkeit = @import("innigkeit");
const std = @import("std");

const completions = @import("completions.zig");
const environment = @import("environment.zig");
const LineEditor = @import("LineEditor.zig");
const write = @import("main.zig").write;

/// Run a single command and return exit status (0 = success).
pub fn run(cmd: []const u8) u8 {
    const trimmed = trimRight(trimLeft(cmd));
    if (trimmed.len == 0) return 0;

    if (std.mem.startsWith(u8, trimmed, "export ")) {
        cmdExport(trimLeft(trimmed[7..]));
        return 0;
    }

    var argv_strs: [64][]const u8 = undefined;
    var argv_storage: [LineEditor.MAX * 2]u8 = undefined;
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
        writeln(environment.get("PWD") orelse "/");
        return 0;
    } else if (std.mem.eql(u8, verb, "ls")) {
        cmdLs();
        return 0;
    } else if (std.mem.eql(u8, verb, "cat")) {
        return cmdCat(args);
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
    const show = @min(limit, completions.total);
    var i: usize = show;
    while (i > 0) : (i -= 1) {
        if (completions.get(i)) |entry| {
            innigkeit.io.stdout.print(
                "{d:>4}  {s}\n",
                .{ completions.count - i + 1, entry },
            ) catch {};
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
    for (environment.table[0..environment.count]) |*e| {
        innigkeit.io.stdout.print("{s}={s}\n", .{ e.key[0..e.klen], e.val[0..e.vlen] }) catch {};
    }
}

fn cmdExport(args: []const u8) void {
    const eq = std.mem.findScalar(u8, args, '=') orelse {
        writeln("export: usage: export KEY=VALUE");
        return;
    };
    const key = trimRight(args[0..eq]);
    const val = args[eq + 1 ..];
    if (key.len == 0) {
        writeln("export: empty key");
        return;
    }
    environment.set(key, val);
}

fn cmdCd(args: []const u8) void {
    const target = trimRight(trimLeft(args));
    if (target.len == 0) {
        environment.set("PWD", "/");
        return;
    }
    // Absolute path: use as-is. Relative: append to current PWD.
    if (target[0] == '/') {
        environment.set("PWD", target);
    } else {
        const cwd = environment.get("PWD") orelse "/";
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
        environment.set("PWD", result);
    }
}

fn cmdLs() void {
    write("Built-ins:\n  cat cd clear cpuinfo echo env exit export help history ls meminfo pwd time uname\n");
    write("Programs (initfs):\n ");
    for (completions.KNOWN_PROGRAMS) |p| {
        innigkeit.io.stdout.print("  {s}", .{p}) catch {};
    }
    write("\n");
}

fn parseIp4(s: []const u8) ?innigkeit.network.Ip4 {
    var ip: innigkeit.network.Ip4 = undefined;
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
        if (innigkeit.network.getMac()) |mac| {
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
    innigkeit.network.setIp(ip);
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
    const rtt = innigkeit.network.ping(ip, 2000) catch {
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

/// `cat <path>`: print a file via the per-process fd table
/// (open / read / close syscalls).
fn cmdCat(args: []const u8) u8 {
    const path = trimRight(trimLeft(args));
    if (path.len == 0) {
        write("usage: cat <path>\n");
        return 1;
    }

    const file = innigkeit.filesystem.File.open(path, .{}) catch |err| {
        innigkeit.io.stdout.print("cat: {s}: {t}\n", .{ path, err }) catch {};
        return 1;
    };
    defer file.close();

    var buf: [512]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch |err| {
            innigkeit.io.stdout.print("cat: read error: {t}\n", .{err}) catch {};
            return 1;
        };
        if (n == 0) break;
        write(buf[0..n]);
    }
    return 0;
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

pub fn trimRight(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and (s[e - 1] == ' ' or s[e - 1] == '\t' or s[e - 1] == '\r')) e -= 1;
    return s[0..e];
}

pub fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
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
                        environment.expand(input, &pos, storage, &spos);
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
                environment.expand(input, &pos, storage, &spos);
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

fn writeln(s: []const u8) void {
    innigkeit.io.stdout.print("{s}\n", .{s}) catch {};
}
