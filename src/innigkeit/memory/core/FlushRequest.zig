const std = @import("std");

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");

const FlushRequest = @This();

batch: *const innigkeit.memory.VirtualRangeBatch,
flush_target: innigkeit.Context,
count: std.atomic.Value(usize) = .init(1), // starts at `1` to account for the current executor
nodes: core.containers.BoundedArray(Node, innigkeit.config.executor.maximum_number_of_executors) = .{},

pub const Node = struct {
    request: *FlushRequest,
    node: std.SinglyLinkedList.Node,
};

pub fn submitAndWait(self: *FlushRequest) void {
    const current_task: innigkeit.Task.Current = .get();

    {
        current_task.incrementMigrationDisable();
        defer current_task.decrementMigrationDisable();

        const current_executor = current_task.knownExecutor();

        // TODO: all except self IPI
        // TODO: is there a better way to determine which executors to target?
        for (innigkeit.Executor.executors()) |*executor| {
            if (executor == current_executor) continue; // skip ourselves
            self.requestExecutor(executor);
        }

        self.flush();
    }

    if (current_task.task.interrupt_disable_count.load(.acquire) == 0) {
        // interrupts are enabled so flush requests from other cores will be serviced
        while (self.count.load(.acquire) != 0) {
            architecture.spinLoopHint();
        }
    } else {
        // interrupts are disabled so service flush requests here
        while (self.count.load(.acquire) != 0) {
            processFlushRequests();
        }
    }
}

pub fn processFlushRequests() void {
    const current_task: innigkeit.Task.Current = .get();
    const executor = current_task.knownExecutor();

    while (executor.flush_requests.popFirst()) |node| {
        const request_node: *const innigkeit.memory.FlushRequest.Node = @fieldParentPtr("node", node);
        request_node.request.flush();
    }
}

fn flush(self: *FlushRequest) void {
    const current_task: innigkeit.Task.Current = .get();
    // .release so the requester's `.acquire` load observing count == 0 is
    // guaranteed to happen-after the cache flush below, not just after the
    // counter decrement (a plain .monotonic pair gives no such ordering).
    defer _ = self.count.fetchSub(1, .release);

    switch (self.flush_target) {
        .kernel => {},
        .user => |target_process| switch (current_task.task.type) {
            .kernel => return,
            .user => {
                const current_process: *innigkeit.user.Process = .from(current_task.task);
                if (current_process != target_process) return;
            },
        },
    }

    for (self.batch.ranges.constSlice()) |range| {
        architecture.paging.flushCache(range);
    }
}

fn requestExecutor(self: *FlushRequest, executor: *innigkeit.Executor) void {
    _ = self.count.fetchAdd(1, .monotonic);

    const node = self.nodes.addOne() catch
        @panic("exceeded maximum number of executors!");
    node.* = .{
        .request = self,
        .node = .{},
    };
    executor.flush_requests.prepend(&node.node);

    architecture.interrupts.sendFlushIPI(executor);
}
