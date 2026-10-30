//! Assembles a bootable disk image for each architecture.
//!
//! The image pipeline is a chain of `Step.Run`s:
//! ```
//! `image_builder describe` (limine.conf + JSON manifest)
//!     -> `image_builder` tool
//!     -> raw image
//!     -> (x64 only) `limine_install` tool
//!     -> final image
//!     -> install step
//! ```
// zlinter-disable require_errdefer_dealloc - every allocation here goes through b.allocator, an arena for the whole build graph's lifetime; there is no per-allocation free to add.
const ImageStep = @This();

const Bundle = @import("Bundle.zig");
const Kernel = @import("Kernel.zig");
const Options = @import("Options.zig");
const std = @import("std");
const Tool = @import("Tool.zig");
const Wrapper = @import("Wrapper.zig");

pub const Collection = std.hash_map.AutoHashMapUnmanaged(Bundle.Architecture, *ImageStep);

/// Installs `built_file` into the install prefix. A VM boots the installed
/// copy (it may write to its boot disk), never the immutable build-cache one.
install_image: *std.Build.Step.InstallFile,

/// The finished image in the build cache. Read-only: copy it before mutating.
built_file: std.Build.LazyPath,

/// The installed image. Anything that boots it must depend on `install_image`.
image_file: std.Build.LazyPath,

pub fn registerImageSteps(
    b: *std.Build,
    kernels: Kernel.Collection,
    tools: Tool.Collection,
    wrapper: Wrapper,
    options: Options,
    architectures: []const Bundle.Architecture,
) !ImageStep.Collection {
    var image_steps: ImageStep.Collection = .empty;
    try image_steps.ensureTotalCapacity(b.allocator, @intCast(architectures.len));

    for (architectures) |arch| {
        const image_step = try create(b, kernels.get(arch).?, tools, arch, options.emulator.kaslr, "innigkeit");
        wrapper.registerImage(arch, &image_step.install_image.step);
        image_steps.putAssumeCapacityNoClobber(arch, image_step);
    }

    return image_steps;
}

/// Build a single bootable disk image from `kernel` for `arch`.
///
/// Uses `innigkeit_test_{arch}.hdd` as the image name so it doesn't conflict
/// with the regular kernel image. The wrapper is not notified (test images are
/// not part of the normal install graph).
pub fn buildTestImageStep(
    b: *std.Build,
    kernel: Kernel,
    tools: Tool.Collection,
    arch: Bundle.Architecture,
    options: Options, // reserved for future use (e.g. UEFI vs BIOS selection)
) !*ImageStep {
    _ = options;
    return create(b, kernel, tools, arch, false, "innigkeit_test");
}

fn create(
    b: *std.Build,
    kernel: Kernel,
    tools: Tool.Collection,
    arch: Bundle.Architecture,
    kaslr: bool,
    name_prefix: []const u8,
) !*ImageStep {
    const image_builder = tools.get("image_builder").?.debug_exe;
    const limine_dep = b.dependency("limine_bin", .{});
    const image_file_name = b.fmt("{s}_{s}.hdd", .{ name_prefix, @tagName(arch) });

    const describe = b.addRunArtifact(image_builder);
    describe.addArgs(&.{ "describe", @tagName(arch), if (kaslr) "1" else "0" });
    describe.addFileArg(kernel.kernel_binary);
    describe.addDirectoryArg2(limine_dep.path(""), .{});
    const manifest = describe.addOutputFileArg("image_description.json");
    _ = describe.addOutputFileArg("limine.conf");

    const assemble = b.addRunArtifact(image_builder);
    assemble.addFileArg(manifest);
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

    const install_path = b.pathJoin(&.{ @tagName(arch), image_file_name });
    const image_step = try b.allocator.create(ImageStep);
    image_step.* = .{
        .install_image = b.addInstallFile(final_image, install_path),
        .built_file = final_image,
        .image_file = .{ .relative = .{ .base = .install_prefix, .sub_path = install_path } },
    };
    return image_step;
}
