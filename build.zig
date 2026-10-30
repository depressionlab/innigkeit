const std = @import("std");

const App = @import("build/App.zig");
const Bundle = @import("build/Bundle.zig");
const FuzzChannelHarness = @import("build/FuzzChannelHarness.zig");
const ImageStep = @import("build/ImageStep.zig");
const Kernel = @import("build/Kernel.zig");
const Library = @import("build/Library.zig");
const Lint = @import("build/Lint.zig");
const metadata = @import("build.zig.zon");
const Options = @import("build/Options.zig");
const QEMU = @import("build/QEMU.zig");
const RustApp = @import("build/RustApp.zig");
const Tool = @import("build/Tool.zig");
const TpmHarness = @import("build/TpmHarness.zig");
const Verify = @import("build/Verify.zig");
const Wrapper = @import("build/Wrapper.zig");

pub fn build(b: *std.Build) !void {
    try disableUnsupportedSteps(b);
    // TODO: what's the Zig 0.17.0 equivalent? do we need this?
    // b.enable_qemu = true;

    const architectures: []const Bundle.Architecture = std.meta.tags(Bundle.Architecture);
    const wrapper: Wrapper = try .create(b, architectures);
    const options: Options = try .get(b, innigkeit_version, architectures);
    const libraries: Library.Collection = try Library.getLibraries(b, wrapper, options, architectures);
    const tools: Tool.Collection = try Tool.getTools(b, wrapper, libraries, options.optimize);
    const apps: App.Collection = try App.getApps(b, wrapper, libraries, options, architectures);

    // Build Rust no_std apps and embed them in the initfs.
    const rust_hello = try RustApp.build(b, tools.get("build_helper").?.release_safe_exe, "rust_hello");
    const rust_cat = try RustApp.build(b, tools.get("build_helper").?.release_safe_exe, "rust_cat");
    const rust_echo = try RustApp.build(b, tools.get("build_helper").?.release_safe_exe, "rust_echo");
    const extra_binaries = [_]Kernel.ExtraBinary{
        .{ .name = rust_hello.name, .binary = rust_hello.binary, .step = rust_hello.step },
        .{ .name = rust_cat.name, .binary = rust_cat.binary, .step = rust_cat.step },
        .{ .name = rust_echo.name, .binary = rust_echo.binary, .step = rust_echo.step },
    };

    const kernels: Kernel.Collection = try Kernel.getKernels(b, wrapper, libraries, options, architectures, apps, tools, &extra_binaries);
    const image_steps: ImageStep.Collection = try ImageStep.registerImageSteps(b, kernels, tools, wrapper, options, architectures);

    try QEMU.registerQemuSteps(b, image_steps, tools, options, architectures);

    const native_test_step = b.step("test_native", "Run native (host) unit tests without QEMU");
    {
        for (&[_]struct { name: []const u8, path: []const u8 }{
            .{ .name = "elf_raw_header", .path = "src/innigkeit/user/elf/RawHeader.zig" },
            .{ .name = "madt_raw_iterator", .path = "src/innigkeit/acpi/tables/MADTRawIterator.zig" },
            .{ .name = "tcp_segment", .path = "src/innigkeit/network/tcp/Segment.zig" },
            .{ .name = "udp", .path = "src/innigkeit/network/udp.zig" },
            .{ .name = "icmp", .path = "src/innigkeit/network/icmp.zig" },
            .{ .name = "abi_error", .path = "library/innigkeit/Error.zig" },
            .{ .name = "wm_core", .path = "library/innigkeit/wm.test.zig" },
            .{ .name = "xts", .path = "src/innigkeit/crypto/xts.zig" },
            .{ .name = "encrypted_block", .path = "src/innigkeit/crypto/EncryptedBlockDevice.zig" },
            .{ .name = "passphrase_keyslot", .path = "src/innigkeit/crypto/PassphraseKeyslot.zig" },
            .{ .name = "volume_header", .path = "src/innigkeit/filesystem/VolumeHeader.zig" },
            .{ .name = "tpm_kdf", .path = "src/innigkeit/drivers/tpm/kdf.zig" },
            .{ .name = "tpm_session", .path = "src/innigkeit/drivers/tpm/Session.zig" },
            .{ .name = "recovery_flow", .path = "src/innigkeit/recovery.test.zig" },
        }) |entry| {
            const mod = b.createModule(.{ .root_source_file = b.path(entry.path) });
            mod.resolved_target = b.resolveTargetQuery(.{});
            const test_exe = b.addTest(.{
                .name = entry.name,
                .root_module = mod,
            });
            const run = b.addRunArtifact(test_exe);
            native_test_step.dependOn(&run.step);
            wrapper.tools_test_step.dependOn(&run.step);
        }

        // SharedHeader.zig imports `core` (for `core.Size`/`core.testing`), so
        // unlike the bare-module entries above it needs a real import wired in.
        {
            const shared_header_mod = b.createModule(.{
                .root_source_file = b.path("src/innigkeit/acpi/tables/SharedHeader.zig"),
                .imports = &.{
                    .{ .name = "core", .module = libraries.get("core").?.external_module_for_host.? },
                },
            });
            shared_header_mod.resolved_target = b.resolveTargetQuery(.{});
            const test_exe = b.addTest(.{
                .name = "acpi_shared_header",
                .root_module = shared_header_mod,
            });
            const run = b.addRunArtifact(test_exe);
            native_test_step.dependOn(&run.step);
            wrapper.tools_test_step.dependOn(&run.step);
        }
    }

    // Test steps: build a test kernel (builtin.is_test = true), assemble a disk
    // image, and run it in QEMU. Exit code 1 = all tests passed.
    //
    // -Dtpm=true wraps the x64 run specifically in a build-managed swtpm
    // (arm has no TPM driver test path); see `TpmHarness`.
    const tpm_harness: ?TpmHarness = if (options.emulator.tpm) TpmHarness.create(b, "innigkeit-tpm") else null;

    // -Dfuzz_channel=true (see `QEMU.buildTestQemuStep`): x64-only for now,
    // since networking is only x64 at the moment.
    const fuzz_channel_harness: ?FuzzChannelHarness = if (options.emulator.fuzz_channel)
        FuzzChannelHarness.create(
            tools.get("kernel_fuzz").?.normal_exe,
            options.emulator.fuzz_iterations,
            options.emulator.fuzz_seed,
        )
    else
        null;

    var x64_verdict: *std.Build.Step.Run = undefined;
    var arm_verdict: *std.Build.Step.Run = undefined;

    inline for (.{
        .{ .arch = Bundle.Architecture.x64, .name = "test_x64", .desc = "Build test kernel and run unit tests in QEMU (x64)" },
        .{ .arch = Bundle.Architecture.arm, .name = "test_arm", .desc = "Build test kernel and run unit tests in QEMU (arm/AArch64)" },
    }) |entry| {
        const test_kernel = try Kernel.buildTestKernel(b, libraries, options, entry.arch, apps, tools, &extra_binaries);
        const test_image = try ImageStep.buildTestImageStep(b, test_kernel, tools, entry.arch, options);
        const tpm_for_arch: ?TpmHarness = if (entry.arch == .x64) tpm_harness else null;
        const fuzz_channel_for_arch: ?FuzzChannelHarness = if (entry.arch == .x64) fuzz_channel_harness else null;
        var required: std.ArrayList([]const u8) = .empty;
        if (tpm_for_arch != null) try required.append(b.allocator, "pass  testing.tpm");
        if (fuzz_channel_for_arch != null) try required.append(b.allocator, "pass  testing.fuzz_channel");
        if (options.checkpoint_test) try required.append(b.allocator, "pass  testing.checkpoint");
        if (options.fault_inject_block_test) try required.append(b.allocator, "pass  testing.fault_injection_block");
        const test_qemu = try QEMU.buildTestQemuStep(
            b,
            entry.arch,
            test_image,
            tools,
            options,
            required.items,
            tpm_for_arch,
            fuzz_channel_for_arch,
        );
        b.step(entry.name, entry.desc).dependOn(&test_qemu.step);
        b.step("image_" ++ entry.name, "Build the " ++ @tagName(entry.arch) ++ " test image (no QEMU run)").dependOn(&test_image.install_image.step);
        switch (entry.arch) {
            .x64 => x64_verdict = test_qemu,
            .arm => arm_verdict = test_qemu,
            else => {},
        }
    }

    const no_check = b.option(bool, "no_check", "dont check") orelse false;

    try Verify.register(
        b,
        wrapper,
        libraries,
        tools,
        apps,
        &extra_binaries,
        options,
        native_test_step,
        x64_verdict,
        arm_verdict,
        !no_check,
    );

    Lint.register(b);

    const help = b.addRunArtifact(tools.get("build_helper").?.release_safe_exe);
    help.addArgs(&.{ "print", menu_text });
    help.has_side_effects = true;
    help.stdio = .inherit;
    b.step("help", "Show a categorized overview of common commands").dependOn(&help.step);
}

const menu_text =
    \\Innigkeit: capability-based kernel
    \\
    \\Common commands:
    \\
    \\  Getting started
    \\    zig build check                 compile-check everything (fastest signal)
    \\    zig build verify                the verification gate: check + host tests + x64 suite
    \\    zig build verify -Darm=true     also run the arm (AArch64) suite
    \\
    \\  Run
    \\    zig build run_x64               boot in QEMU (x86-64)
    \\    zig build run_arm               boot in QEMU (AArch64)
    \\
    \\  Test
    \\    zig build test_x64              build test kernel + run its suite in QEMU (x64)
    \\    zig build test_arm              same, AArch64
    \\    zig build test_native           host-only unit tests, no QEMU
    \\    zig build verify -Dtpm=true       also run the opt-in TPM 2.0 suite
    \\    zig build verify -Dsecboot=true   also run the opt-in UEFI Secure Boot suite
    \\
    \\  Build
    \\    zig build build_all             real link build for every arch (incl. riscv), no QEMU
    \\    zig build image_x64             build a bootable x86-64 disk image
    \\
    \\  Codesign
    \\    zig build codesign -- keygen     generate keys/codesign_{public,private}.key
    \\    zig build codesign -- sign <elf> <manifest.toml> <out.codesig>
    \\    zig build codesign -- verify <elf> <sig.codesig>
    \\
    \\Apps, libraries, and tools each get their own step (e.g. `zig build core`
    \\builds and runs the `core` library's host tests). For the full flat list:
    \\
    \\    zig build -l
    \\
;

fn disableUnsupportedSteps(b: *std.Build) !void {
    b.install_tls.description = "This step is unsupported by Innigkeit!";
    // Bare `zig build` runs the install step, so its failure shows the menu.
    b.install_tls.step.dependOn(&b.addFail("the 'install' step is unsupported!\n\n" ++ menu_text).step);

    b.uninstall_tls.description = "This step is unsupported by Innigkeit!";
    b.uninstall_tls.step.dependOn(&b.addFail("the 'uninstall' step is unsupported! to list available build targets, run: 'zig build -l'").step);
}

const innigkeit_version = std.SemanticVersion.parse(metadata.version) catch unreachable;

comptime {
    const min_zig = std.SemanticVersion.parse(metadata.minimum_zig_version) catch unreachable;

    if (@import("builtin").zig_version.order(min_zig) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "your zig version {} does not meet the minimum build requirement of {}",
            .{ @import("builtin").zig_version, min_zig },
        ));
    }
}
