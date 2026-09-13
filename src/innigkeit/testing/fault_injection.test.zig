//! Fault-injection tests for the physical-page allocator seam.

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

const FaultInjectingAllocator = @import("FaultInjectingAllocator.zig");
const PhysicalPage = innigkeit.memory.PhysicalPage;

/// A page table that exists only in memory, never loaded into a real CPU
/// register: `PageTable.create` zeroes the page, so every level is
/// created fresh by whatever this test maps into it, with no shared
/// structure with the real, running kernel page table to ever corrupt.
const ScratchPageTable = struct {
    page_table: architecture.paging.PageTable,

    fn create() !ScratchPageTable {
        const root_page = try PhysicalPage.allocator.allocate();
        return .{ .page_table = .create(root_page) };
    }

    fn destroy(self: ScratchPageTable) void {
        var list: PhysicalPage.List = .{};
        list.prepend(self.page_table.physical_page);
        PhysicalPage.allocator.deallocate(list);
    }
};

const map_type: innigkeit.memory.MapType = .{
    .type = .kernel,
    .protection = .{ .read = true, .write = true },
};

/// This scratch page table shares nothing with the real kernel page table
/// (see `ScratchPageTable`'s own doc comment), so every intermediate
/// page-table-level page created while mapping into it is exclusively this
/// test's to reclaim. i.e. we use `.free`, not `.keep` (the choice a *shared,
/// long-lived* structure like the real kernel heap's own page-table region
/// wants, e.g. `heap/AllocatorImplementation.zig`'s `heapPageArenaRelease`,
/// where freeing a table page out from under other live mappings would be
/// wrong).
const top_level_decision: core.CleanupDecision = .free;

/// Generous upper bound on allocations a fresh 2-page mapping could need
/// (data pages + intermediate table levels) on any supported architecture
const generous_success_budget = 12;

test "fault injection: mapRangeAndBackWithPhysicalPages leaks nothing on OOM at any allocation point" {
    const scratch = try ScratchPageTable.create();
    defer scratch.destroy();

    const range: innigkeit.VirtualRange = .from(
        architecture.paging.kernel_memory_range.address,
        architecture.paging.standard_page_size.multiplyScalar(2),
    );

    var budget: usize = 0;
    while (budget <= generous_success_budget) : (budget += 1) {
        FaultInjectingAllocator.reset(budget);

        const result = innigkeit.memory.mapRangeAndBackWithPhysicalPages(
            scratch.page_table,
            range,
            map_type,
            .kernel,
            top_level_decision,
            FaultInjectingAllocator.allocator,
        );

        if (result) |_| {
            var unmap_batch: innigkeit.memory.VirtualRangeBatch = .{};
            unmap_batch.appendMergeIfFull(range);
            innigkeit.memory.unmap(
                scratch.page_table,
                &unmap_batch,
                .kernel,
                .free,
                top_level_decision,
                FaultInjectingAllocator.allocator,
            );
            try std.testing.expectEqual(0, FaultInjectingAllocator.outstandingCount());
            break;
        } else |err| {
            try std.testing.expectEqual(error.PagesExhausted, err);
            try std.testing.expectEqual(0, FaultInjectingAllocator.outstandingCount());
        }
    } else {
        try std.testing.expect(false);
    }
}

test "fault injection: a failed mapping leaves no stale page-table entries behind" {
    const scratch = try ScratchPageTable.create();
    defer scratch.destroy();

    const range: innigkeit.VirtualRange = .from(
        architecture.paging.kernel_memory_range.address,
        architecture.paging.standard_page_size,
    );

    // Fail on the very first allocation, then again with nothing left to
    // allocate at all budget levels a real success needs: if any of these
    // partial attempts left a page-table entry behind, the real mapping
    // below would see "already mapped" instead of succeeding.
    for ([_]usize{ 0, 1, 2 }) |budget| {
        FaultInjectingAllocator.reset(budget);
        try std.testing.expectError(
            error.PagesExhausted,
            innigkeit.memory.mapRangeAndBackWithPhysicalPages(
                scratch.page_table,
                range,
                map_type,
                .kernel,
                top_level_decision,
                FaultInjectingAllocator.allocator,
            ),
        );
        try std.testing.expectEqual(0, FaultInjectingAllocator.outstandingCount());
    }

    FaultInjectingAllocator.reset(generous_success_budget);
    try innigkeit.memory.mapRangeAndBackWithPhysicalPages(
        scratch.page_table,
        range,
        map_type,
        .kernel,
        top_level_decision,
        FaultInjectingAllocator.allocator,
    );

    var unmap_batch: innigkeit.memory.VirtualRangeBatch = .{};
    unmap_batch.appendMergeIfFull(range);
    innigkeit.memory.unmap(
        scratch.page_table,
        &unmap_batch,
        .kernel,
        .free,
        top_level_decision,
        FaultInjectingAllocator.allocator,
    );
    try std.testing.expectEqual(0, FaultInjectingAllocator.outstandingCount());
}
