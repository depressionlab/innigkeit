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
    // - x64: ISA debug-exit (port 0xf4). write 0 -> QEMU exits 1 (pass),
    //        write 1 -> QEMU exits 3 (fail). Build step expectExitCode(1).
    // - arm: AArch64 semihosting SYS_EXIT subcode 0 (pass) / 1 (fail).
    //        QEMU exits 0 on pass (standard success).
    if (comptime builtin.is_test) {
        // Bring up PCI and the virtio-blk driver so the disk-I/O tests can
        // exercise the real (interrupt-driven) completion path. Any failure
        // just leaves the boot device unavailable and those tests skip.
        if (comptime builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) {
            innigkeit.pci.init.initializeECAM() catch |err|
                log.warn("test setup: PCI ECAM init failed: {t}", .{err});
            innigkeit.drivers.virtio.blk.init();
        }
        // Probe firmware so the EFI System Table tests see the cached table.
        innigkeit.firmware.init();
        // Run the encrypted-volume boot scan so every test boot proves it is
        // safe on a disk with no INNIKVOL header (the GPT boot disk).
        innigkeit.filesystem.EncryptedVolume.mountAtBoot();
        const failed = innigkeit.testing.runner.runAll();
        switch (comptime builtin.cpu.arch) {
            .x86_64 => {
                // ISA debug-exit: write 0 -> QEMU exits (0<<1)|1 = 1 (pass).
                //                 write 1 -> QEMU exits (1<<1)|1 = 3 (fail).
                const exit_val: u8 = if (failed == 0) 0 else 1;
                asm volatile ("outb %[val], %[port]"
                    :
                    : [val] "{al}" (exit_val),
                      [port] "{dx}" (@as(u16, 0xF4)),
                );
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

    log.debug("probing firmware (EFI)", .{});
    innigkeit.firmware.init();

    log.debug("probing for TPM 2.0", .{});
    innigkeit.drivers.tpm.init();

    log.debug("initializing virtio-blk driver", .{});
    innigkeit.drivers.virtio.blk.init();

    log.debug("initializing virtio-net driver", .{});
    innigkeit.drivers.virtio.net.init();
    innigkeit.drivers.virtio.net.setIp(.{ 10, 0, 2, 15 }); // QEMU user-mode default
    try startNetPollThread();

    if (innigkeit.drivers.virtio.blk.isBootReady()) {
        var sector: [512]u8 = undefined;
        innigkeit.drivers.virtio.blk.readSectors(0, 0, &sector, 1) catch |err| {
            log.err("virtio-blk sector read failed: {t}", .{err});
        };
        log.info("virtio-blk sector 0 [0..8]: {x}", .{sector[0..8]});
    } else {
        log.warn("virtio-blk not ready", .{});
    }

    log.debug("probing for an encrypted data volume", .{});
    innigkeit.filesystem.EncryptedVolume.mountAtBoot();

    try innigkeit.time.init.printInitializationTime();

    log.debug("initializing PS/2 keyboard", .{});
    innigkeit.drivers.input.ps2.init() catch |err| {
        log.err("PS/2 keyboard init failed: {t}", .{err});
    };

    log.debug("initializing PS/2 mouse", .{});
    innigkeit.drivers.input.ps2_mouse.init() catch |err| {
        log.err("PS/2 mouse init failed: {t}", .{err});
    };

    log.debug("initializing virtio-gpu", .{});
    // innigkeit.drivers.virtio.gpu.init();

    const initial_app = if (innigkeit.drivers.virtio.gpu.state != null) "wm" else "shell";
    log.debug("starting {s}", .{initial_app});
    const initial_process: *innigkeit.user.Process = try .create(
        .{ .name = try .fromSlice(initial_app) },
    );
    defer initial_process.decrementReferenceCount();

    const initial_thread = if (innigkeit.drivers.virtio.gpu.state != null)
        try initial_process.createThread(.{ .entry = .prepare(loadWm, .{}) })
    else
        try initial_process.createThread(.{ .entry = .prepare(loadShell, .{}) });

    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();
    scheduler_handle.queueTask(&initial_thread.task, .{ .initial = true });
}

fn startNetPollThread() !void {
    const proc: *innigkeit.user.Process = try .create(.{ .name = try .fromSlice("net_poll") });
    defer proc.decrementReferenceCount();
    const thread = try proc.createThread(.{ .entry = .prepare(netPollLoop, .{}) });
    const h: innigkeit.Task.Scheduler.Handle = .get();
    defer h.unlock();
    h.queueTask(&thread.task, .{ .initial = true });
}

fn netPollLoop() !void {
    while (true) {
        // Blocks until the IRQ handler signals received frames; returns
        // false immediately when running in poll-fallback mode.
        const irq_mode = innigkeit.drivers.virtio.net.waitRx();
        innigkeit.drivers.virtio.net.pollRx(innigkeit.network.socket.handleFrame);
        if (!irq_mode) {
            // Poll fallback: yield so a missing IRQ does not busy-spin.
            const h: innigkeit.Task.Scheduler.Handle = .get();
            h.yield();
            h.unlock();
        }
    }
}

fn loadWm() !void {
    try loadElfFromInitfs("wm");
}

fn loadShell() !void {
    try loadElfFromInitfs("shell");
}

fn loadElfFromInitfs(name: []const u8) !noreturn {
    const elf_data = innigkeit.filesystem.initfs.findFile(name) orelse {
        log.err("'{s}' not found in initfs", .{name});
        return error.FileNotFound;
    };

    const current_task: innigkeit.Task.Current = .get();
    const thread: *innigkeit.user.Thread = .from(current_task.task);
    // No codesign check: the initfs itself is the boot-time trust root for
    // the initial shell/WM process (unlike `spawn`, which verifies a
    // `.codesig` sidecar prior to reaching this same load sequence).
    try innigkeit.user.elf.loader.loadAndJump(thread, elf_data, &.{});
    unreachable;
}
