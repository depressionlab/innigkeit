const EmulatorOptions = @This();
const std = @import("std");

uefi: bool,
display: bool,
acpi: bool,
acceleration: bool,
interrupt_details: bool,
cpus: ?usize,
memory: usize,
kaslr: bool,
tpm: bool,
/// Set by the build script (image signed + booted under a Secure-Boot-enrolled
/// OVMF) so the SecureBoot event-log test can assert the measured state is *enabled*.
expect_secure_boot: bool,
/// Wires a UDP hostfwd into the test boot image and brings up virtio-net early
/// enough for `testing/fuzz_channel.test.zig` to reach it.
fuzz_channel: bool,
/// How many descriptors `tools/kernel_fuzz`'s mutation loop drives through the
/// guest per run (`-Dfuzz_iterations=N`). Host-side only, so changing it does
/// not rebuild the kernel.
fuzz_iterations: u32,
/// Pins the mutation loop's PRNG seed (`-Dfuzz_seed=0x...`) so a finding can be
/// replayed; null means a fresh random seed, printed at the start of the run.
fuzz_seed: ?u64,
qemu_monitor: bool,
remote_debug: bool,
wad_path: ?[]const u8,

pub fn get(b: *std.Build) !EmulatorOptions {
    const qemu_monitor = b.option(bool, "monitor", "Enable the QEMU monitor (default: false)") orelse false;
    const remote_debug = b.option(bool, "debug", "Enable remote GDB debugging; disables acceleration and KASLR (default: false)") orelse false;
    const interrupt_details = b.option(bool, "interrupts", "Log detailed QEMU interrupt info; disables acceleration (default: false)") orelse false;
    const acpi = b.option(bool, "acpi", "Enable ACPI in QEMU where supported (default: true)") orelse true;
    const display = b.option(bool, "display", "Open a graphical QEMU display (default: false)") orelse false;
    const uefi = b.option(bool, "uefi", "Run QEMU in UEFI mode (default: true)") orelse true;
    const cpus = b.option(usize, "cpus", "Number of CPU cores to give QEMU (default: 4)");
    const memory = b.option(usize, "memory", "MiB of RAM to give QEMU (default: 512)") orelse 512;
    const kaslr = b.option(bool, "kaslr", "Enable KASLR (default: true, forced false when '-Ddebug' is set)") orelse !remote_debug;
    const tpm = b.option(bool, "tpm", "Run the opt-in TPM 2.0 suite via a build-managed swtpm daemon (default: false)") orelse false;
    const wad_path = b.option([]const u8, "wad", "Path to a WAD file to attach as data disk (e.g. -Dwad=/path/to/doom1.wad)");
    const expect_secure_boot = b.option(bool, "expect_secure_boot", "Assert UEFI Secure Boot is enabled at boot") orelse false;
    const fuzz_channel = b.option(bool, "fuzz_channel", "Run the in-kernel fuzz-channel PoC (x64-only, default: false)") orelse false;
    const fuzz_iterations = b.option(u32, "fuzz_iterations", "Descriptors the -Dfuzz_channel mutation loop drives per run (default: 40)") orelse 40;
    const fuzz_seed: ?u64 = if (b.option([]const u8, "fuzz_seed", "PRNG seed for the -Dfuzz_channel mutation loop, e.g. 0x9a91eaccae2d7158 (default: random, printed)")) |text|
        std.fmt.parseInt(u64, text, 0) catch std.debug.panic("'-Dfuzz_seed' must be an integer (decimal or 0x-prefixed hex), got '{s}'", .{text})
    else
        null;
    if (fuzz_iterations == 0) std.debug.panic("'-Dfuzz_iterations' must be greater than zero!", .{});

    if (cpus) |c| {
        if (c == 0) std.debug.panic("'-Dcpus' must be greater than zero!", .{});
    }

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
        .tpm = tpm,
        .expect_secure_boot = expect_secure_boot,
        .fuzz_channel = fuzz_channel,
        .fuzz_iterations = fuzz_iterations,
        .fuzz_seed = fuzz_seed,
        .uefi = uefi,
        .wad_path = wad_path,
    };
}
