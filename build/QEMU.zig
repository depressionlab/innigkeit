//! Registers `zig build run_{arch}` steps that launch a disk image in QEMU.
const QEMU = @This();

const std = @import("std");
const Bundle = @import("Bundle.zig");
const ImageStep = @import("ImageStep.zig");
const Options = @import("Options.zig");

/// For each architecture, creates a step that runs the image for the architecture using QEMU.
pub fn registerQemuSteps(
    b: *std.Build,
    image_steps: ImageStep.Collection,
    options: Options,
    architectures: []const Bundle.Architecture,
) !void {
    for (architectures) |arch| {
        const qemu = try buildQemuCommand(b, arch, image_steps.get(arch).?.image_file, options);
        b.step(
            b.fmt("run_{s}", .{@tagName(arch)}),
            b.fmt("Run the {s} image in QEMU", .{@tagName(arch)}),
        ).dependOn(&qemu.step);
    }
}

fn buildQemuCommand(
    b: *std.Build,
    arch: Bundle.Architecture,
    image: std.Build.LazyPath,
    options: Options,
) !*std.Build.Step.Run {
    const emu = options.emulator;
    const firmware: Firmware = if (emu.uefi or requiresUefi(arch))
        .{ .uefi = b.dependency("edk2", .{}) }
    else
        .bios;

    const run = b.addSystemCommand(&.{qemuBinary(arch)});
    run.has_side_effects = true;
    run.stdio = .inherit;

    run.addArgs(&.{ "-nodefaults", "-no-user-config" });
    run.addArgs(&.{ "-boot", "menu=off" });
    run.addArgs(&.{ "-d", "guest_errors" });
    run.addArgs(&.{ "-m", b.fmt("{d}", .{emu.memory}) });
    run.addArgs(&.{ "-smp", b.fmt("{d}", .{emu.cpus}) });

    // Boot disk.
    run.addArgs(&.{ "-device", "virtio-blk-pci,drive=drive0,bootindex=0", "-drive" });
    run.addDecoratedDirectoryArg("file=", image, ",format=raw,if=none,id=drive0");

    if (emu.interrupt_details) {
        run.addArgs(&.{ "-d", "int" });
        // Suppress SMM-generated noise before the kernel starts on x64.
        if (arch == .x64) run.addArgs(&.{ "-M", "smm=off" });
    }

    if (emu.remote_debug) run.addArgs(&.{ "-s", "-S" });

    // Display and console routing.
    if (emu.display) {
        run.addArgs(&.{ "-monitor", "vc" });
        switch (arch) {
            .arm => {
                run.addArgs(&.{ "-serial", "vc", "-device", "ramfb" });
            },
            .riscv => {
                run.addArgs(&.{ "-serial", "vc", "-device", "virtio-vga-gl" });
            },
            .x64 => {
                run.addArgs(&.{ "-debugcon", "vc", "-device", "virtio-vga-gl" });
            },
        }
        run.addArgs(&.{ "-display", "gtk,gl=on,show-tabs=on,zoom-to-fit=off" });
    } else {
        const console_flag: []const u8 = if (arch == .x64) "-debugcon" else "-serial";
        run.addArgs(&.{ console_flag, if (emu.qemu_monitor) "mon:stdio" else "stdio" });
        run.addArgs(&.{ "-display", "none" });
    }

    // CPU model.
    switch (arch) {
        .arm => run.addArgs(&.{ "-cpu", "cortex-a76" }),
        .riscv => run.addArgs(&.{ "-cpu", "max" }),
        .x64 => run.addArgs(&.{ "-cpu", "max,migratable=no" }),
    }

    // Machine type.
    const acpi_kv: []const u8 = if (emu.acpi) "acpi=on" else "acpi=off";
    switch (arch) {
        .arm => run.addArgs(&.{ "-machine", b.fmt("virt,{s}", .{acpi_kv}) }),
        .riscv => run.addArgs(&.{ "-machine", switch (firmware) {
            .bios => b.fmt("virt,{s}", .{acpi_kv}),
            .uefi => b.fmt("virt,pflash0=pflash0,pflash1=pflash1,{s}", .{acpi_kv}),
        } }),
        .x64 => {
            if (!emu.acpi) {
                std.debug.print("ACPI cannot be disabled on x64\n", .{});
                std.process.exit(1);
            }
            run.addArgs(&.{ "-machine", "q35" });
        },
    }

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
    }

    if (emu.tpm_socket) |socket| {
        run.addArgs(&.{
            "-chardev", b.fmt("socket,id=chrtpm,path={s}", .{socket}),
            "-tpmdev",  "emulator,id=tpm0,chardev=chrtpm",
            "-device",  "tpm-tis,tpmdev=tpm0",
        });
    }

    return run;
}

/// Returns true for architectures that always require UEFI (no BIOS fallback).
fn requiresUefi(arch: Bundle.Architecture) bool {
    return switch (arch) {
        .arm, .riscv => true,
        .x64 => false,
    };
}

fn qemuBinary(arch: Bundle.Architecture) []const u8 {
    return switch (arch) {
        .arm => "qemu-system-aarch64",
        .riscv => "qemu-system-riscv64",
        .x64 => "qemu-system-x86_64",
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

const Firmware = union(enum) {
    bios,
    uefi: *std.Build.Dependency,
};
