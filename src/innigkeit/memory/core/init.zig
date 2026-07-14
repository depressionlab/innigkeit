const architecture = @import("architecture");
const boot = @import("boot");
const core = @import("core");
const globals = @import("globals.zig");
const innigkeit = @import("innigkeit");
const std = @import("std");

const init_log = innigkeit.debug.log.scoped(.mem_init);

/// Determine the kernels various offsets and the direct map early in the boot process.
pub fn determineEarlyMemoryLayout() EarlyMemoryLayoutHandle {
    const base_address = boot.kernelBaseAddress() orelse
        @panic("no kernel base address!");
    globals.virtual_base_address = base_address.virtual;

    globals.kernel_virtual_offset = innigkeit.config.memory.kernel_base_address.difference(base_address.virtual);

    init_globals.kernel_physical_to_virtual_offset = core.Size.from(
        base_address.virtual.value - base_address.physical.value,
        .byte,
    );

    const direct_map_size = direct_map_size: {
        var terminating_physical_address: innigkeit.PhysicalAddress = .zero;

        var iter = boot.memoryMap() catch
            @panic("no memory map!");

        while (iter.next()) |entry| {
            const range_terminating_address = entry.range.after();
            if (range_terminating_address.greaterThan(terminating_physical_address)) {
                terminating_physical_address = range_terminating_address;
            }
        }

        break :direct_map_size innigkeit.PhysicalAddress.zero.difference(terminating_physical_address);
    };

    globals.direct_map = .from(
        boot.directMapAddress() orelse
            @panic("direct map address not provided!"),
        direct_map_size,
    );

    return .{};
}

pub const EarlyMemoryLayoutHandle = struct {
    pub fn log(_: EarlyMemoryLayoutHandle) void {
        if (!init_log.levelEnabled(.debug)) return;

        init_log.debug("kernel memory offsets:", .{});

        init_log.debug("  virtual base address:       {f}", .{globals.virtual_base_address});
        init_log.debug("  virtual offset:             0x{x:0>16}", .{globals.kernel_virtual_offset.value});
        init_log.debug("  physical to virtual:        0x{x:0>16}", .{init_globals.kernel_physical_to_virtual_offset.value});
        init_log.debug("  direct map:                 {f}", .{globals.direct_map});
    }
};

pub fn initializeMemorySystem() !void {
    if (init_log.levelEnabled(.debug)) {
        var memory_iter = boot.memoryMap() catch @panic("no memory map!");
        init_log.debug("bootloader provided memory map:", .{});
        while (memory_iter.next()) |entry| {
            init_log.debug("\t{f}", .{entry});
        }
    }

    init_log.debug("building kernel memory layout", .{});
    buildMemoryLayout();

    init_log.debug("building kernel page table", .{});
    globals.kernel_page_table = buildAndLoadKernelPageTable();

    init_log.debug("initializing physical memory", .{});
    innigkeit.memory.PhysicalPage.init.initializePhysicalMemory(globals.regions.find(.pages).?.range);

    init_log.debug("initializing caches", .{});
    try innigkeit.memory.cache.init.initializeCaches();
    try innigkeit.memory.arena.init.initializeCaches();
    try innigkeit.memory.AddressSpace.AnonMap.init.initializeCaches();
    try innigkeit.memory.AddressSpace.AnonPage.init.initializeCaches();
    try innigkeit.memory.AddressSpace.Entry.init.initializeCaches();

    init_log.debug("initializing kernel and special heap", .{});
    try innigkeit.memory.heap.init.initializeHeaps(&globals.regions);

    init_log.debug("initializing kernel address space", .{});
    try globals.kernel_address_space.init(
        .{
            .name = try .fromSlice("kernel"),
            .range = globals.regions.find(.kernel_address_space).?.range.toVirtualRange(),
            .page_table = globals.kernel_page_table,
            .context = .kernel,
        },
    );

    globals.memory_system_initialized = true;
}

fn buildMemoryLayout() void {
    const kernel_regions = &globals.regions;

    registerKernelSections(kernel_regions);
    registerDirectMap(kernel_regions);
    registerHeaps(kernel_regions);
    registerPages(kernel_regions);

    kernel_regions.sort();

    if (init_log.levelEnabled(.debug)) {
        init_log.debug("kernel memory layout:", .{});

        for (kernel_regions.constSlice()) |region| {
            init_log.debug("\t{f}", .{region});
        }
    }
}

fn registerKernelSections(kernel_regions: *innigkeit.memory.KernelMemoryRegion.List) void {
    const linker_symbols = struct {
        extern const __text_start: u8;
        extern const __text_end: u8;
        extern const __rodata_start: u8;
        extern const __rodata_end: u8;
        extern const __data_start: u8;
        extern const __data_end: u8;
    };

    var sections: core.containers.BoundedArray(struct {
        innigkeit.KernelVirtualAddress,
        innigkeit.KernelVirtualAddress,
        innigkeit.memory.KernelMemoryRegion.Type,
    }, 4) = .{};

    sections.appendAssumeCapacity(.{
        .fromPtr(&linker_symbols.__text_start),
        .fromPtr(&linker_symbols.__text_end),
        .executable_section,
    });

    sections.appendAssumeCapacity(.{
        .fromPtr(&linker_symbols.__rodata_start),
        .fromPtr(&linker_symbols.__rodata_end),
        .readonly_section,
    });

    sections.appendAssumeCapacity(.{
        .fromPtr(&linker_symbols.__data_start),
        .fromPtr(&linker_symbols.__data_end),
        .writeable_section,
    });

    for (sections.constSlice()) |section| {
        const start_address = section[0];
        const end_address = section[1];
        const region_type = section[2];

        if (core.is_debug) std.debug.assert(end_address.greaterThan(start_address));

        const virtual_range: innigkeit.KernelVirtualRange = .from(
            start_address,
            core.Size.from(end_address.value - start_address.value, .byte)
                .alignForward(architecture.paging.standard_page_size_alignment),
        );

        kernel_regions.append(.{
            .range = virtual_range,
            .type = region_type,
        });
    }
}

fn registerDirectMap(kernel_regions: *innigkeit.memory.KernelMemoryRegion.List) void {
    const direct_map = globals.direct_map;

    // does the direct map range overlap a pre-existing region?
    for (kernel_regions.constSlice()) |region| {
        if (region.range.anyOverlap(direct_map)) {
            std.debug.panic("direct map overlaps region: {f}", .{region});
        }
    }

    kernel_regions.append(.{
        .range = direct_map,
        .type = .direct_map,
    });
}

fn registerHeaps(kernel_regions: *innigkeit.memory.KernelMemoryRegion.List) void {
    const size_of_top_level = architecture.paging.init.sizeOfTopLevelEntry();
    const size_of_top_level_alignment = size_of_top_level.toAlignment();

    const kernel_heap_range = kernel_regions.findFreeRange(
        size_of_top_level,
        size_of_top_level_alignment,
    ) orelse
        @panic("no space in kernel memory layout for the kernel heap!");

    kernel_regions.append(.{
        .range = kernel_heap_range,
        .type = .kernel_heap,
    });

    const special_heap_range = kernel_regions.findFreeRange(
        size_of_top_level,
        size_of_top_level_alignment,
    ) orelse
        @panic("no space in kernel memory layout for the special heap!");

    kernel_regions.append(.{
        .range = special_heap_range,
        .type = .special_heap,
    });

    const kernel_stacks_range = kernel_regions.findFreeRange(
        size_of_top_level,
        size_of_top_level_alignment,
    ) orelse
        @panic("no space in kernel memory layout for the kernel stacks!");

    kernel_regions.append(.{
        .range = kernel_stacks_range,
        .type = .kernel_stacks,
    });

    const kernel_address_space_range = kernel_regions.findFreeRange(
        size_of_top_level,
        size_of_top_level_alignment,
    ) orelse
        @panic("no space in kernel memory layout for the kernel address space!");

    kernel_regions.append(.{
        .range = kernel_address_space_range,
        .type = .kernel_address_space,
    });
}

fn registerPages(kernel_regions: *innigkeit.memory.KernelMemoryRegion.List) void {
    const page_entries_to_cover = blk: {
        var iter = boot.usableRangeIterator() catch
            @panic("no memory map!");

        var last_page: innigkeit.PhysicalAddress = .zero;

        while (iter.next()) |range| {
            last_page = range.last();
        }

        break :blk @intFromEnum(innigkeit.memory.PhysicalPage.Index.fromAddress(last_page)) + 1;
    };

    const pages_range = kernel_regions.findFreeRange(
        core.Size.of(innigkeit.memory.PhysicalPage)
            .multiplyScalar(page_entries_to_cover)
            .alignForward(architecture.paging.standard_page_size_alignment),
        architecture.paging.standard_page_size_alignment,
    ) orelse @panic("no space in kernel memory layout for the pages array");

    kernel_regions.append(.{
        .range = pages_range,
        .type = .pages,
    });
}

fn buildAndLoadKernelPageTable() architecture.paging.PageTable {
    const kernel_page_table: architecture.paging.PageTable = .create(
        innigkeit.memory.PhysicalPage.init.bootstrap_allocator.allocate() catch unreachable,
    );

    for (globals.regions.constSlice()) |region| {
        init_log.debug("mapping '{t}' into the kernel page table", .{region.type});

        switch (region.type) {
            .direct_map => {
                const direct_map_base = region.range.address;
                const page_alignment = architecture.paging.standard_page_size_alignment;

                var iter = boot.memoryMap() catch
                    @panic("no memory map!");

                // Highest physical address already mapped into the direct map.
                // The bootloader memory map is sorted ascending, so rounding an
                // entry's range out to page boundaries can extend it into the
                // boundary page of the next entry. Each entry's mapping is
                // clamped to start at `mapped_until` to avoid double-mapping a
                // shared page (which `mapToPhysicalRangeAllPageSizes` rejects).
                var mapped_until: innigkeit.PhysicalAddress = .zero;

                while (iter.next()) |entry| {
                    const cache_type: innigkeit.memory.MapType.Cache = switch (entry.type) {
                        .free, .in_use, .bootloader_reclaimable, .acpi_reclaimable, .acpi_nvs, .reserved_mapped => .write_back,
                        .framebuffer => .write_combining,
                        .reserved, .unusable, .unknown => continue,
                    };

                    // Round the entry out to whole pages. x86-64 bootloaders
                    // already report page-aligned entries (this is a no-op
                    // there); aarch64 (Limine/QEMU virt) can report sub-page
                    // sizes, which `mapToPhysicalRangeAllPageSizes` cannot map.
                    var phys_start = entry.range.address.alignBackward(page_alignment);
                    const phys_end = entry.range.after().alignForward(page_alignment);
                    if (phys_start.lessThan(mapped_until)) phys_start = mapped_until;
                    if (!phys_start.lessThan(phys_end)) continue; // fully covered
                    const phys_range: innigkeit.PhysicalRange = .from(
                        phys_start,
                        core.Size.from(phys_end.value - phys_start.value, .byte),
                    );
                    mapped_until = phys_end;

                    architecture.paging.init.mapToPhysicalRangeAllPageSizes(
                        kernel_page_table,
                        innigkeit.KernelVirtualRange.from(
                            direct_map_base.moveForward(
                                innigkeit.PhysicalAddress.zero.difference(phys_range.address),
                            ),
                            phys_range.size,
                        ).toVirtualRange(),
                        phys_range,
                        .{
                            .type = .kernel,
                            .protection = .{ .read = true, .write = true },
                            .cache = cache_type,
                        },
                        innigkeit.memory.PhysicalPage.init.bootstrap_allocator,
                    ) catch |err| std.debug.panic("failed to map {f}: {t}!", .{ region, err });
                }
            },

            .writeable_section,
            .readonly_section,
            .executable_section,
            => architecture.paging.init.mapToPhysicalRangeAllPageSizes(
                kernel_page_table,
                region.range.toVirtualRange(),
                .from(
                    .from(region.range.address.value - init_globals.kernel_physical_to_virtual_offset.value),
                    region.range.size,
                ),
                switch (region.type) {
                    .executable_section => .{ .type = .kernel, .protection = .{ .execute = true } },
                    .readonly_section => .{ .type = .kernel, .protection = .{ .read = true } },
                    .writeable_section => .{ .type = .kernel, .protection = .{ .read = true, .write = true } },
                    else => unreachable,
                },
                innigkeit.memory.PhysicalPage.init.bootstrap_allocator,
            ) catch |err| std.debug.panic("failed to map {f}: {t}!", .{ region, err }),

            .kernel_heap,
            .kernel_stacks,
            .special_heap,
            .kernel_address_space,
            => architecture.paging.init.fillTopLevel(
                kernel_page_table,
                region.range.toVirtualRange(),
                innigkeit.memory.PhysicalPage.init.bootstrap_allocator,
            ) catch |err| std.debug.panic("failed to map {f}: {t}!", .{ region, err }),

            .pages => innigkeit.memory.PhysicalPage.init.mapPagesArray(
                kernel_page_table,
                region.range,
            ) catch |err| std.debug.panic("failed to map {f}: {t}!", .{ region, err }),
        }
    }

    init_log.debug("loading kernel page table", .{});
    kernel_page_table.load();

    return kernel_page_table;
}

const init_globals = struct {
    /// Offset from the virtual address of kernel sections to the physical address of the section.
    ///
    /// Initialized during `init.determineEarlyMemoryLayout`.
    var kernel_physical_to_virtual_offset: core.Size = undefined;
};
