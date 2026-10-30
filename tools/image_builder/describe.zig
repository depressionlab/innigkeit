//! `image_builder describe`: writes the Limine config and the JSON image
//! description for one architecture. Both used to be custom build steps
//! (`LimineConfigStep`/`ImageManifestStep`); they run as a plain `Step.Run`
//! now that Zig 0.17 has no custom steps.
//!
//! Source paths are recorded exactly as given, so the later `image_builder`
//! run must share this run's working directory (the build root).
const std = @import("std");

const ImageDescription = @import("image/ImageDescription.zig");

const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

pub const usage =
    \\Usage: image_builder describe <x64|arm|riscv> <kaslr: 0|1> <kernel> <limine_dir> <manifest_out> <limine_conf_out>
    \\
;

const Architecture = enum { x64, arm, riscv };

pub fn run(arena: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    if (args.len != 6) {
        std.debug.print("incorrect number of arguments given\n\n" ++ usage, .{});
        std.process.exit(1);
    }
    const architecture = std.meta.stringToEnum(Architecture, args[0]) orelse {
        std.debug.print("unknown architecture '{s}'\n\n" ++ usage, .{args[0]});
        std.process.exit(1);
    };
    const kaslr = std.mem.eql(u8, args[1], "1");
    const kernel_path = args[2];
    const limine_dir = args[3];
    const manifest_out = args[4];
    const limine_conf_out = args[5];

    const cwd = std.Io.Dir.cwd();

    try cwd.writeFile(io, .{
        .sub_path = limine_conf_out,
        .data = try limineConfig(arena, io, architecture, kaslr, kernel_path),
    });

    var builder = ImageDescription.Builder.create(arena, 128 * 1024 * 1024); // 128 MiB
    defer builder.deinit();

    if (architecture == .x64) {
        // First partition: bios-boot slot consumed by limine_install.
        _ = try builder.addPartition("bios-boot", 32 * 1024, .none, .bios_boot);
    }

    const efi = try builder.addPartition("EFI", 0, .fat32, .efi); // 0 = expand to fill remainder

    try efi.addFile(.{ .destination_path = "/limine.conf", .source_path = limine_conf_out });
    switch (architecture) {
        .arm => try efi.addFile(.{
            .destination_path = "/EFI/BOOT/BOOTAA64.EFI",
            .source_path = try std.Io.Dir.path.join(arena, &.{ limine_dir, "BOOTAA64.EFI" }),
        }),
        .riscv => try efi.addFile(.{
            .destination_path = "/EFI/BOOT/BOOTRISCV64.EFI",
            .source_path = try std.Io.Dir.path.join(arena, &.{ limine_dir, "BOOTRISCV64.EFI" }),
        }),
        .x64 => {
            try efi.addFile(.{
                .destination_path = "/limine-bios.sys",
                .source_path = try std.Io.Dir.path.join(arena, &.{ limine_dir, "limine-bios.sys" }),
            });
            try efi.addFile(.{
                .destination_path = "/EFI/BOOT/BOOTX64.EFI",
                .source_path = try std.Io.Dir.path.join(arena, &.{ limine_dir, "BOOTX64.EFI" }),
            });
        },
    }
    try efi.addFile(.{ .destination_path = "/kernel", .source_path = kernel_path });

    var out: std.Io.Writer.Allocating = .init(arena);
    try builder.serialize(&out.writer);
    try cwd.writeFile(io, .{ .sub_path = manifest_out, .data = out.written() });
}

fn limineConfig(
    arena: std.mem.Allocator,
    io: std.Io,
    architecture: Architecture,
    kaslr: bool,
    kernel_path: []const u8,
) ![]const u8 {
    const input = try std.Io.Dir.cwd().openFile(io, kernel_path, .{});
    defer input.close(io);

    var reader = input.reader(io, &.{});
    var buf: [4096]u8 = undefined;
    var hashed_writer: std.Io.Writer.Hashing(Blake2b512) = .init(&buf);
    _ = try reader.interface.streamRemaining(&hashed_writer.writer);
    try hashed_writer.writer.flush();

    var kernel_hash: [Blake2b512.digest_length]u8 = undefined;
    hashed_writer.hasher.final(&kernel_hash);

    // Limine verifies a resource when its URI carries a `#<hash>` suffix, where
    // the hash is the file's BLAKE2B-512 as 128 lowercase hex characters.
    // Interpolating the raw digest bytes instead writes 64 non-printable bytes
    // into the path, so Limine fails to open the kernel ("Failed to open
    // executable with path `boot():/kernel...`") and panics before boot.
    const hash_hex = std.fmt.bytesToHex(kernel_hash, .lower);
    const resolution = if (architecture == .arm) "1920x768x32" else "1920x1080x32"; // ramfb limitation
    return arena.print(
        \\ default_entry: 1
        \\ timeout: 0
        \\
        \\ /Innigkeit
        \\     protocol: limine
        \\     kernel_path: boot():/kernel#{s}
        \\     resolution: {s}
        \\     kaslr: {s}
    , .{ hash_hex[0..], resolution, if (kaslr) "auto" else "no" });
}
