const PhysicalPage = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const List = @import("List.zig");
pub const init = @import("init.zig");
pub const Index = @import("Index.zig").Index;
const globals = @import("globals.zig");

node: List.Node = .{},

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

fn allocate() Allocator.AllocateError!Index {
    const index = globals.free_page_list.popFirst() orelse return error.PagesExhausted;

    _ = globals.free_memory.fetchSub(
        architecture.paging.standard_page_size.value,
        .release,
    );

    if (core.is_debug) {
        const virtual_range: innigkeit.KernelVirtualRange = .from(
            index.baseAddress().toDirectMap(),
            architecture.paging.standard_page_size,
        );

        @memset(virtual_range.byteSlice(), undefined);
    }

    return index;
}

fn deallocate(list: List) void {
    if (list.count == 0) {
        @branchHint(.unlikely);
        return;
    }

    _ = globals.free_memory.fetchAdd(
        architecture.paging.standard_page_size.multiplyScalar(list.count).value,
        .release,
    );

    globals.free_page_list.prependList(list);
}
