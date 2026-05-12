//! Represents a userspace thread.
const Thread = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const log = innigkeit.debug.log.scoped(.user);

task: innigkeit.Task,

process: *innigkeit.user.Process,

arch_specific: architecture.user.PerThread,

pub inline fn from(task: *innigkeit.Task) *Thread {
    if (core.is_debug) std.debug.assert(task.type == .user);
    return @fieldParentPtr("task", task);
}

pub inline fn fromConst(task: *const innigkeit.Task) *const Thread {
    if (core.is_debug) std.debug.assert(task.type == .user);
    return @fieldParentPtr("task", task);
}

/// Enter userspace for the first time.
///
/// Asserts that the current task is the same as the thread's task.
pub fn start(self: *Thread, entry_point: innigkeit.UserVirtualAddress) !noreturn {
    if (core.is_debug) {
        const current_task: innigkeit.Task.Current = .get();
        std.debug.assert(current_task.task == &self.task);
    }

    const user_stack = try self.process.address_space.map(.{
        .size = .from(64, .kib),
        .protection = .{ .read = true, .write = true },
        .type = .zero_fill,
    });

    log.debug("starting userspace thread: {f}", .{self});

    architecture.user.enterUserspace(.{
        .entry_point = entry_point,
        .stack_pointer = user_stack.toUser().after(),
    });
}

pub fn format(self: *const Thread, writer: *std.Io.Writer) !void {
    // TODO: these are user controlled strings

    try writer.print(
        "U<{s} - {s}>",
        .{ self.process.name.constSlice(), self.task.name.constSlice() },
    );
}

pub const internal = struct {
    pub fn create(
        process: *innigkeit.user.Process,
        options: innigkeit.Task.internal.InitOptions,
    ) !*Thread {
        const thread = try globals.cache.allocate();
        errdefer globals.cache.deallocate(thread);

        thread.* = .{
            .task = thread.task, // reinitialized below
            .process = process,
            .arch_specific = thread.arch_specific, // reinitialized below
        };

        try innigkeit.Task.internal.init(&thread.task, options);
        architecture.user.initializeThread(thread);

        return thread;
    }

    pub fn destroy(thread: *Thread) void {
        if (core.is_debug) {
            const task = &thread.task;
            std.debug.assert(task.type == .user);
            std.debug.assert(task.state == .terminated);
            std.debug.assert(task.reference_count.load(.monotonic) == 0);
        }
        globals.cache.deallocate(thread);
    }
};

const globals = struct {
    /// The source of thread objects.
    ///
    /// Initialized during `init.initializeThreads`.
    var cache: innigkeit.mem.cache.Cache(
        Thread,
        .{
            .constructor = struct {
                fn constructor(thread: *Thread) innigkeit.mem.cache.ConstructorError!void {
                    if (core.is_debug) thread.* = undefined;
                    thread.task.stack = try .createStack();
                    errdefer thread.task.stack.destroyStack();
                    try architecture.user.createThread(thread);
                }
            }.constructor,
            .destructor = struct {
                fn destructor(thread: *Thread) void {
                    architecture.user.destroyThread(thread);
                    thread.task.stack.destroyStack();
                }
            }.destructor,
        },
    ) = undefined;
};

pub const init = struct {
    const init_log = innigkeit.debug.log.scoped(.user_init);

    pub fn initializeThreads() !void {
        init_log.debug("initializing thread cache", .{});
        globals.cache.init(
            .{ .name = try .fromSlice("thread") },
        );
    }
};
