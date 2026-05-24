const std = @import("std");
const innigkeit = @import("innigkeit");

pub const std_options = innigkeit.interop.std_options;
pub const std_options_debug_io = innigkeit.interop.debug_io;
pub const panic = innigkeit.interop.panic;

var line_buf: [256]u8 = undefined;

pub fn main() void {
    innigkeit.io.stdout.print(
        "\nInnigkeit shell:  type 'help' for commands\n",
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
        innigkeit.io.stdout.print("Innigkeit OS  x86_64\n", .{}) catch {};
    } else if (std.mem.eql(u8, verb, "clear")) {
        innigkeit.io.stdout.print("\x1b[2J\x1b[H", .{}) catch {};
    } else if (std.mem.eql(u8, verb, "exit")) {
        innigkeit.thread.exitCurrent();
    } else {
        // Try to launch the verb as a program in initfs.
        var path_buf: [256]u8 = undefined;
        if (verb.len < path_buf.len) {
            @memcpy(path_buf[0..verb.len], verb);
            path_buf[verb.len] = 0;
            const path: [:0]const u8 = path_buf[0..verb.len :0];
            const handle = innigkeit.process.spawn(path, &.{}) catch {
                innigkeit.io.stdout.print("not found: '{s}'\n", .{verb}) catch {};
                return;
            };
            innigkeit.process.waitProcess(handle) catch {};
        } else {
            innigkeit.io.stdout.print("command too long\n", .{}) catch {};
        }
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
