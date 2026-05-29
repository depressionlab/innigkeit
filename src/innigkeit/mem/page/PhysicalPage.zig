const PhysicalPage = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const List = @import("List.zig");
pub const init = @import("init.zig");
pub const Index = @import("Index.zig").Index;
pub const BuddyAllocator = @import("BuddyAllocator.zig");
const globals = @import("globals.zig");

/// Intrusive singly-linked list node (forward link).
/// Used by both List.Atomic (legacy) and BuddyAllocator free lists.
node: List.Node = .{},

/// Backward link for BuddyAllocator's doubly-linked free lists.
/// Not used by List.Atomic.
prev_node: Index = .none,

/// When this page is the start of a free block: the buddy order of the block.
free_order: u4 = 0,

_pad: u4 = 0,

/// Set when this page is the head of a block on a BuddyAllocator free list.
is_free: bool = false,

pub inline fn fromIndex(index: Index) *PhysicalPage {
    if (core.is_debug) std.debug.assert(index != .none);
    return &globals.pages[@intFromEnum(index)];
}

pub const allocator: Allocator = .{
    .allocate = allocate,
    .deallocate = deallocate,
};

pub const Allocator = struct {
    allocate: Allocate,
    deallocate: Deallocate,

    pub const AllocateError = error{PagesExhausted};

    pub const Allocate = *const fn () AllocateError!Index;
    pub const Deallocate = *const fn (list: List) void;
};

/// Allocate a single physical page (order 0).
fn allocate() Allocator.AllocateError!Index {
    const index = try globals.buddy.alloc(0);

    const prev_free = globals.free_memory.fetchSub(
        architecture.paging.standard_page_size.value,
        .release,
    );
    const remaining = prev_free -| architecture.paging.standard_page_size.value;

    // Memory pressure notification. The hook sees accurate free-page count.
    // The hook must not allocate pages or block.
    const threshold = globals.pressure_threshold_pages;
    if (threshold > 0 and globals.pressure_hook != null) {
        const free_pages = remaining / architecture.paging.standard_page_size.value;
        if (free_pages < threshold) {
            const total_pages = globals.total_memory.value / architecture.paging.standard_page_size.value;
            globals.pressure_hook.?(free_pages, total_pages);
        }
    }

    if (core.is_debug) {
        // In debug builds, fill with 0xAA to detect uninitialized use.
        // (BuddyAllocator.alloc already zeroes in release, but in debug
        // we want to catch reads before writes.)
        const virtual_range: innigkeit.KernelVirtualRange = .from(
            index.baseAddress().toDirectMap(),
            architecture.paging.standard_page_size,
        );

        @memset(virtual_range.byteSlice(), undefined);
    }

    return index;
}

/// Deallocate a list of individual physical pages (all at order 0).
fn deallocate(list: List) void {
    if (list.count == 0) {
        @branchHint(.unlikely);
        return;
    }

    _ = globals.free_memory.fetchAdd(
        architecture.paging.standard_page_size.multiplyScalar(list.count).value,
        .release,
    );

    // Return each page individually at order 0.
    var it = list.first_index;
    while (it != .none) {
        const page = fromIndex(it);
        const next = page.node.next;
        page.node.next = .none;
        page.prev_node = .none;
        globals.buddy.free(it, 0);
        it = next;
    }
}

/// Allocate 2^order contiguous physical pages (order 0..BuddyAllocator.max_order).
pub fn allocateContiguous(order: u4) Allocator.AllocateError!Index {
    const index = try globals.buddy.alloc(order);
    const page_count: u32 = @as(u32, 1) << order;
    _ = globals.free_memory.fetchSub(
        architecture.paging.standard_page_size.multiplyScalar(page_count).value,
        .release,
    );
    return index;
}

/// Free 2^order contiguous pages starting at `index`.
pub fn freeContiguous(index: Index, order: u4) void {
    const page_count: u32 = @as(u32, 1) << order;
    _ = globals.free_memory.fetchAdd(
        architecture.paging.standard_page_size.multiplyScalar(page_count).value,
        .release,
    );
    globals.buddy.free(index, order);
}
