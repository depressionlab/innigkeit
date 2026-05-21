const innigkeit = @import("innigkeit");
const sched_bench = @import("../../bench/sched.zig");
const log = innigkeit.debug.log.scoped(.init);

/// Stage 4 of kernel initialization.
///
/// Runs in a fully scheduled kernel task with interrupts enabled.
pub fn start() !void {
    log.info("running scheduler benchmark", .{});
    try sched_bench.run();

    log.debug("initializing PCI ECAM", .{});
    try innigkeit.pci.init.initializeECAM();

    log.debug("initializing ACPI", .{});
    try innigkeit.acpi.init.initialize();

    log.debug("initializing virtio-blk driver", .{});
    innigkeit.drivers.virtio.blk.init();

    if (innigkeit.drivers.virtio.blk.isReady()) {
        var sector: [512]u8 = undefined;
        innigkeit.drivers.virtio.blk.readSectors(0, &sector, 1) catch |err| {
            log.err("virtio-blk sector read failed: {t}", .{err});
        };
        log.info("virtio-blk sector 0 [0..8]: {x}", .{sector[0..8]});
    } else {
        log.warn("virtio-blk not ready", .{});
    }

    try innigkeit.time.init.printInitializationTime();

    log.debug("initializing PS/2 keyboard", .{});
    innigkeit.drivers.input.ps2.init() catch |err| {
        log.err("PS/2 keyboard init failed: {t}", .{err});
    };

    log.debug("starting shell", .{});
    const shell_process: *innigkeit.user.Process = try .create(
        .{ .name = try .fromSlice("shell") },
    );
    defer shell_process.decrementReferenceCount();

    const shell_main_thread = try shell_process.createThread(
        .{ .entry = .prepare(loadShell, .{}) },
    );

    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();
    scheduler_handle.queueTask(&shell_main_thread.task, .{ .initial = true });

    try innigkeit.init.Output.experimentalRegister(.full);
}

fn loadShell() !void {
    try loadElfFromInitfs("shell");
}

fn loadElfFromInitfs(name: []const u8) !noreturn {
    const elf_data = innigkeit.fs.initfs.findFile(name) orelse {
        log.err("'{s}' not found in initfs", .{name});
        return error.FileNotFound;
    };

    const current_task: innigkeit.Task.Current = .get();
    const thread: *innigkeit.user.Thread = .from(current_task.task);
    const address_space = &thread.process.address_space;

    const header = try innigkeit.user.elf.Header.parse(elf_data);

    const entry_point = blk: {
        const possible_entry_point: innigkeit.VirtualAddress = .from(header.entry);
        if (possible_entry_point.getType() != .user) return error.InvalidEntryPoint;
        break :blk possible_entry_point.toUser();
    };

    const program_header_table: []const u8 = blk: {
        const loc = header.programHeaderTableLocation();
        break :blk elf_data[loc.base..][0..loc.length];
    };

    // Map all loadable segments read-write so the address space can merge entries.
    {
        var iter = header.loadableRegionIterator(program_header_table);

        while (try iter.next()) |region| {
            _ = try address_space.map(.{
                .base = region.virtual_range.address.toVirtualAddress(),
                .size = region.virtual_range.size,
                .protection = .{ .read = true, .write = true },
                .max_protection = .all,
                .type = .zero_fill,
            });
        }
    }

    // Copy ELF segments into the mapped address space.
    {
        current_task.incrementEnableAccessToUserMemory();
        defer current_task.decrementEnableAccessToUserMemory();

        var iter = header.loadableRegionIterator(program_header_table);

        while (try iter.next()) |region| {
            if (region.source_length == 0) continue;
            const mapped_slice = region.virtual_range.byteSlice();

            @memcpy(
                mapped_slice[region.destination_offset..][0..region.source_length],
                elf_data[region.source_base..][0..region.source_length],
            );
        }
    }

    // Apply correct protections as specified by the ELF program headers.
    {
        var iter = header.loadableRegionIterator(program_header_table);

        while (try iter.next()) |region| {
            try address_space.changeProtection(
                region.virtual_range.toVirtualRange(),
                .{
                    .both = .{
                        .protection = region.protection,
                        .max_protection = region.protection,
                    },
                },
            );
        }
    }

    try thread.start(entry_point, 0);
    unreachable;
}
