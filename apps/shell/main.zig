const std = @import("std");
const innigkeit = @import("innigkeit");

const LineEditor = @import("LineEditor.zig");
const commands = @import("commands.zig");
const environment = @import("environment.zig");
const completions = @import("completions.zig");

pub fn write(s: []const u8) void {
    innigkeit.io.stdout.print("{s}", .{s}) catch {};
}

pub fn writePrompt() void {
    const cwd = environment.get("PWD") orelse "/";
    innigkeit.io.stdout.print("{s}$ ", .{cwd}) catch {};
}

/// Execute `line`, handling `;` and `&&` operators at the top level
/// (outside quotes). Returns the last command's exit status.
fn runLine(line: []const u8) u8 {
    var rest = commands.trimLeft(commands.trimRight(line));
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
        const cmd = commands.trimRight(commands.trimLeft(rest[0..cmd_end]));

        if (!require_success or last_status == 0) {
            if (cmd.len > 0) last_status = commands.run(cmd);
        }

        if (sep_pos) |pos| {
            require_success = (sep_len == 2); // `&&` -> next cmd needs success
            rest = commands.trimLeft(rest[pos + sep_len ..]);
        } else {
            break;
        }
    }
    return last_status;
}

pub fn main() void {
    environment.set("PWD", "/");
    environment.set("SHELL", "shell");
    environment.set("TERM", "ansi");

    write("\x1b[2J\x1b[H");
    write(
        "Innigkeit OS shell  (type 'help' for commands, Tab to complete)\n" ++
            "────────────────────────────────────────────────────────────────\n",
    );

    var ed: LineEditor = .{};
    while (true) {
        writePrompt();
        const line = ed.readline() orelse break;
        const trimmed = commands.trimRight(line);
        if (trimmed.len > 0) {
            completions.push(trimmed);
            _ = runLine(trimmed);
        }
    }

    write("logout\n");
    innigkeit.process.exit(0);
}
