const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const globals = @import("globals.zig");

const boot = @import("boot");
const init_log = innigkeit.debug.log.scoped(.mem_init);

pub const bootstrap_allocator: innigkeit.mem.PhysicalPage.Allocator = .{
    .allocate = struct {
        fn allocate() !innigkeit.mem.PhysicalPage.Index {
            const non_empty_region: *FreePhysicalRegion =
                region: for (init_globals.bootstrap_physical_regions.slice()) |*region| {
                    if (region.first_free_page_index < region.page_count) break :region region;
                } else {
                    for (init_globals.bootstrap_physical_regions.constSlice()) |region| {
                        init_log.warn("  region: {}", .{region});
                    }

                    @panic("no empty region in bootstrap physical page allocator!");
                };

            const first_free_page_index = non_empty_region.first_free_page_index;
            non_empty_region.first_free_page_index = first_free_page_index + 1;

            return @enumFromInt(@intFromEnum(non_empty_region.start_physical_page) + first_free_page_index);
        }
    }.allocate,
    .deallocate = struct {
        fn deallocate(_: innigkeit.mem.PhysicalPage.List) void {
            @panic("deallocate not supported!");
        }
    }.deallocate,
};

/// Initialize the bootstrap physical page allocator that is used for allocating physical pages before the full memory
/// system is initialized.
pub fn initializeBootstrapAllocator() void {
    var memory_map = boot.memoryMap() catch @panic("no memory map!");
    while (memory_map.next()) |entry| {
        if (entry.type != .free) continue;

        // TODO: if the last page of the entry is greater or equal to `std.math.maxInt(u32)` those pages cannot be represented by
        //       `Index`, we should break out of the loop and print a warning later in the boot process
        //       this unaccessible pages will need to be marked as unavailable in `initializePhysicalMemory`

        init_globals.bootstrap_physical_regions.append(.{
            .start_physical_page = .fromAddress(entry.range.address),
            .first_free_page_index = 0,
            .page_count = @intCast(entry.range.size.divide(architecture.paging.standard_page_size)),
        }) catch @panic("exceeded max number of physical regions!");
    }
}

/// Maps the pages array sparsely, only backing regions corresponding to usable physical memory.
pub fn mapPagesArray(
    kernel_page_table: architecture.paging.PageTable,
    pages_array_range: innigkeit.KernelVirtualRange,
) !void {
    const pages_array_base = pages_array_range.address;

    var opt_current_pages_range: ?innigkeit.KernelVirtualRange = null;

    var iter = boot.usableRangeIterator() catch @panic("no memory map!");

    while (iter.next()) |entry_range| {
        const entry_pages_range = innigkeit.KernelVirtualRange.from(
            pages_array_base.moveForward(
                core.Size.of(innigkeit.mem.PhysicalPage).multiplyScalar(
                    @intFromEnum(innigkeit.mem.PhysicalPage.Index.fromAddress(entry_range.address)),
                ),
            ),
            core.Size.of(innigkeit.mem.PhysicalPage).multiplyScalar(
                @intFromEnum(innigkeit.mem.PhysicalPage.Index.fromAddress(entry_range.last())),
            ),
        ).pageAlign();

        const current_pages_range = opt_current_pages_range orelse {
            opt_current_pages_range = entry_pages_range;
            continue;
        };

        if (current_pages_range.anyOverlap(entry_pages_range) or
            current_pages_range.after().equal(entry_pages_range.address))
        {
            std.debug.assert(current_pages_range.address.lessThanOrEqual(entry_pages_range.address));
            opt_current_pages_range.?.size.addInPlace(current_pages_range.after().difference(entry_pages_range.after()));
            continue;
        }

        opt_current_pages_range = entry_pages_range;

        try innigkeit.mem.mapRangeAndBackWithPhysicalPages(
            kernel_page_table,
            current_pages_range.toVirtualRange(),
            .{ .protection = .{ .read = true, .write = true }, .type = .kernel },
            .kernel,
            .keep,
            bootstrap_allocator,
        );
    }

    if (opt_current_pages_range) |range| {
        try innigkeit.mem.mapRangeAndBackWithPhysicalPages(
            kernel_page_table,
            range.toVirtualRange(),
            .{ .protection = .{ .read = true, .write = true }, .type = .kernel },
            .kernel,
            .keep,
            bootstrap_allocator,
        );
    }
}

/// Initializes the normal physical page allocator and the pages array.
///
/// Pulls all memory out of the bootstrap physical page allocator and uses it to populate the normal allocator.
pub fn initializePhysicalMemory(pages_range: innigkeit.KernelVirtualRange) void {
    const pages: []innigkeit.mem.PhysicalPage = @alignCast(std.mem.bytesAsSlice(
        innigkeit.mem.PhysicalPage,
        pages_range.byteSlice(),
    ));
    globals.pages = pages;

    var total_memory: core.Size = .zero;
    var reserved_memory: core.Size = .zero;
    var reclaimable_memory: core.Size = .zero;
    var framebuffer_memory: core.Size = .zero;
    var unavailable_memory: core.Size = .zero;

    var memory_iter = boot.memoryMap() catch @panic("no memory map!");

    while (memory_iter.next()) |entry| {
        total_memory.addInPlace(entry.range.size);

        switch (entry.type) {
            .free, .in_use => {},
            .framebuffer => framebuffer_memory.addInPlace(entry.range.size),
            .reserved, .acpi_nvs, .reserved_mapped => reserved_memory.addInPlace(entry.range.size),
            .bootloader_reclaimable, .acpi_reclaimable => reclaimable_memory.addInPlace(entry.range.size),
            .unusable, .unknown => unavailable_memory.addInPlace(entry.range.size),
        }

        if (entry.type.isUsableForAllocation()) {
            const first_page_index: usize = @intFromEnum(innigkeit.mem.PhysicalPage.Index.fromAddress(entry.range.address));
            const last_page_index: usize = @intFromEnum(innigkeit.mem.PhysicalPage.Index.fromAddress(entry.range.last()));

            const slice = pages[first_page_index..last_page_index];

            @memset(slice, .{});
        }
    }

    var free_memory: core.Size = .zero;

    const bootstrap_regions = init_globals.bootstrap_physical_regions;
    init_globals.bootstrap_physical_regions = undefined;

    for (bootstrap_regions.constSlice()) |bootstrap_region| {
        std.debug.assert(
            (@as(usize, @intFromEnum(bootstrap_region.start_physical_page)) +
                @as(usize, bootstrap_region.page_count -| 1) <
                @as(usize, @intFromEnum(innigkeit.mem.PhysicalPage.Index.none))),
        );

        const in_use_pages = bootstrap_region.first_free_page_index;
        const free_pages = bootstrap_region.page_count - in_use_pages;

        free_memory.addInPlace(architecture.paging.standard_page_size.multiplyScalar(free_pages));

        if (init_log.levelEnabled(.debug)) {
            if (in_use_pages == 0) {
                init_log.debug(
                    "pulled {} ({f}) free pages out of bootstrap page allocator region",
                    .{
                        free_pages,
                        architecture.paging.standard_page_size.multiplyScalar(free_pages),
                    },
                );
            } else if (in_use_pages == bootstrap_region.page_count) {
                init_log.debug(
                    "pulled {} ({f}) in use pages out of bootstrap page allocator region",
                    .{
                        in_use_pages,
                        architecture.paging.standard_page_size.multiplyScalar(in_use_pages),
                    },
                );
            } else {
                init_log.debug(
                    "pulled {} ({f}) free pages and {} ({f}) in use pages out of bootstrap page allocator region",
                    .{
                        free_pages,
                        architecture.paging.standard_page_size.multiplyScalar(free_pages),
                        in_use_pages,
                        architecture.paging.standard_page_size.multiplyScalar(in_use_pages),
                    },
                );
            }
        }

        var current_free_index: usize = @as(usize, @intFromEnum(bootstrap_region.start_physical_page)) + @as(usize, bootstrap_region.first_free_page_index);
        const last_free_index: usize = @as(usize, @intFromEnum(bootstrap_region.start_physical_page)) + @as(usize, bootstrap_region.page_count) - 1;

        while (current_free_index <= last_free_index) : (current_free_index += 1) {
            globals.free_page_list.prepend(@enumFromInt(@as(u32, @intCast(current_free_index))));
        }
    }

    globals.free_memory.store(free_memory.value, .release);
    globals.total_memory = total_memory;
    globals.reserved_memory = reserved_memory;
    globals.reclaimable_memory = reclaimable_memory;
    globals.framebuffer_memory = framebuffer_memory;
    globals.unavailable_memory = unavailable_memory;

    const used_memory = total_memory
        .subtract(free_memory)
        .subtract(reserved_memory)
        .subtract(reclaimable_memory)
        .subtract(framebuffer_memory)
        .subtract(unavailable_memory);

    init_log.debug("total memory:         {f}", .{total_memory});
    init_log.debug("  free memory:        {f}", .{free_memory});
    init_log.debug("  used memory:        {f}", .{used_memory});
    init_log.debug("  reserved memory:    {f}", .{reserved_memory});
    init_log.debug("  reclaimable memory: {f}", .{reclaimable_memory});
    init_log.debug("  framebuffer memory: {f}", .{framebuffer_memory});
    init_log.debug("  unavailable memory: {f}", .{unavailable_memory});
}

const FreePhysicalRegion = struct {
    /// The first page of the region.
    start_physical_page: innigkeit.mem.PhysicalPage.Index,

    /// Index of the first free page in this region.
    first_free_page_index: u32,

    /// Total number of pages in the region.
    page_count: u32,

    pub const List = core.containers.BoundedArray(FreePhysicalRegion, max_regions);
    const max_regions: usize = 64;
};

const init_globals = struct {
    /// The physical regions used by the bootstrap allocator.
    ///
    /// Initialized during `init.initializeBootstrapPageAllocator`.
    var bootstrap_physical_regions: FreePhysicalRegion.List = .{};
};
