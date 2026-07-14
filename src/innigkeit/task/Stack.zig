const Stack = @This();

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

/// The entire virtual range including the guard page.
range: innigkeit.KernelVirtualRange,

/// The usable range excluding the guard page.
usable_range: innigkeit.KernelVirtualRange,

/// The current stack pointer.
stack_pointer: innigkeit.KernelVirtualAddress,

/// The top of the stack.
///
/// This is not the same as `usable_range.after()` as a zero return address is pushed onto the top of the stack.
top_stack_pointer: innigkeit.KernelVirtualAddress,

/// Creates a stack from a range.
///
/// Requirements:
/// - `usable_range` must be atleast `@sizeOf(usize)` bytes.
/// - `range` and `usable_range` must be aligned to 16 bytes.
/// - `range` must fully contain `usable_range`.
pub fn fromRange(range: innigkeit.KernelVirtualRange, usable_range: innigkeit.KernelVirtualRange) Stack {
    if (core.is_debug) {
        std.debug.assert(usable_range.size.greaterThanOrEqual(core.Size.of(usize)));
        std.debug.assert(range.fullyContains(usable_range));

        std.debug.assert(range.address.aligned(.@"16"));
        std.debug.assert(usable_range.address.aligned(.@"16"));
    }

    var stack: Stack = .{
        .range = range,
        .usable_range = usable_range,
        .stack_pointer = usable_range.after(),
        .top_stack_pointer = undefined, // set by `reset`
    };

    stack.reset();

    return stack;
}

/// Pushes a value onto the stack.
pub fn push(self: *Stack, value: usize) error{StackOverflow}!void {
    const new_stack_pointer: innigkeit.KernelVirtualAddress = self.stack_pointer.moveBackward(.of(usize));
    if (new_stack_pointer.lessThan(self.usable_range.address)) return error.StackOverflow;

    const ptr: *usize = new_stack_pointer.toPtr(*usize);
    ptr.* = value;

    self.stack_pointer = new_stack_pointer;
}

/// Returns true if there is space for `number` of `usize` values on the stack.
pub fn spaceFor(self: *const Stack, number: usize) bool {
    const size = core.Size.of(usize).multiplyScalar(number);
    const new_stack_pointer: innigkeit.KernelVirtualAddress = self.stack_pointer.moveBackward(size);
    if (new_stack_pointer.lessThan(self.usable_range.address)) return false;
    return true;
}

pub fn reset(self: *Stack) void {
    self.stack_pointer = self.usable_range.after();

    // push a zero return address
    self.push(0) catch unreachable; // TODO: is this correct for non-x64?

    self.top_stack_pointer = self.stack_pointer;
}

/// Create a kernel task stack sized by `innigkeit.config.task.kernel_stack_size`.
pub fn createStack() !Stack {
    return createStackWithSize(innigkeit.config.task.kernel_stack_size);
}

/// Create an IST stack (double-fault / NMI) sized by `innigkeit.config.task.interrupt_stack_size`.
pub fn createInterruptStack() !Stack {
    return createStackWithSize(innigkeit.config.task.interrupt_stack_size);
}

fn createStackWithSize(usable_size: core.Size) !Stack {
    const size_with_guard = usable_size.add(architecture.paging.standard_page_size);

    const stack_range = globals.stack_arena.allocate(
        size_with_guard.value,
        .instant_fit,
    ) catch return error.ItemConstructionFailed;
    errdefer globals.stack_arena.deallocate(stack_range);

    const range = stack_range.toVirtualRange();
    // The guard page sits at range.address (unmapped, no physical backing).
    // The usable stack begins one page above it and grows downward from the top.
    // A stack overflow past usable_range.address hits the unmapped guard page
    // and faults immediately rather than silently corrupting adjacent memory.
    const usable_range: innigkeit.KernelVirtualRange = .{
        .address = range.address.moveForward(architecture.paging.standard_page_size),
        .size = usable_size,
    };

    {
        globals.stack_page_table_mutex.lock();
        defer globals.stack_page_table_mutex.unlock();

        innigkeit.memory.mapRangeAndBackWithPhysicalPages(
            innigkeit.memory.kernelPageTable(),
            usable_range.toVirtualRange(),
            .{ .type = .kernel, .protection = .{ .read = true, .write = true } },
            .kernel,
            .keep,
            innigkeit.memory.PhysicalPage.allocator,
        ) catch return error.ItemConstructionFailed;
    }

    return .fromRange(range, usable_range);
}

pub fn destroyStack(self: Stack) void {
    {
        globals.stack_page_table_mutex.lock();
        defer globals.stack_page_table_mutex.unlock();

        var unmap_batch: innigkeit.memory.VirtualRangeBatch = .{};
        unmap_batch.appendMergeIfFull(self.usable_range.toVirtualRange());

        innigkeit.memory.unmap(
            innigkeit.memory.kernelPageTable(),
            &unmap_batch,
            .kernel,
            .free,
            .keep,
            innigkeit.memory.PhysicalPage.allocator,
        );
    }

    globals.stack_arena.deallocate(.fromVirtualRange(self.range));
}

const globals = struct {
    var stack_arena: innigkeit.memory.arena.Arena(.none) = undefined;
    var stack_page_table_mutex: innigkeit.sync.Mutex = .{};
};

pub const init = struct {
    const init_log = innigkeit.debug.log.scoped(.task_init);

    pub fn initializeStacks() !void {
        init_log.debug("initializing task stacks", .{});
        try globals.stack_arena.init(
            .{
                .name = try .fromSlice("stacks"),
                .quantum = architecture.paging.standard_page_size.value,
            },
        );

        const stacks_range = innigkeit.memory.kernelRegions().find(.kernel_stacks).?.range;

        globals.stack_arena.addSpan(
            stacks_range.address.value,
            stacks_range.size.value,
        ) catch |err| {
            std.debug.panic("failed to add stack range to `stack_arena`: {t}!", .{err});
        };
    }
};

// Tests
test "stack: guard page occupies the bottom of the virtual range" {
    // Verify that the usable stack starts exactly one page above range.address.
    // The page at range.address is intentionally left unmapped so that a
    // downward stack overflow produces a page fault instead of silent corruption.
    const page_size = architecture.paging.standard_page_size;
    const stack = try createStack();
    defer destroyStack(stack);

    try std.testing.expectEqual(
        stack.range.address.moveForward(page_size),
        stack.usable_range.address,
    );
    // The usable region ends flush with the top of the full allocation.
    try std.testing.expectEqual(
        stack.range.after(),
        stack.usable_range.after(),
    );
    // The usable region is strictly smaller than the full range (guard page gap).
    try std.testing.expect(
        stack.usable_range.size.lessThan(stack.range.size),
    );
}

test "stack: initial stack pointer is inside the usable range" {
    const stack = try createStack();
    defer destroyStack(stack);

    // After reset(), top_stack_pointer must be within [usable_range.address, usable_range.after()).
    try std.testing.expect(
        !stack.top_stack_pointer.lessThan(stack.usable_range.address),
    );
    try std.testing.expect(
        stack.top_stack_pointer.lessThan(stack.usable_range.after()),
    );
}
