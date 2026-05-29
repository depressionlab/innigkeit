//! Owns all top-level named build steps and wires the dependency graph.
//!
//! Subsystems call the `register*` helpers to attach their artifacts;
//! `Wrapper` handles the fan-in into the correct aggregate steps.
//!
//! Dependency graph wired at construction:
//!
//!   test ──► kernel
//!        ──► library ──► library_host ──► library_host_{arch}...
//!        ──► app     ──► app_host     ──► app_host_{arch}...
//!        ──► internal_app             ──► internal_app_{arch}...
//!        ──► tools   ──► tools_build
//!                    ──► tools_test
//!
//! Note: `image` is intentionally excluded from `test`. Building disk images
//! in CI is expensive and does not affect correctness checks.
const Wrapper = @This();

const std = @import("std");
const Step = std.Build.Step;
const Bundle = @import("Bundle.zig");

const ArchSteps = std.AutoHashMapUnmanaged(Bundle.Architecture, *Step);

/// Steps that build the kernel for each architecture.
kernel_steps: ArchSteps,

/// Steps that assemble the disk image for each architecture.
image_steps: ArchSteps,

/// Steps that build + run external library tests for each architecture.
library_test_steps: ArchSteps,

/// Steps that build applications targeting Innigkeit for each architecture.
internal_app_steps: ArchSteps,

/// Steps that build + run external application tests for each architecture.
external_app_steps: ArchSteps,

/// Builds all host tools.
tools_build_step: *Step,

/// Runs all host tool tests.
tools_test_step: *Step,

/// Compiles everything with `-fno-emit-bin` to verify correctness cheaply.
check_step: *Step,

pub fn create(b: *std.Build, architectures: []const Bundle.Architecture) !Wrapper {
    const check_step = b.step("check", "Compile all code with -fno-emit-bin");
    const test_step = b.step("test", "Run all tests and check all code");
    const kernel_step = b.step("kernel", "Build kernels for all targets");
    const image_step = b.step("image", "Build disk images for all targets");
    const library_step = b.step("library", "Build and run all library tests");
    const library_host_step = b.step("library_host", "Build and run library tests on the host");
    const app_step = b.step("app", "Build and run all application tests");
    const app_host_step = b.step("app_host", "Build and run application tests on the host");
    const internal_app_step = b.step("internal_app", "Build all applications targeting Innigkeit");
    const tools_step = b.step("tools", "Build all tools and run their tests");
    const tools_build_step = b.step("tools_build", "Build all host tools");
    const tools_test_step = b.step("tools_test", "Run all host tool tests");

    test_step.dependOn(kernel_step);
    test_step.dependOn(library_step);
    library_step.dependOn(library_host_step);
    test_step.dependOn(app_step);
    app_step.dependOn(app_host_step);
    test_step.dependOn(internal_app_step);
    test_step.dependOn(tools_step);
    tools_step.dependOn(tools_build_step);
    tools_step.dependOn(tools_test_step);

    return .{
        .check_step = check_step,
        .tools_build_step = tools_build_step,
        .tools_test_step = tools_test_step,
        .kernel_steps = try archStepMap(b, architectures, kernel_step, "kernel_{s}", "Build the kernel for {s}"),
        .image_steps = try archStepMap(b, architectures, image_step, "image_{s}", "Build the disk image for {s}"),
        .library_test_steps = try archStepMap(b, architectures, library_host_step, "library_host_{s}", "Run library tests for {s} on the host"),
        .internal_app_steps = try archStepMap(b, architectures, internal_app_step, "internal_app_{s}", "Build Innigkeit applications for {s}"),
        .external_app_steps = try archStepMap(b, architectures, app_host_step, "app_host_{s}", "Run application tests for {s} on the host"),
    };
}

/// Adds any compile step to the check pass.
pub fn registerCheck(self: Wrapper, exe: anytype) void {
    self.check_step.dependOn(&exe.step);
}

/// Wires a tool's build and test steps into the tools aggregate.
pub fn registerTool(self: Wrapper, build_step: *Step, test_step: *Step) void {
    self.tools_build_step.dependOn(build_step);
    self.tools_test_step.dependOn(test_step);
}

/// Adds a kernel install step for the given architecture.
pub fn registerKernel(self: Wrapper, arch: Bundle.Architecture, step: *Step) void {
    self.kernel_steps.get(arch).?.dependOn(step);
}

/// Adds a disk-image build step for the given architecture.
pub fn registerImage(self: Wrapper, arch: Bundle.Architecture, step: *Step) void {
    self.image_steps.get(arch).?.dependOn(step);
}

/// Adds an external library test step for the given architecture.
pub fn registerLibraryTest(self: Wrapper, arch: Bundle.Architecture, step: *Step) void {
    self.library_test_steps.get(arch).?.dependOn(step);
}

/// Adds an internal (Innigkeit-targeting) application build step for the given architecture.
pub fn registerInternalApp(self: Wrapper, arch: Bundle.Architecture, step: *Step) void {
    self.internal_app_steps.get(arch).?.dependOn(step);
}

/// Adds an external application test step for the given architecture.
pub fn registerExternalApp(self: Wrapper, arch: Bundle.Architecture, step: *Step) void {
    self.external_app_steps.get(arch).?.dependOn(step);
}

/// Creates one step per architecture, registers each under `parent`, and
/// returns the map. `{s}` in the format strings is replaced with the arch tag name.
fn archStepMap(
    b: *std.Build,
    architectures: []const Bundle.Architecture,
    parent: *Step,
    comptime name_fmt: []const u8,
    comptime description_fmt: []const u8,
) !ArchSteps {
    var map: ArchSteps = .empty;

    for (architectures) |arch| {
        const step = b.step(
            b.fmt(name_fmt, .{@tagName(arch)}),
            b.fmt(description_fmt, .{@tagName(arch)}),
        );
        parent.dependOn(step);
        try map.putNoClobber(b.allocator, arch, step);
    }

    return map;
}
