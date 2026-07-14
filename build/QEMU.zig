//! Registers `zig build run_{arch}` steps that launch a disk image in QEMU.

const Bundle = @import("Bundle.zig");
const ImageStep = @import("ImageStep.zig");
const Options = @import("Options.zig");
const Platform = @import("Platform.zig");
const std = @import("std");
const TpmHarness = @import("TpmHarness.zig");
const VerdictStep = @import("VerdictStep.zig");

/// For each architecture, creates a step that runs the image for the architecture using QEMU.
pub fn registerQemuSteps(
    b: *std.Build,
    image_steps: ImageStep.Collection,
    options: Options,
    architectures: []const Bundle.Architecture,
) !void {
    for (architectures) |arch| {
        const qemu = try buildQemuCommand(b, arch, image_steps.get(arch).?.image_file, options, .{});
        qemu.addArgs(&.{
            "-device", "virtio-blk-pci,drive=drive1,disable-modern=on,disable-legacy=off",
            "-drive",  b.fmt("file={s},format=raw,if=none,id=drive1,readonly=on", .{options.emulator.wad_path}),
        });
        b.step(
            b.fmt("run_{s}", .{@tagName(arch)}),
            b.fmt("Run the {s} image in QEMU", .{@tagName(arch)}),
        ).dependOn(&qemu.step);
    }
}

pub const CommandOptions = struct {
    /// When non-null, the non-display console output is routed to a
    /// build-tracked log file (instead of the process's own stdio) and
    /// the resulting `LazyPath` is written here so a `VerdictStep` can
    /// scan it.
    log_out: ?*std.Build.LazyPath = null,
    /// When non-null, bypasses the normal uefi/host-firmware auto-detection
    /// below entirely. Used by the Secure Boot suite (`build/Verify.zig`),
    /// which needs an SB-capable OVMF plus a per-run enrolled VARS store,
    /// neither of which fits the plain readonly-both-units UEFI case.
    firmware_override: ?Firmware = null,
    /// When non-null, wraps the QEMU invocation in `timeout <secs>`. Used
    /// by the Secure Boot suite's rejected-boot cases (unsigned/tampered
    /// images): firmware refusing to boot may just sit at an error screen
    /// forever rather than exiting, so a bounded wait is the only way to
    /// tell "rejected as expected" apart from "actually hung".
    timeout_secs: ?u32 = null,
};

pub fn buildQemuCommand(
    b: *std.Build,
    arch: Bundle.Architecture,
    image: std.Build.LazyPath,
    options: Options,
    cmd_opts: CommandOptions,
) !*std.Build.Step.Run {
    const emu = options.emulator;
    const firmware: Firmware = cmd_opts.firmware_override orelse if (emu.uefi or requiresUefi(arch)) uefi: {
        if (Platform.hostFirmware(b, arch)) |host| break :uefi .{ .host_uefi = host };
        if (arch == .arm) std.debug.print("note: host AAVMF not found, falling back to vendored edk2 firmware\n", .{});
        break :uefi .{ .uefi = b.dependency("edk2", .{}) };
    } else .bios;

    const qemu_bin = Platform.findQemuBinary(b, arch);
    const run = if (cmd_opts.timeout_secs) |secs|
        b.addSystemCommand(&.{ "timeout", b.fmt("{d}", .{secs}), qemu_bin })
    else
        b.addSystemCommand(&.{qemu_bin});
    run.has_side_effects = true;
    run.stdio = .inherit;

    run.addArgs(&.{ "-nodefaults", "-no-user-config" });
    run.addArgs(&.{ "-boot", "menu=off" });
    run.addArgs(&.{ "-d", "guest_errors" });
    run.addArgs(&.{ "-m", b.fmt("{d}", .{emu.memory}) });
    run.addArgs(&.{ "-smp", b.fmt("{d}", .{emu.cpus}) });

    // Boot disk (for now we use legacy virtio-blk for simpler I/O register access).
    run.addArgs(&.{ "-device", "virtio-blk-pci,drive=drive0,bootindex=0,disable-modern=on,disable-legacy=off", "-drive" });
    run.addDecoratedDirectoryArg("file=", image, ",format=raw,if=none,id=drive0");

    // Network: user-mode networking (slirp). Guest IP 10.0.2.15, gateway 10.0.2.2.
    run.addArgs(&.{
        "-netdev", "user,id=net0",
        "-device", "virtio-net-pci,netdev=net0,disable-modern=on,disable-legacy=off",
    });

    if (emu.interrupt_details) {
        run.addArgs(&.{ "-d", "int" });
        // Suppress SMM-generated noise before the kernel starts on x64.
        if (arch == .x64) run.addArgs(&.{ "-M", "smm=off" });
    }

    if (emu.remote_debug) run.addArgs(&.{ "-s", "-S" });

    // Display and console routing.
    const host_os = b.graph.host.result.os.tag;
    // virtio-vga-gl on Linux/GTK, plain virtio-vga on macOS/Cocoa.
    const vga_device = if (host_os == .macos) "virtio-vga" else "virtio-vga-gl";
    if (emu.display) {
        run.addArgs(&.{ "-monitor", "vc" });
        run.addArgs(switch (arch) {
            .arm => &.{ "-serial", "vc", "-device", "ramfb" },
            .riscv => &.{ "-serial", "vc", "-device", vga_device },
            .x64 => &.{ "-debugcon", "vc", "-device", vga_device },
        });
        // macOS: use the native Cocoa window (install QEMU via `brew install qemu`).
        // Linux: use GTK with OpenGL for smooth rendering.
        const display_backend: []const u8 = if (host_os == .macos)
            "cocoa"
        else
            "gtk,gl=on,show-tabs=on,zoom-to-fit=off";
        run.addArgs(&.{ "-display", display_backend });
    } else {
        const console_flag: []const u8 = if (arch == .x64) "-debugcon" else "-serial";
        run.addArg(console_flag);
        if (cmd_opts.log_out) |out| {
            out.* = run.addPrefixedOutputFileArg("file:", "test.log");
        } else {
            run.addArg(if (emu.qemu_monitor) "mon:stdio" else "stdio");
        }
        run.addArgs(&.{ "-display", "none" });
    }

    // TODO: CPU model.
    run.addArgs(&.{ "-cpu", switch (arch) {
        .arm => "max",
        .riscv => "max",
        .x64 => "max,migratable=no",
    } });

    // Machine type.
    const acpi_kv: []const u8 = if (emu.acpi) "acpi=on" else "acpi=off";
    if (!emu.acpi and arch == .x64) {
        std.debug.print("ACPI cannot be disabled on x64\n", .{});
        std.process.exit(1);
    }

    run.addArgs(&.{
        "-machine",
        switch (arch) {
            .arm => b.fmt("virt,{s}", .{acpi_kv}),
            .riscv => switch (firmware) {
                .bios => b.fmt("virt,{s}", .{acpi_kv}),
                .uefi => b.fmt("virt,pflash0=pflash0,pflash1=pflash1,{s}", .{acpi_kv}),
                .host_uefi, .secboot_uefi => unreachable, // Platform.hostFirmware is arm-only
            },
            .x64 => "q35",
        },
    });

    // Hardware acceleration.
    if (emu.acceleration and arch.isNative(b)) {
        run.addArgs(&.{ "-accel", switch (b.graph.host.result.os.tag) {
            .linux => "kvm",
            .macos => "hvf",
            .windows => "whpx",
            else => |tag| std.debug.panic("unsupported host OS for acceleration: {s}!", .{@tagName(tag)}),
        } });
    }
    run.addArgs(&.{ "-accel", "tcg" }); // always appended as the fallback accelerator

    // Firmware.
    switch (firmware) {
        .bios => {},
        .uefi => |edk2| switch (arch) {
            .riscv => {
                run.addArg("-blockdev");
                run.addPrefixedFileArg("node-name=pflash0,driver=file,read-only=on,filename=", edk2.path(firmwareCodePath(arch)));
                run.addArg("-blockdev");
                run.addPrefixedFileArg("node-name=pflash1,driver=file,read-only=on,filename=", edk2.path(firmwareVarsPath(arch)));
            },
            .arm, .x64 => {
                run.addArg("-drive");
                run.addPrefixedFileArg("if=pflash,format=raw,unit=0,readonly=on,file=", edk2.path(firmwareCodePath(arch)));
                run.addArg("-drive");
                run.addPrefixedFileArg("if=pflash,format=raw,unit=1,readonly=on,file=", edk2.path(firmwareVarsPath(arch)));
            },
        },
        .host_uefi => |host| {
            run.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,unit=0,readonly=on,file={s}", .{host.code}) });
            run.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,unit=1,readonly=on,file={s}", .{host.vars}) });
        },
        .secboot_uefi => |sb| {
            // vars (unit1) is intentionally NOT readonly: firmware may
            // record state into it, and the whole point is enrolling our
            // own PK/KEK/db beforehand via `tools/secureboot -- enroll`.
            run.addArgs(&.{ "-global", "driver=cfi.pflash01,property=secure,value=on" });
            run.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,unit=0,readonly=on,file={s}", .{sb.code}) });
            run.addArg("-drive");
            run.addPrefixedFileArg("if=pflash,format=raw,unit=1,file=", sb.vars);
        },
    }

    if (emu.tpm_socket) |socket| {
        // CRB interface (PTP), matching drivers/tpm/crb.zig and QEMU's tpm-crb.
        run.addArgs(&.{
            "-chardev", b.fmt("socket,id=chrtpm,path={s}", .{socket}),
            "-tpmdev",  "emulator,id=tpm0,chardev=chrtpm",
            "-device",  "tpm-crb,tpmdev=tpm0",
        });
    }

    return run;
}

/// TODO: adjustable test options (set to 1 to verify single core)
/// aarch64 runs single-core for now: we only have the
/// bootstrap executor for now (AP startup needs PSCI CPU_ON, TODO), so booting
/// extra vCPUs would create executor structs for CPUs that never run and make
/// cross-executor operations (e.g. TLB-flush IPIs) target offline executors
fn testCpus(arch: Bundle.Architecture) u8 {
    return switch (arch) {
        .arm => 1,
        .riscv, .x64 => 4,
    };
}

/// Build a QEMU run step for `test_{arch}`.
///
/// Pass/fail convention:
/// - x64: ISA debug-exit (port 0xf4). write 0 -> QEMU exits 1 (pass),
///        write 1 -> QEMU exits 3 (fail). Step uses expectExitCode(1).
/// - arm: AArch64 semihosting SYS_EXIT subcode 0 (pass) / 1 (fail).
///        QEMU exits 0 on pass; standard exit-0-success applies.
pub fn buildTestQemuStep(
    b: *std.Build,
    arch: Bundle.Architecture,
    image: std.Build.LazyPath,
    options: Options,
    /// Extra substrings the serial log must contain, beyond the plain
    /// pass/fail verdict line (e.g., proof the opt-in TPM suite actually
    /// ran rather than being silently skipped).
    required_substrings: []const []const u8,
    /// When non-null (and `options.emulator.tpm_socket` is set), the run
    /// step depends on `harness.start` and `harness.stop` depends on the
    /// resulting verdict so the caller can fold the whole TPM lifecycle
    /// into whatever step it names as depending on the returned VerdictStep.
    tpm_harness: ?*TpmHarness,
) !*VerdictStep {
    var test_opts = options;
    test_opts.emulator.cpus = testCpus(arch);
    // TODO: determine the best value for this
    test_opts.emulator.memory = 256;
    test_opts.emulator.display = false;
    // TODO: TPM-like security on other arches
    if (arch != .x64) test_opts.emulator.tpm_socket = null;

    var log: std.Build.LazyPath = undefined;
    const run = try buildQemuCommand(b, arch, image, test_opts, .{ .log_out = &log });
    if (tpm_harness) |harness| {
        if (test_opts.emulator.tpm_socket != null)
            run.step.dependOn(&harness.start);
    }

    switch (arch) {
        .x64 => run.addArgs(&.{ "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04" }),
        .arm => run.addArgs(&.{ "-semihosting", "-semihosting-config", "enable=on,target=native" }),
        .riscv => @panic("RISC-V test exit not yet implemented"),
    }

    run.addArg("-no-reboot");
    // buildQemuCommand sets stdio = .inherit; reset so expectExitCode works.
    // With .infer_from_args, output is captured and printed only on failure.
    run.stdio = .infer_from_args;
    switch (arch) {
        .x64 => run.expectExitCode(1), // (0 << 1) | 1 = 1 means all tests passed
        .arm => {}, // semihosting SYS_EXIT subcode 0 -> QEMU exits 0 (default success)
        .riscv => {},
    }
    const verdict = try VerdictStep.create(b, run, log, required_substrings, true);
    if (tpm_harness) |harness| {
        if (test_opts.emulator.tpm_socket != null)
            harness.stop.dependOn(&verdict.step);
    }
    return verdict;
}

/// Returns true for architectures that always require UEFI (no BIOS fallback).
fn requiresUefi(arch: Bundle.Architecture) bool {
    return switch (arch) {
        .arm, .riscv => true,
        .x64 => false,
    };
}

fn firmwareCodePath(arch: Bundle.Architecture) []const u8 {
    return switch (arch) {
        .arm => "aarch64/code.fd",
        .riscv => "riscv64/code.fd",
        .x64 => "x64/code.fd",
    };
}

fn firmwareVarsPath(arch: Bundle.Architecture) []const u8 {
    return switch (arch) {
        .arm => "aarch64/vars.fd",
        .riscv => "riscv64/vars.fd",
        .x64 => "x64/vars.fd",
    };
}

pub const Firmware = union(enum) {
    bios,
    uefi: *std.Build.Dependency,
    host_uefi: Platform.FirmwarePaths,
    /// UEFI Secure Boot-capable firmware: `code` is a static host path,
    /// mapped readonly (the firmware itself); `vars` is a build-generated
    /// per-run enrolled PK/KEK/db copy, mapped writable (the firmware may
    /// update it). Requires the `cfi.pflash01` "secure" property so OVMF
    /// enforces SB at all.
    secboot_uefi: struct { code: []const u8, vars: std.Build.LazyPath },
};
