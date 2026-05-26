const std = @import("std");
const innigkeit = @import("innigkeit");

pub const std_options = innigkeit.interop.std_options;
pub const std_options_debug_io = innigkeit.interop.debug_io;
pub const std_options_thread_impl = innigkeit.thread.InnigkeitThreadImpl;
pub const panic = innigkeit.interop.panic;

var line_buf: [256]u8 = undefined;

pub fn main() void {
    innigkeit.io.stdout.print(
        "\nwelcome to innigkeit shell: type 'help' for commands\n",
        .{},
    ) catch return;
    prompt();

    while (true) {
        const line = innigkeit.io.stdin.readLine(&line_buf) catch |err| {
            innigkeit.io.stdout.print("read error: {}\n", .{err}) catch {};
            prompt();
            continue;
        };

        if (line.len > 0) runCommand(line);
        prompt();
    }
}

fn prompt() void {
    innigkeit.io.stdout.print("> ", .{}) catch {};
}

fn runCommand(line: []const u8) void {
    const cmd = trimRight(line);
    if (cmd.len == 0) return;

    const space_idx = std.mem.indexOfScalar(u8, cmd, ' ');
    const verb = if (space_idx) |i| cmd[0..i] else cmd;
    const args = if (space_idx) |i| trimLeft(cmd[i + 1 ..]) else "";

    if (std.mem.eql(u8, verb, "help")) {
        innigkeit.io.stdout.print(
            "Commands:\n" ++
                "  help          show this message\n" ++
                "  echo <text>   print text\n" ++
                "  uname         print OS info\n" ++
                "  clear         clear the screen\n" ++
                "  exit          exit the shell\n",
            .{},
        ) catch {};
    } else if (std.mem.eql(u8, verb, "echo")) {
        innigkeit.io.stdout.print("{s}\n", .{args}) catch {};
    } else if (std.mem.eql(u8, verb, "uname")) {
        innigkeit.io.stdout.print("Innigkeit x86_64\n", .{}) catch {};
    } else if (std.mem.eql(u8, verb, "clear")) {
        innigkeit.io.stdout.print("\x1b[2J\x1b[H", .{}) catch {};
    } else if (std.mem.eql(u8, verb, "exit")) {
        innigkeit.thread.exitCurrent();
    } else {
        // Try to launch the verb as a program in initfs.
        var path_buf: [256]u8 = undefined;
        if (verb.len >= path_buf.len) {
            innigkeit.io.stdout.print("command too long\n", .{}) catch {};
            return;
        }

        @memcpy(path_buf[0..verb.len], verb);
        path_buf[verb.len] = 0;
        const path: [:0]const u8 = path_buf[0..verb.len :0];

        // Split trailing args string into whitespace-separated tokens (max 63).
        var argv_strs: [63][]const u8 = undefined;
        var argc: usize = 0;
        var rest = args;
        while (rest.len > 0 and argc < argv_strs.len) {
            rest = trimLeft(rest);
            if (rest.len == 0) break;
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            argv_strs[argc] = rest[0..end];
            argc += 1;
            rest = rest[end..];
        }

        const handle = innigkeit.process.spawnArgs(path, argv_strs[0..argc]) catch |err| {
            const msg = if (err == error.NotFound) "command not found" else "spawn failed";
            innigkeit.io.stdout.print("{s}: {s}\n", .{ msg, verb }) catch {};
            return;
        };
        innigkeit.process.waitProcess(handle) catch {};
    }
}

fn trimRight(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    return s[0..end];
}

fn trimLeft(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    return s[start..];
}

pub const _start = void;
comptime {
    innigkeit.exportEntry();
}
