//! A custom build step that produces the JSON image description consumed by
//! the `image_builder` tool. The output is content-addressed and cached.
const ImageManifestStep = @This();

const std = @import("std");
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const Step = std.Build.Step;

const Bundle = @import("Bundle.zig");
const Kernel = @import("Kernel.zig");
const LimineConfigStep = @import("LimineConfigStep.zig");

step: Step,

architecture: Bundle.Architecture,
generated_manifest_file: std.Build.GeneratedFile,
/// Stable lazy path pointing to the cached JSON manifest.
manifest_file: std.Build.LazyPath,
kernel: Kernel,
limine_dep: *std.Build.Dependency,
limine_conf: *LimineConfigStep,

pub fn create(
    owner: *std.Build,
    kernel: Kernel,
    architecture: Bundle.Architecture,
    limine_dep: *std.Build.Dependency,
    kaslr: bool,
) !*ImageManifestStep {
    const limine_config_step = try LimineConfigStep.create(owner, kernel, architecture, kaslr);
    const self = try owner.allocator.create(ImageManifestStep);
    self.* = .{
        .kernel = kernel,
        .limine_dep = limine_dep,
        .limine_conf = limine_config_step,
        .step = .init(.{
            .id = .custom,
            .name = owner.fmt("generate {s} image manifest", .{@tagName(architecture)}),
            .owner = owner,
            .makeFn = make,
        }),
        .architecture = architecture,
        .generated_manifest_file = .{ .step = &self.step },
        .manifest_file = .{ .generated = .{ .file = &self.generated_manifest_file } },
    };

    self.step.dependOn(kernel.install_step);
    self.step.dependOn(&limine_config_step.step);

    return self;
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    const b = step.owner;
    const io = b.graph.io;

    const self: *ImageManifestStep = @fieldParentPtr("step", step);
    const start_time: std.Io.Timestamp = .now(io, .real);

    const node = options.progress_node.start("generate image_description.json", 1);
    defer {
        node.end();
        step.result_duration_ns = @intCast(start_time.durationTo(.now(io, .real)).toNanoseconds());
    }

    const manifest_bytes = try self.buildManifest();

    // Content-address the manifest so unchanged images are a cache hit.
    var hash = b.graph.cache.hash;
    hash.add(@as(u32, 0xde92a821)); // bump this if the serialisation format changes
    hash.addBytes(manifest_bytes);
    const sub_path =
        "innigkeit" ++ std.fs.path.sep_str ++
        "idesc" ++ std.fs.path.sep_str ++
        hash.final() ++ std.fs.path.sep_str ++
        "image_description.json";

    self.generated_manifest_file.path = try b.cache_root.join(b.allocator, &.{sub_path});

    if (b.cache_root.handle.access(io, sub_path, .{})) |_| {
        step.result_cached = true;
        return;
    } else |outer_err| switch (outer_err) {
        std.Io.Dir.AccessError.FileNotFound => {
            const sub_dir = std.fs.path.dirname(sub_path).?;
            b.cache_root.handle.createDirPath(io, sub_dir) catch |e|
                return step.fail("unable to create cache directory '{f}{s}': {t}", .{ b.cache_root, sub_dir, e });

            var rand: u64 = undefined;
            io.random(std.mem.asBytes(&rand));
            const tmp = "tmp" ++ std.fs.path.sep_str ++ std.fmt.hex(rand) ++ std.fs.path.sep_str ++ "image_description.json";
            const tmp_dir = std.fs.path.dirname(tmp).?;

            b.cache_root.handle.createDirPath(io, tmp_dir) catch |e|
                return step.fail("unable to create temp directory '{f}{s}': {t}", .{ b.cache_root, tmp_dir, e });

            b.cache_root.handle.writeFile(io, .{ .sub_path = tmp, .data = manifest_bytes }) catch |e|
                return step.fail("unable to write manifest to '{f}{s}': {t}", .{ b.cache_root, tmp, e });

            b.cache_root.handle.rename(tmp, b.cache_root.handle, sub_path, io) catch |e|
                return step.fail("unable to rename '{f}{s}' -> '{f}{s}': {t}", .{
                    b.cache_root, tmp,
                    b.cache_root, sub_path,
                    e,
                });
        },
        else => |e| return step.fail("unable to access cache file '{f}{s}': {t}", .{ b.cache_root, sub_path, e }),
    }
}

const ImageDescription = @import("../tools/image_builder/image/ImageDescription.zig");

fn buildManifest(self: *ImageManifestStep) ![]const u8 {
    const b = self.step.owner;
    var builder = ImageDescription.Builder.create(b.allocator, 64 * 1024 * 1024); // 64 MiB
    defer builder.deinit();

    if (self.architecture == .x64) {
        // First partition: bios-boot slot consumed by limine_install.
        _ = try builder.addPartition("bios-boot", 32 * 1024, .none, .bios_boot);
    }

    const efi = try builder.addPartition("EFI", 0, .fat32, .efi); // 0 = expand to fill remainder

    try efi.addFile(.{
        .destination_path = "/limine.conf",
        .source_path = self.limine_conf.limine_conf
            .getPath2(self.step.owner, &self.step),
    });

    switch (self.architecture) {
        .arm => try efi.addFile(.{
            .destination_path = "/EFI/BOOT/BOOTAA64.EFI",
            .source_path = self.limine_dep.path("BOOTAA64.EFI")
                .getPath2(b, &self.step),
        }),
        .riscv => try efi.addFile(.{
            .destination_path = "/EFI/BOOT/BOOTRISCV64.EFI",
            .source_path = self.limine_dep.path("BOOTRISCV64.EFI")
                .getPath2(b, &self.step),
        }),
        .x64 => {
            try efi.addFile(.{
                .destination_path = "/limine-bios.sys",
                .source_path = self.limine_dep.path("limine-bios.sys")
                    .getPath2(b, &self.step),
            });
            try efi.addFile(.{
                .destination_path = "/EFI/BOOT/BOOTX64.EFI",
                .source_path = self.limine_dep.path("BOOTX64.EFI")
                    .getPath2(b, &self.step),
            });
        },
    }

    try efi.addFile(.{
        .destination_path = "/kernel",
        .source_path = self.kernel.kernel_binary
            .getPath2(b, &self.step),
    });

    var out: std.Io.Writer.Allocating = .init(b.allocator);
    errdefer out.deinit();
    try builder.serialize(&out.writer);
    return try out.toOwnedSlice();
}
