const std = @import("std");

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");

pub const log = @import("log.zig");
pub const PanicType = @import("PanicType.zig").PanicType;
pub const PanicMode = @import("PanicMode.zig").PanicMode;
pub const std_debug_exports = @import("std_debug_exports.zig");
pub const panic_interface = std.debug.FullPanic(zigPanic);

pub fn hasAnExecutorPanicked() bool {
    return globals.panicking_executor.load(.acquire) != null;
}

pub fn interruptSourcePanic(
    interrupt_frame: architecture.interrupts.InterruptFrame,
    comptime format: []const u8,
    args: anytype,
) noreturn {
    @branchHint(.cold);

    const current_task: innigkeit.Task.Current = .get();

    current_task.incrementInterruptDisable(); // ensure the executor is not going to change underneath us
    const executor = current_task.knownExecutor();

    panicDispatch(
        executor.renderInterruptSourcePanicMessage(format, args),
        .{ .interrupt = interrupt_frame },
    );
}

fn panicDispatch(
    msg: []const u8,
    panic_type: PanicType,
) noreturn {
    @branchHint(.cold);

    const static = struct {
        var nested_panic_count: usize = 0;
    };

    architecture.interrupts.disable();

    no_op_panic: {
        switch (globals.panic_mode) {
            .no_op => break :no_op_panic,
            .single_executor_init_panic => innigkeit.init.Output.lock.poison(),
            .init_panic => {
                const current_task: innigkeit.Task.Current = .panicked();
                const executor = current_task.knownExecutor();

                if (globals.panicking_executor.cmpxchgStrong(
                    null,
                    executor,
                    .acq_rel,
                    .acquire,
                )) |panicking_executor| {
                    if (panicking_executor != executor) break :no_op_panic; // another executor is panicking
                }

                innigkeit.init.Output.lock.poison();

                architecture.interrupts.sendPanicIPI();
            },
        }

        const nested_panic_count = static.nested_panic_count;
        static.nested_panic_count += 1;

        printPanic(innigkeit.init.Output.terminal, msg, panic_type, nested_panic_count) catch {};
    }

    architecture.interrupts.disableAndHalt();
}

fn printPanic(
    t: std.Io.Terminal,
    msg: []const u8,
    panic_type: PanicType,
    nested_panic_count: usize,
) !void {
    switch (nested_panic_count) {
        // on first panic attempt to print the panic message and backtrace
        0 => {
            try t.setColor(.red);
            try t.writer.writeAll("\nPANIC");
            try t.setColor(.reset);

            try printPanicMessage(t.writer, msg);
            try printPanicBacktrace(t, panic_type);
        },
        // on first panic in panic print only the panic message
        1 => {
            try t.setColor(.red);
            try t.writer.writeAll("\nPANIC IN PANIC");
            try t.setColor(.reset);

            try printPanicMessage(t.writer, msg);
        },
        // on second panic in panic dont even try to print the panic message
        2 => {
            try t.setColor(.red);
            try t.writer.writeAll("\nPANIC IN PANIC");
            try t.setColor(.reset);
        },
        // don't trigger any more panics
        else => return,
    }

    try t.writer.flush();
}

fn printPanicMessage(
    writer: *std.Io.Writer,
    msg: []const u8,
) !void {
    if (msg.len != 0) {
        try writer.writeAll(" - ");

        try writer.writeAll(msg);

        if (msg[msg.len - 1] != '\n') {
            try writer.writeByte('\n');
        }
    } else {
        try writer.writeByte('\n');
    }
}

fn printPanicBacktrace(
    t: std.Io.Terminal,
    panic_type: PanicType,
) !void {
    switch (panic_type) {
        .normal => |normal| {
            if (normal.error_return_trace) |trace| if (trace.index != 0) {
                try t.writer.writeAll("error return context:\n");
                try std.debug.writeErrorReturnTrace(trace, t);
                try t.writer.writeAll("\nstack trace:\n");
            };
            try std.debug.writeCurrentStackTrace(.{ .first_address = normal.return_address }, t);
        },
        .interrupt => |interrupt| {
            var context: std.debug.cpu_context.Native = undefined;
            interrupt.fillContext(&context);
            try std.debug.writeCurrentStackTrace(.{ .context = &context }, t);
        },
    }
}

pub fn setPanicMode(mode: PanicMode) void {
    if (@intFromEnum(globals.panic_mode) + 1 != @intFromEnum(mode)) {
        std.debug.panic(
            "invalid panic mode transition '{t}' -> '{t}'!",
            .{ globals.panic_mode, mode },
        );
    }

    globals.panic_mode = mode;
}

/// Entry point from the Zig language upon a panic.
fn zigPanic(
    msg: []const u8,
    return_address_opt: ?usize,
) noreturn {
    @branchHint(.cold);
    panicDispatch(
        msg,
        .{ .normal = .{
            .return_address = return_address_opt orelse @returnAddress(),
            .error_return_trace = @errorReturnTrace(),
        } },
    );
}

const globals = struct {
    /// The executor that is currently panicking.
    ///
    /// Checked by executors to confirm receiving a panic IPI.
    var panicking_executor: std.atomic.Value(?*const innigkeit.Executor) = .init(null);

    var panic_mode: PanicMode = .no_op;
};
