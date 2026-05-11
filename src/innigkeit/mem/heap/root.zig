//! Provides a kernel heap.

const std = @import("std");
const innigkeit = @import("innigkeit");

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = AllocatorImplementation.alloc,
        .resize = AllocatorImplementation.resize,
        .remap = AllocatorImplementation.remap,
        .free = AllocatorImplementation.free,
    },
};

pub const AllocateSpecialOptions = @import("AllocateSpecialOptions.zig");
const AllocatorImplementation = @import("AllocatorImplementation.zig");

// pub to allow access by `innigkeit.mem.cache`
pub const heap_page_arena = &globals.heap_page_arena;
const globals = @import("globals.zig");
pub const init = @import("init.zig");
pub const c = @import("c.zig");

/// Allocate a range of memory that is mapped to a specific physical range with the given map type.
pub fn allocateSpecial(
    options: AllocateSpecialOptions,
) AllocateSpecialOptions.Error!innigkeit.KernelVirtualRange {
    const page_aligned_physical_range = options.physical_range.pageAlign();

    const allocation = globals.special_heap_address_space_arena.allocate(
        page_aligned_physical_range.size.value,
        .instant_fit,
    ) catch |err| {
        @branchHint(.cold);
        return switch (err) {
            error.ZeroLength => error.ZeroLength,
            error.RequestedLengthUnavailable, error.OutOfBoundaryTags => error.OutOfMemory,
        };
    };
    errdefer globals.special_heap_address_space_arena.deallocate(allocation);

    const page_aligned_virtual_range = allocation.toVirtualRange();

    {
        globals.special_heap_page_table_mutex.lock();
        defer globals.special_heap_page_table_mutex.unlock();

        innigkeit.mem.mapRangeToPhysicalRange(
            innigkeit.mem.kernelPageTable(),
            page_aligned_virtual_range.toVirtualRange(),
            page_aligned_physical_range,
            .{
                .type = .kernel,
                .protection = options.protection,
                .cache = options.cache,
            },
            .kernel,
            .keep,
            innigkeit.mem.PhysicalPage.allocator,
        ) catch |err| {
            @branchHint(.cold);
            switch (err) {
                error.AlreadyMapped, error.MappingNotValid => std.debug.panic(
                    "allocate special failed: {s}!",
                    .{@errorName(err)},
                ),
                error.PagesExhausted => return error.OutOfMemory,
            }
        };
    }

    return .from(
        page_aligned_virtual_range.address
            .moveForward(page_aligned_physical_range.address.difference(options.physical_range.address)),
        options.physical_range.size,
    );
}

/// Deallocate a range of memory that was allocated by `allocateSpecial`.
///
/// **REQUIREMENTS**:
/// - `virtual_range` must be a range that was previously allocated by `allocateSpecial`.
pub fn deallocateSpecial(virtual_range: innigkeit.KernelVirtualRange) void {
    const page_aligned_virtual_range = virtual_range.pageAlign();

    {
        globals.special_heap_page_table_mutex.lock();
        defer globals.special_heap_page_table_mutex.unlock();

        var unmap_batch: innigkeit.mem.VirtualRangeBatch = .{};
        std.debug.assert(unmap_batch.append(page_aligned_virtual_range.toVirtualRange()));

        innigkeit.mem.unmap(
            innigkeit.mem.kernelPageTable(),
            &unmap_batch,
            .kernel,
            .keep,
            .keep,
            innigkeit.mem.PhysicalPage.allocator,
        );
    }

    globals.special_heap_address_space_arena.deallocate(.fromVirtualRange(page_aligned_virtual_range));
}
