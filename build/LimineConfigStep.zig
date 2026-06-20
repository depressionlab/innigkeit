const LimineConfigStep = @This();

const std = @import("std");
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const Step = std.Build.Step;

const Bundle = @import("Bundle.zig");
const Kernel = @import("Kernel.zig");

step: Step,

architecture: Bundle.Architecture,
kernel: Kernel,
generated_limine_conf: std.Build.GeneratedFile,
limine_conf: std.Build.LazyPath,
kaslr: bool,

pub fn create(
    owner: *std.Build,
    kernel: Kernel,
    arch: Bundle.Architecture,
    kaslr: bool,
) !*LimineConfigStep {
    const self = try owner.allocator.create(LimineConfigStep);
    self.* = .{
        .kernel = kernel,
        .step = .init(.{
            .id = .custom,
            .name = owner.fmt("generate {s} limine config", .{@tagName(arch)}),
            .owner = owner,
            .makeFn = make,
        }),
        .architecture = arch,
        .kaslr = kaslr,
        .generated_limine_conf = .{ .step = &self.step },
        .limine_conf = .{ .generated = .{ .file = &self.generated_limine_conf } },
    };

    self.step.dependOn(kernel.install_step);

    return self;
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    const b = step.owner;
    const io = b.graph.io;

    const self: *LimineConfigStep = @fieldParentPtr("step", step);
    const start_time: std.Io.Timestamp = .now(io, .real);

    const node = options.progress_node.start("generate image_description.json", 1);
    defer {
        node.end();
        step.result_duration_ns = @intCast(start_time.durationTo(.now(io, .real)).toNanoseconds());
    }

    const kernel_path = self.kernel.kernel_binary.getPath3(b, step);
    const input = try kernel_path.root_dir.handle.openFile(b.graph.io, kernel_path.sub_path, .{});
    defer input.close(b.graph.io);

    var reader = input.reader(b.graph.io, &.{});
    var buf: [4096]u8 = undefined;
    var hashed_writer: std.Io.Writer.Hashing(Blake2b512) = .init(&buf);
    _ = try reader.interface.streamRemaining(&hashed_writer.writer);
    try hashed_writer.writer.flush();

    var kernel_hash: [Blake2b512.digest_length]u8 = undefined;
    hashed_writer.hasher.final(&kernel_hash);

    const resolution = if (self.architecture == .arm) "1920x768x32" else "1920x1080x32"; // ramfb limitation
    const cfg_kaslr = if (self.kaslr) "auto" else "no";
    const limine_bytes = generateLimineConfig(b, kernel_hash, resolution, cfg_kaslr);

    // Content-address the limine.conf so unchanged images are a cache hit.
    var hash = b.graph.cache.hash;
    hash.add(@as(u32, 0xde92a821)); // bump this if the limine conf changes
    hash.addBytes(limine_bytes);
    const sub_path =
        "innigkeit" ++ std.fs.path.sep_str ++
        "limine" ++ std.fs.path.sep_str ++
        hash.final() ++ std.fs.path.sep_str ++
        "limine.conf";

    self.generated_limine_conf.path = try b.cache_root.join(b.allocator, &.{sub_path});

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
            const tmp = "tmp" ++ std.fs.path.sep_str ++ std.fmt.hex(rand) ++ std.fs.path.sep_str ++ "limine.conf";
            const tmp_dir = std.fs.path.dirname(tmp).?;

            b.cache_root.handle.createDirPath(io, tmp_dir) catch |e|
                return step.fail("unable to create temp directory '{f}{s}': {t}", .{ b.cache_root, tmp_dir, e });

            b.cache_root.handle.writeFile(io, .{ .sub_path = tmp, .data = limine_bytes }) catch |e|
                return step.fail("unable to write limine.conf to '{f}{s}': {t}", .{ b.cache_root, tmp, e });

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

fn generateLimineConfig(
    b: *std.Build,
    hash: [Blake2b512.digest_length]u8,
    resolution: []const u8,
    kaslr: []const u8,
) []const u8 {
    return b.fmt(
        \\ default_entry: 1
        \\ timeout: 0
        \\
        \\ /Innigkeit
        \\     protocol: limine
        \\     kernel_path: boot():/kernel{s}
        \\     resolution: {s}
        \\     kaslr: {s}
    ,
        .{ hash[0..], resolution, kaslr },
    );
}
