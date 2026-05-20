const innigkeit = @import("innigkeit");
const sched_bench = @import("../../bench/sched.zig");
const log = innigkeit.debug.log.scoped(.init);

/// Stage 4 of kernel initialization.
///
/// This function is executed in a fully scheduled kernel task with interrupts enabled.
pub fn start() !void {
    log.info("running scheduler benchmark", .{});
    try sched_bench.run();

    log.debug("initializing PCI ECAM", .{});
    try innigkeit.pci.init.initializeECAM();

    log.debug("initializing ACPI", .{});
    try innigkeit.acpi.init.initialize();

    try innigkeit.time.init.printInitializationTime();

    log.debug("starting first user process", .{});
    const hello_world_process: *innigkeit.user.Process = try .create(
        .{ .name = try .fromSlice("hello world") },
    );
    defer hello_world_process.decrementReferenceCount();

    const hello_world_main_thread = try hello_world_process.createThread(
        .{ .entry = .prepare(loadHelloWorld, .{}) },
    );

    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();
    scheduler_handle.queueTask(&hello_world_main_thread.task, .{ .initial = true });

    // TODO: colors
    try innigkeit.init.Output.experimentalRegister(.full);
}

fn loadHelloWorld() !void {
    const hello_world_elf = @embedFile("hello_world");

    const current_task: innigkeit.Task.Current = .get();
    const thread: *innigkeit.user.Thread = .from(current_task.task);
    const address_space = &thread.process.address_space;

    const header = try innigkeit.user.elf.Header.parse(hello_world_elf);

    const entry_point = blk: {
        const possible_entry_point: innigkeit.VirtualAddress = .from(header.entry);
        if (possible_entry_point.getType() != .user) return error.InvalidEntryPoint;
        break :blk possible_entry_point.toUser();
    };

    const program_header_table: []const u8 = blk: {
        const program_header_table_location = header.programHeaderTableLocation();
        break :blk hello_world_elf[program_header_table_location.base..][0..program_header_table_location.length];
    };

    // map all loadable segments read write - this allows the address space to merge the entries
    // TODO: this only makes sense for an embedded program, not if it is loaded from disk
    {
        var iter = header.loadableRegionIterator(program_header_table);

        while (try iter.next()) |loadable_region| {
            _ = try address_space.map(.{
                .base = loadable_region.virtual_range.address.toVirtualAddress(),
                .size = loadable_region.virtual_range.size,
                .protection = .{ .read = true, .write = true },
                .max_protection = .all,
                .type = .zero_fill,
            });
        }
    }

    // copy the regions from the elf into the address space
    {
        current_task.incrementEnableAccessToUserMemory();
        defer current_task.decrementEnableAccessToUserMemory();

        var iter = header.loadableRegionIterator(program_header_table);

        while (try iter.next()) |loadable_region| {
            if (loadable_region.source_length == 0) continue;

            const mapped_slice = loadable_region.virtual_range.byteSlice();

            @memcpy(
                mapped_slice[loadable_region.destination_offset..][0..loadable_region.source_length],
                hello_world_elf[loadable_region.source_base..][0..loadable_region.source_length],
            );
        }
    }

    // change each regions protections as per the elf
    {
        var iter = header.loadableRegionIterator(program_header_table);

        while (try iter.next()) |loadable_region| {
            try address_space.changeProtection(
                loadable_region.virtual_range.toVirtualRange(),
                .{
                    .both = .{
                        .protection = loadable_region.protection,
                        .max_protection = loadable_region.protection,
                    },
                },
            );
        }
    }

    try thread.start(entry_point, 0);
    unreachable;
}
