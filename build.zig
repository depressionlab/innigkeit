const std = @import("std");

const metadata = @import("build.zig.zon");
const Bundle = @import("build/Bundle.zig");
const Options = @import("build/Options.zig");
const App = @import("build/App.zig");
const Wrapper = @import("build/Wrapper.zig");
const Library = @import("build/Library.zig");
const Tool = @import("build/Tool.zig");
const Kernel = @import("build/Kernel.zig");
const RustApp = @import("build/RustApp.zig");
const ImageStep = @import("build/ImageStep.zig");
const QEMU = @import("build/QEMU.zig");

pub fn build(b: *std.Build) !void {
    try disableUnsupportedSteps(b);
    b.enable_qemu = true;

    const architectures: []const Bundle.Architecture = std.meta.tags(Bundle.Architecture);
    const wrapper = try Wrapper.create(b, architectures);
    const options = try Options.get(b, innigkeit_version, architectures);
    const libraries = try Library.getLibraries(b, wrapper, options, architectures);
    const tools = try Tool.getTools(b, wrapper, libraries, options.optimize);
    const apps = try App.getApps(b, wrapper, libraries, options, architectures);

    // Build Rust no_std apps and embed them in the initfs.
    const rust_hello = RustApp.build(b, "rust_hello", "apps/rust_hello");
    const rust_cat = RustApp.build(b, "rust_cat", "apps/rust_cat");
    const rust_echo = RustApp.build(b, "rust_echo", "apps/rust_echo");
    const extra_binaries = [_]Kernel.ExtraBinary{
        .{ .name = rust_hello.name, .binary_path = rust_hello.binary_path, .step = rust_hello.step },
        .{ .name = rust_cat.name, .binary_path = rust_cat.binary_path, .step = rust_cat.step },
        .{ .name = rust_echo.name, .binary_path = rust_echo.binary_path, .step = rust_echo.step },
    };

    const kernels = try Kernel.getKernels(b, wrapper, libraries, options, architectures, apps, tools, &extra_binaries);
    const image_steps = try ImageStep.registerImageSteps(b, kernels, tools, wrapper, options, architectures);

    try QEMU.registerQemuSteps(b, image_steps, options, architectures);

    {
        const native_test_step = b.step("test_native", "Run native (host) unit tests without QEMU");
        for (&[_]struct { name: []const u8, path: []const u8 }{
            .{ .name = "tcp_segment", .path = "src/innigkeit/net/tcp/Segment.zig" },
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
    }

    // Test steps: build a test kernel (builtin.is_test = true), assemble a disk
    // image, and run it in QEMU. Exit code 1 = all tests passed.
    inline for (.{
        .{ .arch = Bundle.Architecture.x64, .name = "test_x64", .desc = "Build test kernel and run unit tests in QEMU (x64)" },
        .{ .arch = Bundle.Architecture.arm, .name = "test_arm", .desc = "Build test kernel and run unit tests in QEMU (arm/AArch64)" },
    }) |entry| {
        const test_kernel = try Kernel.buildTestKernel(b, libraries, options, entry.arch, apps, tools, &extra_binaries);
        const test_image = try ImageStep.buildTestImageStep(b, test_kernel, tools, entry.arch, options);
        const test_qemu = try QEMU.buildTestQemuStep(b, entry.arch, test_image.image_file, options);
        b.step(entry.name, entry.desc).dependOn(&test_qemu.step);
    }
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
    b.default_step.* = std.Build.Step.init(.{
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
