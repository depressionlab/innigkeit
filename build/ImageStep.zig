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

/// A custom build step that produces the JSON image description consumed by
/// the `image_builder` tool. The output is content-addressed and cached.
const ImageManifestStep = struct {
    b: *std.Build,
    step: Step,
    architecture: Bundle.Architecture,
    /// Path to the limine.conf file selected for this architecture and KASLR setting.
    limine_conf: []const u8,
    generated_manifest_file: std.Build.GeneratedFile,
    /// Stable lazy path pointing to the cached JSON manifest.
    manifest_file: std.Build.LazyPath,
    kernel: Kernel,
    limine_dep: *std.Build.Dependency,

    fn create(
        b: *std.Build,
        kernel: Kernel,
        arch: Bundle.Architecture,
        limine_dep: *std.Build.Dependency,
        kaslr: bool,
    ) !*ImageManifestStep {
        const limine_conf = switch (arch) {
            .arm => if (kaslr) b.pathJoin(&.{ "build", "limine_ramfb.conf" }) else b.pathJoin(&.{ "build", "limine_no_kaslr_ramfb.conf" }),
            .riscv, .x64 => if (kaslr) b.pathJoin(&.{ "build", "limine.conf" }) else b.pathJoin(&.{ "build", "limine_no_kaslr.conf" }),
        };

        const self = try b.allocator.create(ImageManifestStep);
        self.* = .{
            .b = b,
            .kernel = kernel,
            .limine_dep = limine_dep,
            .limine_conf = limine_conf,
            .step = Step.init(.{
                .id = .custom,
                .name = b.fmt("generate {s} image manifest", .{@tagName(arch)}),
                .owner = b,
                .makeFn = make,
            }),
            .architecture = arch,
            .generated_manifest_file = .{ .step = &self.step },
            .manifest_file = .{ .generated = .{ .file = &self.generated_manifest_file } },
        };

        // TODO: limine.conf is not tracked as a proper build input yet.
        try self.step.addWatchInput(b.path(limine_conf));
        self.step.dependOn(kernel.install_step);

        return self;
    }

    fn make(step: *Step, options: Step.MakeOptions) !void {
        const self: *ImageManifestStep = @fieldParentPtr("step", step);
        const io = step.owner.graph.io;
        const start_time: std.Io.Timestamp = .now(io, .real);

        const node = options.progress_node.start("generate image_description.json", 1);
        defer {
            node.end();
            step.result_duration_ns = @intCast(start_time.durationTo(.now(io, .real)).toNanoseconds());
        }

        const manifest_bytes = try self.buildManifest();

        // Content-address the manifest so unchanged images are a cache hit.
        var hash = self.b.graph.cache.hash;
        hash.add(@as(u32, 0xde92a821)); // bump this if the serialisation format changes
        hash.addBytes(manifest_bytes);
        const sub_path =
            "innigkeit" ++ std.fs.path.sep_str ++
            "idesc" ++ std.fs.path.sep_str ++
            hash.final() ++ std.fs.path.sep_str ++
            "image_description.json";

        self.generated_manifest_file.path = try self.b.cache_root.join(self.b.allocator, &.{sub_path});

        if (self.b.cache_root.handle.access(io, sub_path, .{})) |_| {
            step.result_cached = true;
            return;
        } else |outer_err| switch (outer_err) {
            error.FileNotFound => {
                const sub_dir = std.fs.path.dirname(sub_path).?;
                self.b.cache_root.handle.createDirPath(io, sub_dir) catch |e|
                    return step.fail("unable to create cache directory '{f}{s}': {t}", .{ self.b.cache_root, sub_dir, e });

                var rand: u64 = undefined;
                io.random(std.mem.asBytes(&rand));
                const tmp = "tmp" ++ std.fs.path.sep_str ++ std.fmt.hex(rand) ++ std.fs.path.sep_str ++ "image_description.json";
                const tmp_dir = std.fs.path.dirname(tmp).?;

                self.b.cache_root.handle.createDirPath(io, tmp_dir) catch |e|
                    return step.fail("unable to create temp directory '{f}{s}': {t}", .{ self.b.cache_root, tmp_dir, e });

                self.b.cache_root.handle.writeFile(io, .{ .sub_path = tmp, .data = manifest_bytes }) catch |e|
                    return step.fail("unable to write manifest to '{f}{s}': {t}", .{ self.b.cache_root, tmp, e });

                self.b.cache_root.handle.rename(tmp, self.b.cache_root.handle, sub_path, io) catch |e|
                    return step.fail("unable to rename '{f}{s}' → '{f}{s}': {t}", .{
                        self.b.cache_root, tmp,
                        self.b.cache_root, sub_path,
                        e,
                    });
            },
            else => |e| return step.fail("unable to access cache file '{f}{s}': {t}", .{ self.b.cache_root, sub_path, e }),
        }
    }

    const ImageDescription = @import("../tools/image_builder/ImageDescription.zig");

    fn buildManifest(self: *ImageManifestStep) ![]const u8 {
        var builder = ImageDescription.Builder.create(self.b.allocator, 64 * 1024 * 1024); // 64 MiB
        defer builder.deinit();

        if (self.architecture == .x64) {
            // First partition: bios-boot slot consumed by limine_install.
            _ = try builder.addPartition("bios-boot", 32 * 1024, .none, .bios_boot);
        }

        const efi = try builder.addPartition("EFI", 0, .fat32, .efi); // 0 = expand to fill remainder

        try efi.addFile(.{ .destination_path = "/limine.conf", .source_path = self.limine_conf });

        switch (self.architecture) {
            .arm => try efi.addFile(.{
                .destination_path = "/EFI/BOOT/BOOTAA64.EFI",
                .source_path = self.limine_dep.path("BOOTAA64.EFI").getPath2(self.b, &self.step),
            }),
            .riscv => try efi.addFile(.{
                .destination_path = "/EFI/BOOT/BOOTRISCV64.EFI",
                .source_path = self.limine_dep.path("BOOTRISCV64.EFI").getPath2(self.b, &self.step),
            }),
            .x64 => {
                try efi.addFile(.{
                    .destination_path = "/limine-bios.sys",
                    .source_path = self.limine_dep.path("limine-bios.sys")
                        .getPath2(self.b, &self.step),
                });
                try efi.addFile(.{
                    .destination_path = "/EFI/BOOT/BOOTX64.EFI",
                    .source_path = self.limine_dep.path("BOOTX64.EFI")
                        .getPath2(self.b, &self.step),
                });
            },
        }

        try efi.addFile(.{
            .destination_path = "/kernel",
            .source_path = self.kernel.kernel_binary.getPath(self.b),
        });

        var out: std.Io.Writer.Allocating = .init(self.b.allocator);
        errdefer out.deinit();
        try builder.serialize(&out.writer);
        return try out.toOwnedSlice();
    }
};
