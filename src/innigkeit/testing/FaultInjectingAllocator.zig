//! A `PhysicalPage.Allocator` wrapper that fails deterministically after a
//! fixed number of successful allocations, for exercising the kernel's own
//! OOM-unwind (`errdefer`) paths rather than only their success paths.
//!
//! Mirrors Linux's `CONFIG_FAULT_INJECTION` at a much smaller scope, using
//! a build-time-injectable failure seam composed with the real allocator,
//! not a new allocation strategy.
//!
//! `PhysicalPage.Allocator`'s `allocate`/`deallocate` are bare
//! `*const fn` pointers with no context parameter, so per-instance state
//! isn't representable. This wrapper uses file-level `var`s instead.
const FaultInjectingAllocator = @This();

const innigkeit = @import("innigkeit");

const PhysicalPage = innigkeit.memory.PhysicalPage;

var successes_remaining: usize = 0;

/// Net pages currently outstanding through this specific allocator
/// instance. Incremented on every forwarded `allocate()` success,
/// decremented by however many pages a `deallocate()` call returns.
var outstanding: usize = 0;

/// Allow `budget` more `allocate()` calls to succeed (forwarded to the real
/// allocator); the next one after that returns `error.PagesExhausted`
/// without touching the real allocator at all. Also resets `outstanding`
/// to 0.
pub fn reset(budget: usize) void {
    successes_remaining = budget;
    outstanding = 0;
}

/// Net pages currently allocated-and-not-yet-deallocated through this
/// allocator since the last `reset`.
pub fn outstandingCount() usize {
    return outstanding;
}

pub const allocator: PhysicalPage.Allocator = .{
    .allocate = allocate,
    .deallocate = deallocate,
};

fn allocate() PhysicalPage.Allocator.AllocateError!PhysicalPage.Index {
    if (successes_remaining == 0) {
        @branchHint(.cold);
        return error.PagesExhausted;
    }
    successes_remaining -= 1;
    const index = try PhysicalPage.allocator.allocate();
    outstanding += 1;
    return index;
}

fn deallocate(list: PhysicalPage.List) void {
    outstanding -= list.count;
    PhysicalPage.allocator.deallocate(list);
}
