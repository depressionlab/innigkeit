//! Custom build steps that assemble a bootable disk image for each architecture.
//!
//! `ImageStep` wraps an install step and exposes the output path as a
//! `std.Build.LazyPath` so downstream steps (e.g. QEMU) can depend on it
//! without hard-coding output directory layout.
//!
//! The image pipeline is:
//!   `ImageDescriptionStep` (JSON manifest) -> `image_builder` tool -> raw image
//!   -> (x64 only) `limine_install` tool -> final image -> `ImageStep`
const ImageStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const Bundle = @import("Bundle.zig");
const Kernel = @import("Kernel.zig");
const Options = @import("Options.zig");
const Tool = @import("Tool.zig");
const Wrapper = @import("Wrapper.zig");

pub const Collection = std.AutoHashMapUnmanaged(Bundle.Architecture, *ImageStep);
const ImageManifestStep = @import("ImageManifestStep.zig");

step: Step,
install_image: *std.Build.Step.InstallFile,
generated_image_file: std.Build.GeneratedFile,
/// Stable lazy path pointing to the installed image file.
image_file: std.Build.LazyPath,

pub fn registerImageSteps(
    b: *std.Build,
    kernels: Kernel.Collection,
    tools: Tool.Collection,
    wrapper: Wrapper,
    options: Options,
    architectures: []const Bundle.Architecture,
) !ImageStep.Collection {
    const image_builder = tools.get("image_builder").?.release_safe_exe;
    const limine_dep = b.dependency("limine_bin", .{});

    var image_steps: ImageStep.Collection = .empty;
    try image_steps.ensureTotalCapacity(b.allocator, @intCast(architectures.len));

    for (architectures) |arch| {
        const image_file_name = b.fmt("innigkeit_{s}.hdd", .{@tagName(arch)});
        const kernel = kernels.get(arch).?;

        const desc_step = try ImageManifestStep.create(
            b,
            kernel,
            arch,
            limine_dep,
            options.emulator.kaslr,
        );

        const assemble = b.addRunArtifact(image_builder);
        assemble.addFileArg(desc_step.manifest_file);
        const raw_image = assemble.addOutputFileArg(image_file_name);

        // x64 additionally needs the Limine BIOS bootstrap written into the MBR.
        const final_image = if (arch == .x64) blk: {
            const bios_install = b.addRunArtifact(tools.get("limine_install").?.release_safe_exe);
            bios_install.addArgs(&.{ "-p", "1" }); // 1-based partition index of the bios-boot partition
            bios_install.addArg("-i");
            bios_install.addFileArg(raw_image);
            bios_install.addArg("-o");
            break :blk bios_install.addOutputFileArg(image_file_name);
        } else raw_image;

        const install = b.addInstallFile(
            final_image,
            b.pathJoin(&.{ @tagName(arch), image_file_name }),
        );

        const image_step = try b.allocator.create(ImageStep);
        image_step.* = .{
            .install_image = install,
            .step = Step.init(.{
                .id = .custom,
                .name = b.fmt("build {s} image", .{@tagName(arch)}),
                .owner = b,
                .makeFn = resolveImagePath,
            }),
            .generated_image_file = .{ .step = &image_step.step },
            .image_file = .{ .generated = .{
                .file = &image_step.generated_image_file,
            } },
        };
        image_step.step.dependOn(&install.step);

        wrapper.registerImage(arch, &install.step);
        image_steps.putAssumeCapacityNoClobber(arch, image_step);
    }

    return image_steps;
}

/// Resolves the installed image path into `generated_image_file` at make time.
fn resolveImagePath(step: *Step, _: Step.MakeOptions) !void {
    const self: *ImageStep = @fieldParentPtr("step", step);
    self.generated_image_file.path = step.owner.getInstallPath(
        self.install_image.dir,
        self.install_image.dest_rel_path,
    );
}
