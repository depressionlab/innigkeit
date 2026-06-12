//! Standard library integration for Innigkeit userspace apps.
//!
//! Wire these two declarations into each app's root file:
//!
//! ```zig
//! const innigkeit = @import("innigkeit");
//! pub const std_options = innigkeit.stdlib_config.std_options;
//! pub const panic = innigkeit.stdlib_config.panic;
//! ```
//!
//! ## Logging
//!
//! Use `std.log.*` for diagnostic output: routes to stderr via write syscall.
//! Use `std.debug.print` for formatted debug output (also goes to stderr).
//! Use `innigkeit.io.stdout` for user-visible program output.
//!
//! Override the default log level by declaring in your root file:
//!
//! ```zig
//! pub const log_level: std.log.Level = .warn;
//! ```
//!
//! ## Panic
//!
//! `@panic("literal message")`: use for unreachable invariant violations.
//! `std.debug.panic("fmt {}", .{args})`: use when formatting is needed.
//! Both route through `pub const panic` below, which writes to stderr and exits.
//!
//! ## I/O
//!
//! * `innigkeit.io.stdout` / `.stderr`: direct write syscall wrappers.
//! * `.stdWriter()`: on either returns a `std.Io.Writer` for stdlib APIs.
//! * `innigkeit.stdio.io()`: a full synchronous `std.Io` backend (eager async,
//!   futexes, monotonic clock, sleep, standard-stream file I/O) for std APIs
//!   that take an `Io` parameter; see library/innigkeit/stdio.zig.
//! * `std.fs`: is not supported for `.os = .other`; use initfs for read-only
//!   init-time files and future VFS capability for general file I/O.
const std = @import("std");
const innigkeit = @import("innigkeit");

pub const debug_io = @import("debug_io.zig").debug_io;

const root = @import("root");
const default_log_level: std.log.Level = .debug;
const effective_log_level: std.log.Level =
    if (@hasDecl(root, "log_level"))
        root.log_level
    else
        default_log_level;

/// `std.Options` for Innigkeit userspace apps.
///
/// Routes `std.log.*` to stderr via the write syscall. Disables networking
/// and other features that require OS support not yet implemented.
pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = effective_log_level,
    .networking = false,
    // TODO: make sure this is correct
    .page_size_max = 4096,
    .page_size_min = 4096,
};

/// Panic handler for Innigkeit userspace apps.
///
/// Writes "PANIC: <msg>\n" to stderr, then calls exit_process(1).
/// Exported as `pub const panic` so that both @panic("literal") and
/// std.debug.panic("fmt", .{args}) route here.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    innigkeit.io.stderr.writeAll("PANIC: ") catch {};
    innigkeit.io.stderr.writeAll(msg) catch {};
    innigkeit.io.stderr.writeAll("\n") catch {};
    _ = innigkeit.Syscall.invoke(.exit_process, .{1});
    unreachable;
}

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = comptime level.asText() ++
        (if (scope == .default) ": " else " (" ++ @tagName(scope) ++ "): ");
    var buf: [4096]u8 = undefined;
    // bufPrint fails only on truncation; write whatever fit in the buffer.
    const msg = std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", args) catch blk: {
        buf[buf.len - 1] = '\n';
        break :blk &buf;
    };
    innigkeit.io.stderr.writeAll(msg) catch {};
}
