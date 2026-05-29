const builtin = @import("builtin");
const innigkeit = @import("innigkeit");
const sched_bench = @import("../../bench/sched.zig");
const log = innigkeit.debug.log.scoped(.init);

/// Stage 4 of kernel initialization.
///
/// Runs in a fully scheduled kernel task with interrupts enabled.
pub fn start() !void {
    // In test builds, run all collected unit tests then signal QEMU to exit.
    //
    // Convention: QEMU exit code 0 = all tests passed; non-zero = failure.
    // This lets the build step use the standard "exit 0 = success" rule with
    // stdio = .inherit (which always shows test output on the terminal).
    //
    // - x64 pass: ACPI S5 soft-off via ICH9 PM1a_CNT port 0x604 -> QEMU exits 0.
    // - x64 fail: ISA debug-exit (port 0xf4) write 1 -> QEMU exits 3.
    // - arm pass: AArch64 semihosting SYS_EXIT subcode 0 -> QEMU exits 0.
    // - arm fail: AArch64 semihosting SYS_EXIT subcode 1 -> QEMU exits 1.
    if (comptime builtin.is_test) {
        const failed = innigkeit.testing.runner.runAll();
        switch (comptime builtin.cpu.arch) {
            .x86_64 => {
                if (failed == 0) {
                    // ACPI soft power-off: SLP_EN=1, SLP_TYP=7 (S5) -> QEMU exits 0.
                    // Port 0x604 = ICH9 PM1a_CNT_BLK on the QEMU q35 machine.
                    asm volatile ("outw %[val], %[port]"
                        :
                        : [val] "{ax}" (@as(u16, 0x3C00)),
                          [port] "{dx}" (@as(u16, 0x604)),
                    );
                } else {
                    // ISA debug-exit: write 1 -> QEMU exits (1<<1)|1 = 3.
                    asm volatile ("outb %[val], %[port]"
                        :
                        : [val] "{al}" (@as(u8, 1)),
                          [port] "{dx}" (@as(u16, 0xf4)),
                    );
                }
                while (true) asm volatile ("hlt");
            },
            .aarch64 => {
                // AArch64 semihosting SYS_EXIT (0x18): QEMU exits with subcode.
                const subcode: u64 = if (failed == 0) 0 else 1;
                const param align(8) = [2]u64{ 0x20026, subcode }; // ADP_Stopped_ApplicationExit
                asm volatile ("hlt #0xf000"
                    :
                    : [op] "{x0}" (@as(u64, 0x18)),
                      [param] "{x1}" (@intFromPtr(&param)),
                    : .{ .memory = true });
                while (true) asm volatile ("wfe");
            },
            else => @compileError("test exit not implemented for this architecture"),
        }
    }

    log.info("running scheduler benchmark", .{});
    try sched_bench.run();

    log.debug("initializing PCI ECAM", .{});
    try innigkeit.pci.init.initializeECAM();

    log.debug("initializing ACPI", .{});
    try innigkeit.acpi.init.initialize();

    log.debug("initializing virtio-blk driver", .{});
    innigkeit.drivers.virtio.blk.init();

    log.debug("initializing virtio-net driver", .{});
    innigkeit.drivers.virtio.net.init();

    if (innigkeit.drivers.virtio.blk.isBootReady()) {
        var sector: [512]u8 = undefined;
        innigkeit.drivers.virtio.blk.readSectors(0, 0, &sector, 1) catch |err| {
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

    // try innigkeit.init.Output.experimentalRegister(.full);
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

    // Compute AT_PHDR: the virtual address of the phdr table in the loaded image.
    const phdr_vaddr: usize = blk: {
        var iter = header.iterateProgramHeaders(program_header_table);
        while (iter.next()) |phdr| {
            if (phdr.type != .load) continue;
            if (phdr.offset <= header.program_header_offset and
                header.program_header_offset < phdr.offset + phdr.file_size)
            {
                break :blk @intCast(phdr.virtual_address +
                    (header.program_header_offset - phdr.offset));
            }
        }
        break :blk 0;
    };

    try thread.startProcess(entry_point, .{
        .phdr_vaddr = phdr_vaddr,
        .phnum = header.program_header_entry_count,
        .entry = header.entry,
    });
    unreachable;
}
