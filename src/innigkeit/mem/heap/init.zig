const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");

const globals = @import("globals.zig");
const AllocatorImplementation = @import("AllocatorImplementation.zig");
const init_log = innigkeit.debug.log.scoped(.heap_init);

pub fn initializeHeaps(
    kernel_regions: *const innigkeit.mem.KernelMemoryRegion.List,
) !void {
    // heap
    {
        init_log.debug("initializing heap address space arena", .{});
        try globals.heap_address_space_arena.init(
            .{
                .name = try .fromSlice("heap_address_space"),
                .quantum = architecture.paging.standard_page_size.value,
            },
        );

        init_log.debug("initializing heap page arena", .{});
        try globals.heap_page_arena.init(
            .{
                .name = try .fromSlice("heap_page"),
                .quantum = architecture.paging.standard_page_size.value,
                .source = globals.heap_address_space_arena.createSource(.{
                    .custom_import = AllocatorImplementation.heapPageArenaImport,
                    .custom_release = AllocatorImplementation.heapPageArenaRelease,
                }),
            },
        );

        init_log.debug("initializing heap arena", .{});
        try globals.heap_arena.init(
            .{
                .name = try .fromSlice("heap"),
                .quantum = globals.heap_arena_quantum,
                .source = globals.heap_page_arena.createSource(.{}),
            },
        );

        const heap_range = kernel_regions.find(.kernel_heap).?.range;

        globals.heap_address_space_arena.addSpan(
            heap_range.address.value,
            heap_range.size.value,
        ) catch |err| {
            std.debug.panic("failed to add heap range to `heap_address_space_arena`: {t}!", .{err});
        };
    }

    // special heap
    {
        init_log.debug("initializing special heap address space arena", .{});
        try globals.special_heap_address_space_arena.init(
            .{
                .name = try .fromSlice("special_heap_address_space"),
                .quantum = architecture.paging.standard_page_size.value,
            },
        );

        const special_heap_range = kernel_regions.find(.special_heap).?.range;

        init_log.debug("adding special heap range to special heap address space arena", .{});
        globals.special_heap_address_space_arena.addSpan(
            special_heap_range.address.value,
            special_heap_range.size.value,
        ) catch |err| {
            std.debug.panic(
                "failed to add special heap range to `special_heap_address_space_arena`: {t}!",
                .{err},
            );
        };
    }
}
