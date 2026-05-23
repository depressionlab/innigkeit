const std = @import("std");

const metadata = @import("build.zig.zon");
const Bundle = @import("build/Bundle.zig");
const Options = @import("build/Options.zig");
const App = @import("build/App.zig");
const Wrapper = @import("build/Wrapper.zig");
const Library = @import("build/Library.zig");
const Tool = @import("build/Tool.zig");
const Kernel = @import("build/Kernel.zig");
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
    const kernels = try Kernel.getKernels(b, wrapper, libraries, options, architectures, apps, tools);
    const image_steps = try ImageStep.registerImageSteps(b, kernels, tools, wrapper, options, architectures);

    try QEMU.registerQemuSteps(b, image_steps, options, architectures);

    // Test step: builds a test kernel (builtin.is_test = true), assembles a
    // disk image, and runs it in QEMU with the ISA debug-exit device.
    // Exit code 1 means all tests passed; any other code means failure.
    {
        const test_kernel = try Kernel.buildTestKernel(b, libraries, options, .x64, apps, tools);
        const test_image = try ImageStep.buildTestImageStep(b, test_kernel, tools, .x64, options);
        // const test_qemu = try QEMU.buildTestQemuStep(b, .x64, test_image.image_file, options);
        b.step("test_x64", "Build test kernel and run unit tests in QEMU (x64)").dependOn(&test_image.step);
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
            "your zig version {} does meet the minimum build requirement of {}",
            .{ current_zig, min_zig },
        ));
    }
}
