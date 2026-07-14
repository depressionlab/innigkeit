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
/// Collect the opt-in TPM test suite only when `-Dtpm=true` is set, so the
/// default baseline is stable. The socket path is a deterministic location
/// under the build cache; `build/TpmHarness.zig` owns spawning/killing the
/// `swtpm` daemon that listens on it.
tpm_socket: ?[]const u8,
/// Parent directory of `tpm_socket` (also `swtpm`'s `--tpmstate dir=`); null
/// iff `tpm_socket` is null.
tpm_state_dir: ?[]const u8,
/// Set by the build script (image signed + booted under a Secure-Boot-enrolled
/// OVMF) so the SecureBoot event-log test can assert the measured state is *enabled*.
expect_secure_boot: bool,
qemu_monitor: bool,
remote_debug: bool,
wad_path: []const u8,

pub fn get(b: *std.Build) !EmulatorOptions {
    const qemu_monitor = b.option(bool, "monitor", "Enable the QEMU monitor (default: false)") orelse false;
    const remote_debug = b.option(bool, "debug", "Enable remote GDB debugging; disables acceleration and KASLR (default: false)") orelse false;
    const interrupt_details = b.option(bool, "interrupts", "Log detailed QEMU interrupt info; disables acceleration (default: false)") orelse false;
    const acpi = b.option(bool, "acpi", "Enable ACPI in QEMU where supported (default: true)") orelse true;
    const display = b.option(bool, "display", "Open a graphical QEMU display (default: false)") orelse false;
    const uefi = b.option(bool, "uefi", "Run QEMU in UEFI mode (default: true)") orelse true;
    const cpus = b.option(usize, "cpus", "Number of CPU cores to give QEMU (default: 4)") orelse 4;
    const memory = b.option(usize, "memory", "MiB of RAM to give QEMU (default: 512)") orelse 512;
    const kaslr = b.option(bool, "kaslr", "Enable KASLR (default: true, forced false when '-Ddebug' is set)") orelse !remote_debug;
    const tpm = b.option(bool, "tpm", "Run the opt-in TPM 2.0 suite via a build-managed swtpm daemon (default: false)") orelse false;
    const tpm_state_dir: ?[]const u8 = if (tpm) try b.cache_root.join(b.allocator, &.{ "tmp", "innigkeit-tpm" }) else null;
    const tpm_socket: ?[]const u8 = if (tpm_state_dir) |dir| b.pathJoin(&.{ dir, "sock" }) else null;
    const wad_path = b.option([]const u8, "wad", "Path to a WAD file to attach as data disk (e.g. -Dwad=/path/to/doom1.wad)") orelse wad: {
        const p = try b.path("apps/doom/doom1.wad").getPath4(b, b.default_step);
        break :wad b.pathResolve(&.{ p.root_dir.path orelse ".", p.sub_path });
    };
    const expect_secure_boot = b.option(bool, "expect_secure_boot", "Assert UEFI Secure Boot is enabled at boot") orelse false;

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
        .tpm_state_dir = tpm_state_dir,
        .expect_secure_boot = expect_secure_boot,
        .uefi = uefi,
        .wad_path = wad_path,
    };
}
