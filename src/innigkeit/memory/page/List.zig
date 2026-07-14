//! A non-atomic singly linked list of physical pages.
//!
//! Tracks both first and last index to allow `List.Atomic` to atomically prepend the whole list.
//!
//! Tracks the count to allow `deallocate` to atomically update the amount of free memory.
const List = @This();

const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

first_index: innigkeit.memory.PhysicalPage.Index = .none,
last_index: innigkeit.memory.PhysicalPage.Index = .none,
count: u32 = 0,

pub const Node = struct {
    next: innigkeit.memory.PhysicalPage.Index = .none,
};

pub fn prepend(self: *List, index: innigkeit.memory.PhysicalPage.Index) void {
    const page: *innigkeit.memory.PhysicalPage = .fromIndex(index);

    page.node.next = self.first_index;
    self.first_index = index;
    if (self.last_index == .none) {
        @branchHint(.unlikely);
        self.last_index = index;
    }
    self.count += 1;
}

pub const Atomic = struct {
    first_index: std.atomic.Value(innigkeit.memory.PhysicalPage.Index) = .init(.none),

    /// Removes the first index from the list and returns it.
    pub fn popFirst(self: *Atomic) ?innigkeit.memory.PhysicalPage.Index {
        var first = self.first_index.load(.monotonic);

        while (first != .none) {
            const page: *innigkeit.memory.PhysicalPage = .fromIndex(first);
            const node = &page.node;

            if (self.first_index.cmpxchgWeak(
                first,
                node.next,
                .acq_rel,
                .monotonic,
            )) |new_first| {
                first = new_first;
                continue;
            }

            node.* = .{};
            return first;
        }

        return null;
    }

    /// Prepend a single index to the front of the list.
    ///
    /// Asserts that `index` is not `.none`.
    pub fn prepend(self: *Atomic, index: innigkeit.memory.PhysicalPage.Index) void {
        self.prependList(.{
            .first_index = index,
            .last_index = index,
            .count = 1,
        });
    }

    /// Prepend a linked list to the front of the list.
    ///
    /// The provided list is expected to be already linked correctly.
    ///
    /// `first_index` and `last_index` can be the same index.
    ///
    /// Asserts that `first_index` and `last_index` are not `.none`.
    pub fn prependList(self: *Atomic, list: List) void {
        if (core.is_debug) {
            std.debug.assert(list.first_index != .none);
            std.debug.assert(list.last_index != .none);
        }

        const last_page: *innigkeit.memory.PhysicalPage = .fromIndex(list.last_index);
        const last_node = &last_page.node;
        const new_first_index = list.first_index;

        var first = self.first_index.load(.monotonic);

        while (true) {
            last_node.next = first;

            if (self.first_index.cmpxchgWeak(
                first,
                new_first_index,
                .acq_rel,
                .monotonic,
            )) |new_first| {
                first = new_first;
                continue;
            }

            return;
        }
    }
};
