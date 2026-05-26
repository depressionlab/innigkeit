const std = @import("std");
const innigkeit = @import("innigkeit");

pub const std_options = innigkeit.interop.std_options;
pub const std_options_debug_io = innigkeit.interop.debug_io;
pub const std_options_thread_impl = innigkeit.thread.InnigkeitThreadImpl;
pub const panic = innigkeit.interop.panic;

var buffer: [256]u8 = undefined;

pub fn main() void {
    innigkeit.io.stdout.print("=== Simple Calculator ===\n", .{}) catch return;
    innigkeit.io.stdout.print("Enter expression (e.g., '5 + 3')\n", .{}) catch return;
    innigkeit.io.stdout.print("Operations: +, -, *, /\n", .{}) catch return;
    innigkeit.io.stdout.print("Type 'quit' to exit\n\n", .{}) catch return;

    while (true) {
        innigkeit.io.stdout.print("> ", .{}) catch return;

        const line = innigkeit.io.stdin.readLine(&buffer) catch |err| {
            innigkeit.io.stdout.print("Read error: {}\n", .{err}) catch return;
            continue;
        };

        if (std.mem.eql(u8, line, "quit")) {
            innigkeit.io.stdout.print("Goodbye!\n", .{}) catch return;
            break;
        }

        if (line.len == 0) continue;

        if (parseAndCompute(line)) |value| {
            innigkeit.io.stdout.print("Result: {d}\n", .{value}) catch return;
        } else {
            innigkeit.io.stdout.print("Error: Invalid expression\n", .{}) catch return;
        }
    }

    innigkeit.thread.exitCurrent();
}

fn parseAndCompute(expr: []const u8) ?i64 {
    var tokens: [10]Token = undefined;
    var token_count: usize = 0;

    // Tokenize
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        if (expr[i] == ' ') continue;

        if (isOperator(expr[i])) {
            if (token_count >= tokens.len) return null;
            tokens[token_count] = .{ .op = expr[i] };
            token_count += 1;
        } else if (isDigit(expr[i])) {
            if (token_count >= tokens.len) return null;
            const start = i;
            while (i < expr.len and isDigit(expr[i])) : (i += 1) {}
            const num_str = expr[start..i];
            i -= 1;

            const num = std.fmt.parseInt(i64, num_str, 10) catch return null;
            tokens[token_count] = .{ .num = num };
            token_count += 1;
        }
    }

    if (token_count < 3 or token_count % 2 == 0) return null;

    // Simple left-to-right evaluation (no operator precedence)
    var result = if (tokens[0] == .num) tokens[0].num else return null;
    i = 1;

    while (i < token_count) {
        const op = if (tokens[i] == .op) tokens[i].op else return null;
        const operand = if (tokens[i + 1] == .num) tokens[i + 1].num else return null;

        result = compute(result, op, operand) orelse return null;
        i += 2;
    }

    return result;
}

fn compute(a: i64, op: u8, b: i64) ?i64 {
    return switch (op) {
        '+' => a + b,
        '-' => a - b,
        '*' => a * b,
        '/' => if (b != 0) @divTrunc(a, b) else null,
        else => null,
    };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isOperator(c: u8) bool {
    return c == '+' or c == '-' or c == '*' or c == '/';
}

const Token = union(enum) {
    num: i64,
    op: u8,
};

pub const _start = void;
comptime {
    innigkeit.exportEntry();
}
