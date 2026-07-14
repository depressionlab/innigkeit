const Executor = @This();

const std = @import("std");

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");

/// Unique identifier per executor.
///
/// As no executor hotswapping is supported this is guaranteed to be the index of this executor in `globals.executors`.
id: Id,

_current_task: *innigkeit.Task,

scheduler: innigkeit.Task.Scheduler,

arch_specific: architecture.PerExecutor,

/// List of `innigkeit.memory.FlushRequest` objects that need to be actioned.
flush_requests: core.containers.AtomicSinglyLinkedList = .{},

/// Intel Hybrid core classification detected at executor initialization.
/// Always `.unknown` on non-hybrid processors.
core_type: CoreType = .unknown,

// used during `innigkeit.debug.interruptSourcePanic`
interrupt_source_panic_buffer: [
    innigkeit.config.executor.interrupt_source_panic_buffer_size.value + interrupt_source_panic_truncated.len
]u8 = undefined,
const interrupt_source_panic_truncated = " (msg truncated)";

/// Arch-agnostic P/E core classification for Intel Hybrid platforms.
pub const CoreType = enum {
    unknown,
    /// Intel Golden Cove and later: high-performance core.
    p_core,
    /// Intel Gracemont and later: efficiency core.
    e_core,
};

pub fn setCurrentTask(self: *Executor, task: *innigkeit.Task) void {
    self._current_task = task;
    architecture.scheduling.setCurrentTask(task);
}

/// Renders the given message using this executor's interrupt source panic buffer.
///
/// If the message is too large to fit in the buffer, the message is truncated.
pub fn renderInterruptSourcePanicMessage(self: *Executor, comptime fmt: []const u8, args: anytype) []const u8 {
    // TODO: this treatment should be given to all panics, maybe we generalize this buffer with truncation message

    const full_buffer = self.interrupt_source_panic_buffer[0..];

    var bw: std.Io.Writer = .fixed(full_buffer[0..innigkeit.config.executor.interrupt_source_panic_buffer_size.value]);

    bw.print(fmt, args) catch {
        @memcpy(
            full_buffer[innigkeit.config.executor.interrupt_source_panic_buffer_size.value..],
            interrupt_source_panic_truncated,
        );
        return full_buffer;
    };

    return bw.buffered();
}

pub fn executors() []Executor {
    return globals.executors;
}

pub inline fn format(self: *const Executor, writer: *std.Io.Writer) !void {
    return self.id.format(writer);
}

pub const Id = enum(u32) {
    _,

    pub const bootstrap: Id = @enumFromInt(0);

    pub inline fn format(self: Id, writer: *std.Io.Writer) !void {
        try writer.print("Executor({d})", .{@intFromEnum(self)});
    }
};

const globals = struct {
    var executors: []Executor = &.{};
};

pub const init = struct {
    pub fn setExecutors(executor_slice: []Executor) void {
        globals.executors = executor_slice;
    }
};
