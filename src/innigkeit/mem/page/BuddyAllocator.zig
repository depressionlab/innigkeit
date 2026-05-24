//! Binary buddy allocator for physical pages.
//!
//! Supports allocating 2^order contiguous pages (order 0..MAX_ORDER).
//! All allocations are zeroed before returning (prevents cross-process info leaks).
//! All frees are zeroed before returning to the free list.
//!
//! Thread safety: protected by an internal TicketSpinLock; all public
//! methods are safe to call from any CPU.
//!
//! Coalescing: on free, the buddy block (at the same order) is checked; if
//! it is also free its block is removed from the free list and the merged
//! block is freed at the next order. This recurses up to MAX_ORDER.
//!
//! Splitting: on alloc, if the exact order is empty, a larger block is split
//! downward until the requested order is available.
const BuddyAllocator = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const PhysicalPage = innigkeit.mem.PhysicalPage;
const Index = PhysicalPage.Index;
const sync = innigkeit.sync;

pub const max_order: u4 = 10;
const num_orders: usize = max_order + 1;

/// Per-order free lists (doubly-linked via PhysicalPage.prev_node + node.next).
/// Protected by `lock`.
free_lists: [num_orders]FreeList = [_]FreeList{.{}} ** num_orders,

/// Count of free pages per order (in blocks, not pages).
nr_free: [num_orders]u32 = [_]u32{0} ** num_orders,

/// Protects all mutations of free_lists and nr_free.
lock: sync.TicketSpinLock = .{},

/// Allocate 2^order contiguous physical pages.
/// Returns the index of the first page (naturally aligned to 2^order pages).
pub fn alloc(self: *BuddyAllocator, order: u4) error{PagesExhausted}!Index {
    self.lock.lock();
    defer self.lock.unlock();
    return self.allocLocked(order);
}

fn allocLocked(self: *BuddyAllocator, order: u4) error{PagesExhausted}!Index {
    // Find smallest available order >= requested.
    var avail: u4 = order;
    while (avail <= max_order and self.free_lists[avail].first == .none) : (avail += 1) {}
    if (avail > max_order) return error.PagesExhausted;

    // Pop from avail order.
    const block = self.free_lists[avail].popFirst().?;
    self.nr_free[avail] -= 1;
    const page = PhysicalPage.fromIndex(block);
    page.is_free = false;

    // Split down to the requested order, pushing upper halves back.
    var cur_order: u4 = avail;
    while (cur_order > order) {
        cur_order -= 1;
        const pages_per_block: u32 = @as(u32, 1) << cur_order;
        const upper_idx: u32 = @intFromEnum(block) + pages_per_block;
        const upper: Index = @enumFromInt(upper_idx);
        const upper_page = PhysicalPage.fromIndex(upper);
        upper_page.is_free = true;
        upper_page.free_order = cur_order;
        self.free_lists[cur_order].prepend(upper);
        self.nr_free[cur_order] += 1;
    }

    // Zero the block before handing it out (security + correctness).
    zeroBlock(block, order);

    return block;
}

/// Free 2^order contiguous pages starting at `index`.
/// `index` must be aligned to 2^order pages.
pub fn free(self: *BuddyAllocator, index: Index, order: u4) void {
    self.lock.lock();
    defer self.lock.unlock();
    self.freeLocked(index, order);
}

fn freeLocked(self: *BuddyAllocator, index: Index, order: u4) void {
    // Double-free detection: the page must not be already on a free list.
    if (core.is_debug) {
        const page = PhysicalPage.fromIndex(index);
        if (page.is_free) std.debug.panic(
            "BuddyAllocator: double-free of page index {} at order {}",
            .{ @intFromEnum(index), order },
        );
    }

    // Zero before returning to the free list (security).
    zeroBlock(index, order);

    var cur_order: u4 = order;
    var cur_idx: u32 = @intFromEnum(index);

    // Coalesce with buddy upward.
    while (cur_order < max_order) {
        const buddy_idx: u32 = cur_idx ^ (@as(u32, 1) << cur_order);
        const buddy: Index = @enumFromInt(buddy_idx);
        const buddy_page = PhysicalPage.fromIndex(buddy);

        if (!buddy_page.is_free or buddy_page.free_order != cur_order) break;

        // Remove buddy from the free list.
        self.free_lists[cur_order].remove(buddy);
        self.nr_free[cur_order] -= 1;
        buddy_page.is_free = false;

        // Merge: the combined block starts at the lower page index.
        cur_idx = @min(cur_idx, buddy_idx);
        cur_order += 1;
    }

    // Insert merged block at cur_order.
    const merged: Index = @enumFromInt(cur_idx);
    PhysicalPage.fromIndex(merged).is_free = true;
    PhysicalPage.fromIndex(merged).free_order = cur_order;
    self.free_lists[cur_order].prepend(merged);
    self.nr_free[cur_order] += 1;
}

/// Add a naturally-aligned block to the allocator during initialization.
/// `index` must be aligned to 2^order pages; called with lock NOT held
/// (single-threaded init phase).
pub fn addBlock(self: *BuddyAllocator, index: Index, order: u4) void {
    const page = PhysicalPage.fromIndex(index);
    page.is_free = true;
    page.free_order = order;
    self.free_lists[order].prepend(index);
    self.nr_free[order] += 1;
}

/// Total number of free pages tracked by this allocator.
pub fn totalFreePages(self: *const BuddyAllocator) u64 {
    var total: u64 = 0;
    for (0..num_orders) |o| {
        total += @as(u64, self.nr_free[o]) << @intCast(o);
    }
    return total;
}

fn zeroBlock(index: Index, order: u4) void {
    const page_size = architecture.paging.standard_page_size.value;
    const size: usize = page_size << order;
    const base = index.baseAddress().toDirectMap();
    @memset(@as([*]u8, @ptrFromInt(base.value))[0..size], 0);
}

/// A doubly-linked free list backed by PhysicalPage.node.next and prev_node.
/// All operations are O(1) (prepend, popFirst, remove by index).
const FreeList = struct {
    first: Index = .none,

    fn prepend(self: *FreeList, index: Index) void {
        const page = PhysicalPage.fromIndex(index);
        page.node.next = self.first;
        page.prev_node = .none;
        if (self.first != .none) PhysicalPage.fromIndex(self.first).prev_node = index;
        self.first = index;
    }

    fn popFirst(self: *FreeList) ?Index {
        const idx = self.first;
        if (idx == .none) return null;
        const page = PhysicalPage.fromIndex(idx);
        self.first = page.node.next;
        if (self.first != .none) PhysicalPage.fromIndex(self.first).prev_node = .none;
        page.node.next = .none;
        page.prev_node = .none;
        return idx;
    }

    fn remove(self: *FreeList, index: Index) void {
        const page = PhysicalPage.fromIndex(index);
        const prev = page.prev_node;
        const next = page.node.next;
        if (prev != .none) {
            PhysicalPage.fromIndex(prev).node.next = next;
        } else {
            self.first = next;
        }
        if (next != .none) PhysicalPage.fromIndex(next).prev_node = prev;
        page.node.next = .none;
        page.prev_node = .none;
    }
};

// Tests

const page_globals = @import("globals.zig");

test "buddy: alloc returns zeroed pages" {
    const page = try page_globals.buddy.alloc(0);
    defer page_globals.buddy.free(page, 0);

    const page_size = architecture.paging.standard_page_size.value;
    const ptr: [*]const u8 = @ptrFromInt(page.baseAddress().toDirectMap().value);
    for (0..page_size) |i| try std.testing.expectEqual(@as(u8, 0), ptr[i]);
}

test "buddy: free zeroes the block before returning it to the free list" {
    const page = try page_globals.buddy.alloc(0);

    const page_size = architecture.paging.standard_page_size.value;
    const ptr: [*]u8 = @ptrFromInt(page.baseAddress().toDirectMap().value);
    @memset(ptr[0..page_size], 0xAB);

    // free() must zero the block; the next alloc of this page must see zeros.
    page_globals.buddy.free(page, 0);
    const page2 = try page_globals.buddy.alloc(0);
    defer page_globals.buddy.free(page2, 0);

    const ptr2: [*]const u8 = @ptrFromInt(page2.baseAddress().toDirectMap().value);
    for (0..page_size) |i| try std.testing.expectEqual(@as(u8, 0), ptr2[i]);
}

test "buddy: order-1 block is 2 contiguous zeroed pages" {
    const block = try page_globals.buddy.alloc(1);
    defer page_globals.buddy.free(block, 1);

    const page_size = architecture.paging.standard_page_size.value;
    const ptr: [*]const u8 = @ptrFromInt(block.baseAddress().toDirectMap().value);
    for (0..page_size * 2) |i| try std.testing.expectEqual(@as(u8, 0), ptr[i]);
}
