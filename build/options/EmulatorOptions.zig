const EmulatorOptions = @This();
const std = @import("std");

uefi: bool,
display: bool,
acpi: bool,
acceleration: bool,
interrupt_details: bool,
cpus: usize,
memory: usize,
kaslr: bool,
tpm_socket: ?[]const u8,
qemu_monitor: bool,
remote_debug: bool,
wad_path: []const u8,

pub fn get(b: *std.Build) EmulatorOptions {
    const qemu_monitor = b.option(bool, "monitor", "Enable the QEMU monitor (default: false)") orelse false;
    const remote_debug = b.option(bool, "debug", "Enable remote GDB debugging; disables acceleration and KASLR (default: false)") orelse false;
    const interrupt_details = b.option(bool, "interrupts", "Log detailed QEMU interrupt info; disables acceleration (default: false)") orelse false;
    const acpi = b.option(bool, "acpi", "Enable ACPI in QEMU where supported (default: true)") orelse true;
    const display = b.option(bool, "display", "Open a graphical QEMU display (default: false)") orelse false;
    const uefi = b.option(bool, "uefi", "Run QEMU in UEFI mode (default: true)") orelse true;
    const cpus = b.option(usize, "cpus", "Number of CPU cores to give QEMU (default: 4)") orelse 4;
    const memory = b.option(usize, "memory", "MiB of RAM to give QEMU (default: 512)") orelse 512;
    const kaslr = b.option(bool, "kaslr", "Enable KASLR (default: true, forced false when '-Ddebug' is set)") orelse !remote_debug;
    const tpm_socket = b.option([]const u8, "tpm_socket", "Path to an swtpm socket; omit to run without a TPM");
    const wad_path = b.option([]const u8, "wad", "Path to a WAD file to attach as data disk (e.g. -Dwad=/path/to/doom1.wad)") orelse
        b.path("apps/doom/doom1.wad").getPath2(b, b.default_step);

    if (cpus == 0) std.debug.panic("'-Dcpus' must be greater than zero!", .{});

    // Acceleration logic:
    // - Explicit false -> off, always.
    // - Explicit true -> on, but error if interrupt_details is also set.
    // - Not set -> on unless interrupt_details or remote_debug force it off.
    const acceleration = if (b.option(bool, "acceleration", "Enable KVM/HVF virtualisation acceleration (default: true)")) |explicit| blk: {
        if (explicit and interrupt_details)
            std.debug.panic("'-Dacceleration=true' conflicts with '-Dinterrupts=true'!", .{});
        if (explicit and remote_debug)
            std.debug.print("warning: QEMU acceleration is unreliable with remote debugging\n", .{});
        break :blk explicit;
    } else !(interrupt_details or remote_debug);

    return .{
        .acceleration = acceleration,
        .acpi = acpi,
        .cpus = cpus,
        .display = display,
        .interrupt_details = interrupt_details,
        .kaslr = kaslr,
        .memory = memory,
        .qemu_monitor = qemu_monitor,
        .remote_debug = remote_debug,
        .tpm_socket = tpm_socket,
        .uefi = uefi,
        .wad_path = wad_path,
    };
}
