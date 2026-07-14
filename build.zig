const std = @import("std");

const App = @import("build/App.zig");
const Bundle = @import("build/Bundle.zig");
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
const VerdictStep = @import("build/VerdictStep.zig");
const Verify = @import("build/Verify.zig");
const Wrapper = @import("build/Wrapper.zig");

pub fn build(b: *std.Build) !void {
    try disableUnsupportedSteps(b);
    b.enable_qemu = true;

    const architectures: []const Bundle.Architecture = std.meta.tags(Bundle.Architecture);
    const wrapper: Wrapper = try .create(b, architectures);
    const options: Options = try .get(b, innigkeit_version, architectures);
    const libraries: Library.Collection = try Library.getLibraries(b, wrapper, options, architectures);
    const tools: Tool.Collection = try Tool.getTools(b, wrapper, libraries, options.optimize);
    const apps: App.Collection = try App.getApps(b, wrapper, libraries, options, architectures);

    // Build Rust no_std apps and embed them in the initfs.
    const rust_hello = try RustApp.build(b, "rust_hello");
    const rust_cat = try RustApp.build(b, "rust_cat");
    const rust_echo = try RustApp.build(b, "rust_echo");
    const extra_binaries = [_]Kernel.ExtraBinary{
        .{ .name = rust_hello.name, .binary_path = rust_hello.binary_path, .step = rust_hello.step },
        .{ .name = rust_cat.name, .binary_path = rust_cat.binary_path, .step = rust_cat.step },
        .{ .name = rust_echo.name, .binary_path = rust_echo.binary_path, .step = rust_echo.step },
    };

    const kernels: Kernel.Collection = try Kernel.getKernels(b, wrapper, libraries, options, architectures, apps, tools, &extra_binaries);
    const image_steps: ImageStep.Collection = try ImageStep.registerImageSteps(b, kernels, tools, wrapper, options, architectures);

    try QEMU.registerQemuSteps(b, image_steps, options, architectures);

    const native_test_step = b.step("test_native", "Run native (host) unit tests without QEMU");
    {
        for (&[_]struct { name: []const u8, path: []const u8 }{
            .{ .name = "elf_raw_header", .path = "src/innigkeit/user/elf/RawHeader.zig" },
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
    // -Dtpm=true wires a build-managed swtpm around the x64 run specifically
    // (arm has no TPM driver test path); the harness is created once here so
    // both this loop and `zig build verify -Dtpm=true` share the same daemon.
    const tpm_harness: ?*TpmHarness = if (options.emulator.tpm_socket) |socket|
        try .create(b, options.emulator.tpm_state_dir.?, socket)
    else
        null;

    var x64_verdict: *VerdictStep = undefined;
    var arm_verdict: *VerdictStep = undefined;

    inline for (.{
        .{ .arch = Bundle.Architecture.x64, .name = "test_x64", .desc = "Build test kernel and run unit tests in QEMU (x64)" },
        .{ .arch = Bundle.Architecture.arm, .name = "test_arm", .desc = "Build test kernel and run unit tests in QEMU (arm/AArch64)" },
    }) |entry| {
        const test_kernel = try Kernel.buildTestKernel(b, libraries, options, entry.arch, apps, tools, &extra_binaries);
        const test_image = try ImageStep.buildTestImageStep(b, test_kernel, tools, entry.arch, options);
        const harness_for_arch: ?*TpmHarness = if (entry.arch == .x64) tpm_harness else null;
        const required: []const []const u8 = if (harness_for_arch != null) &.{"pass  testing.tpm"} else &.{};
        const test_qemu = try QEMU.buildTestQemuStep(b, entry.arch, test_image.image_file, options, required, harness_for_arch);
        const final_step: *std.Build.Step = if (harness_for_arch) |h| &h.stop else &test_qemu.step;
        b.step(entry.name, entry.desc).dependOn(final_step);
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
}

fn disableUnsupportedSteps(b: *std.Build) !void {
    const installMakeFn = struct {
        fn installMakeFn(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
            std.debug.print("the 'install' step is unsupported! to list available build targets, run: 'zig build -l'\n", .{});
            std.process.exit(1);
        }
    }.installMakeFn;

    b.install_tls.description = "This step is unsupported by Innigkeit!";
    b.install_tls.step.makeFn = &installMakeFn;

    const uninstallMakeFn = struct {
        fn uninstallMakeFn(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
            std.debug.print("the 'uninstall' step is unsupported! to list available build targets, run: 'zig build -l'\n", .{});
            std.process.exit(1);
        }
    }.uninstallMakeFn;

    b.uninstall_tls.description = "This step is unsupported by Innigkeit!";
    b.uninstall_tls.step.makeFn = &uninstallMakeFn;

    const defaultMakeFn = struct {
        fn defaultMakeFn(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
            std.debug.print("no build target provided! to list available build targets, run: 'zig build -l'\n", .{});
            std.process.exit(1);
        }
    }.defaultMakeFn;

    b.default_step = try b.allocator.create(std.Build.Step);
    b.default_step.* = .init(.{
        .id = .custom,
        .makeFn = &defaultMakeFn,
        .name = "default step",
        .owner = b,
    });
}

const innigkeit_version = std.SemanticVersion.parse(metadata.version) catch unreachable;

comptime {
    const current_zig = @import("builtin").zig_version;
    const min_zig = std.SemanticVersion.parse(metadata.minimum_zig_version) catch unreachable;

    if (current_zig.order(min_zig) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "your zig version {} does not meet the minimum build requirement of {}",
            .{ current_zig, min_zig },
        ));
    }
}
