//! A capability representing a region of physical memory (one page for now).
//!
//! Frames can be shared between processes by transferring the capability.
//! Mapping a Frame into an address space is a future operation via the Vmem syscall.
const Frame = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");

/// Revocation generation counter. See `Notify.generation` for semantics.
generation: std.atomic.Value(u32) = .init(0),
refcount: std.atomic.Value(usize) = .init(1),
page: innigkeit.mem.PhysicalPage.Index,

/// Allocate a new single-page Frame.
pub fn create() error{OutOfMemory}!*Frame {
    const page = innigkeit.mem.PhysicalPage.allocator.allocate() catch return error.OutOfMemory;
    errdefer {
        var list: innigkeit.mem.PhysicalPage.List = .{};
        list.prepend(page);
        innigkeit.mem.PhysicalPage.allocator.deallocate(list);
    }
    const self = innigkeit.mem.heap.allocator.create(Frame) catch return error.OutOfMemory;
    self.* = .{ .page = page };
    return self;
}

pub fn ref(self: *Frame) void {
    _ = self.refcount.fetchAdd(1, .acq_rel);
}

pub fn unref(self: *Frame) void {
    if (self.refcount.fetchSub(1, .acq_rel) != 1) return;
    var list: innigkeit.mem.PhysicalPage.List = .{};
    list.prepend(self.page);
    innigkeit.mem.PhysicalPage.allocator.deallocate(list);
    innigkeit.mem.heap.allocator.destroy(self);
}

/// Return the base physical address of this frame.
pub fn physicalAddress(self: *const Frame) innigkeit.PhysicalAddress {
    return self.page.baseAddress();
}

/// cap_invoke operations for Frame.
pub const Op = enum(u64) {
    /// Clone: create a new cap handle to the same frame in this process.
    clone = 0,
    /// PhysAddr: return the physical base address as word[0].
    phys_addr = 1,
};
