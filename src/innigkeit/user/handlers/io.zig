//! The multiplexed `write` and `read` syscalls.
//!
//! Both resolve the fd in the per-process table and dispatch on the descriptor
//! kind: terminal_out / keyboard_in stream through a bounded kernel bounce
//! buffer here; the `.file` case delegates to handlers/file.zig (same register
//! layout: fd=arg.one, buf=arg.two, len=arg.three). User buffers are validated
//! up front and copied with the fault-safe helpers so a bad/unmapped page yields
//! BadAddress instead of panicking, and no UserAccess window is held across a
//! device or VFS call.

const std = @import("std");
const innigkeit = @import("innigkeit");
const log = innigkeit.debug.log.scoped(.user_io);

const file = @import("file.zig");
const validate = @import("../validate.zig");
const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");

/// write(fd, buf, len) -> bytes_written | error
pub fn write(context: Context) Error.Syscall!usize {
    const fd = context.arg(.one);
    const buf_ptr = context.arg(.two);
    const buf_len = context.arg(.three);

    const resolved = context.process().fd_table.resolve(fd) orelse
        return Error.Syscall.BadHandle;

    if (buf_len == 0) return 0;

    switch (resolved.desc) {
        .terminal_out => {
            if (!validate.validateUserBuffer(buf_ptr, buf_len))
                return Error.Syscall.BadAddress;

            const output = innigkeit.init.Output.terminal;
            var chunk_buffer: [256]u8 = undefined;
            var offset: usize = 0;
            while (offset < buf_len) {
                const chunk_len = @min(buf_len - offset, chunk_buffer.len);
                validate.copyFromUser(
                    chunk_buffer[0..chunk_len],
                    buf_ptr + offset,
                ) catch return Error.Syscall.BadAddress;
                output.writer.writeAll(chunk_buffer[0..chunk_len]) catch |err| {
                    log.err("write: {t}", .{err});
                    return Error.Syscall.IoError;
                };
                offset += chunk_len;
            }
            output.writer.flush() catch |err| {
                log.err("write flush: {t}", .{err});
                return Error.Syscall.IoError;
            };
            return @intCast(buf_len);
        },
        .file => return file.writeFile(context),
        // keyboard_in is not writable; .closed never escapes resolve.
        else => return Error.Syscall.BadHandle,
    }
}

/// read(fd, buf, len) -> bytes_read | error
pub fn read(context: Context) Error.Syscall!usize {
    const fd = context.arg(.one);
    const buf_ptr = context.arg(.two);
    const buf_len = context.arg(.three);

    const resolved = context.process().fd_table
        .resolve(fd) orelse return Error.Syscall.BadHandle;

    if (buf_len == 0) return 0;

    switch (resolved.desc) {
        .keyboard_in => {
            if (!validate.validateUserBuffer(buf_ptr, buf_len))
                return Error.Syscall.BadAddress;

            var line_buffer: [256]u8 = undefined;
            const capacity = @min(buf_len, line_buffer.len);
            const bytes_read = innigkeit.drivers.input.ps2.keyboard_buffer.readLine(line_buffer[0..capacity]);

            validate.copyToUser(
                buf_ptr,
                line_buffer[0..bytes_read],
            ) catch return Error.Syscall.BadAddress;
            return @intCast(bytes_read);
        },
        .file => return file.readFile(context),
        // terminal_out is not readable; .closed never escapes resolve.
        else => return Error.Syscall.BadHandle,
    }
}
