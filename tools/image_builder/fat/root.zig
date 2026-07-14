const std = @import("std");

const core = @import("core");
const filesystem = @import("filesystem");

const ImageDescription = @import("../image/ImageDescription.zig");
const root = @import("../main.zig");

pub const Context = @import("Context.zig");
pub const DateTime = @import("DateTime.zig");
pub const Directory = @import("Directory.zig");
pub const Name = @import("Name.zig");

pub fn create(allocator: std.mem.Allocator, io: std.Io, partition: ImageDescription.Partition, slice: []u8) !void {
    const sector_size = root.disk_block_size;

    const root_cluster = 2;
    const number_of_fat = 2;
    const sectors_per_fat = 0x3F1; // TODO: Why 1009?
    const sectors_per_cluster = 1;
    const sectors_per_track = 32;
    const number_of_heads = 16;
    const fsinfo_sector = 1;
    const reserved_sectors = sectors_per_track; // TODO: Is it always one track reserved?

    const number_of_sectors = core.Size.from(slice.len, .byte).divide(sector_size);
    const number_of_clusters: u32 = @intCast(number_of_sectors / sectors_per_cluster);

    const bpb = root.asPtr(*filesystem.fat.BPB, slice, 0, sector_size);
    bpb.* = filesystem.fat.BPB{
        .oem_identifier = [_]u8{ 'C', 'A', 'S', 'C', 'A', 'D', 'E', 0 },
        .bytes_per_sector = @intCast(sector_size.value),
        .sectors_per_cluster = sectors_per_cluster,
        .reserved_sectors = reserved_sectors,
        .number_of_fats = number_of_fat,
        .number_of_root_directory_entries = 0,
        .number_of_sectors = 0,
        .media_descriptor_type = .fixed_disk,
        .sectors_per_fat = 0,
        .sectors_per_track = sectors_per_track,
        .number_of_heads = number_of_heads,
        .number_of_hidden_sectors = 0x800,
        .large_sector_count = @intCast(number_of_sectors),
    };

    // `ExtendedBPB_32` is the on-disk FAT32 layout immediately following BPB;
    // `bpb` points into `slice`, which is sized for at least one whole sector.
    const ebpb: *filesystem.fat.ExtendedBPB_32 = @ptrFromInt(@intFromPtr(bpb) + @sizeOf(filesystem.fat.BPB));
    ebpb.* = filesystem.fat.ExtendedBPB_32{
        .sectors_per_fat = sectors_per_fat,
        .flags = .{
            .active_fat = 0,
            .mode = .each_fat_active_and_mirrored,
        },
        .version = 0,
        .root_cluster = root_cluster,
        .fsinfo_sector = fsinfo_sector,
        .backup_boot_sector = 0x6,
        .drive_number = 0x80,
        .extended_boot_signature = 0x29,
        .volume_id = 0xA96B2625, // TODO
        .volume_label = [_]u8{ 'N', 'O', ' ', 'N', 'A', 'M', 'E', ' ', ' ', ' ', ' ' }, // TODO
    };
    const boot_code_ptr: *@TypeOf(ebpb_boot_code) = @ptrCast(&ebpb.boot_code);
    boot_code_ptr.* = ebpb_boot_code;

    const fsinfo = root.asPtr(*filesystem.fat.FSInfo, slice, fsinfo_sector, sector_size);
    fsinfo.* = .{
        .last_known_number_of_free_clusters = 0xFFFFFFFF,
        .most_recently_allocated_cluster = 0xFFFFFFFF,
    };

    const size_of_info = core.Size.from(
        @sizeOf(filesystem.fat.BPB) + @sizeOf(filesystem.fat.ExtendedBPB_32) + @sizeOf(filesystem.fat.FSInfo),
        .byte,
    );

    const four_kib_alignment = core.Size.from(4, .kib).toAlignment();

    const padding_before_backup_info = size_of_info
        .alignForward(four_kib_alignment)
        .subtract(size_of_info);

    @memcpy(
        slice[padding_before_backup_info.value..][0..size_of_info.value],
        slice[0..size_of_info.value],
    );

    const fat_begin = reserved_sectors;
    const number_of_fat_entries = (sectors_per_fat * sector_size.value) / 4;

    const cluster_begin_sector = reserved_sectors + (number_of_fat * sectors_per_fat);

    var context = Context.init(
        io,
        slice,
        fat_begin,
        number_of_fat_entries,
        sector_size,
        root_cluster,
        sectors_per_cluster,
        cluster_begin_sector,
        number_of_clusters,
    );

    // BPB media in lower byte and all ones elsewhere
    context.setFAT(0, @enumFromInt(0xFFFFF00 | @as(u32, @intFromEnum(bpb.media_descriptor_type))));

    // Reserved entry
    context.setFAT(1, @enumFromInt(0xFFFFFFF));

    // Root directory end of chain
    context.setFAT(root_cluster, filesystem.fat.FAT32Entry.end_of_chain);

    try addFilesAndDirectoriesToFAT(&context, allocator, partition);

    const backup_fat_table: []filesystem.fat.FAT32Entry = root.asPtr(
        [*]filesystem.fat.FAT32Entry,
        slice,
        fat_begin + sectors_per_fat,
        sector_size,
    )[0..number_of_fat_entries];

    @memcpy(backup_fat_table, context.fat_table);
}

fn addFilesAndDirectoriesToFAT(context: *Context, allocator: std.mem.Allocator, partition: ImageDescription.Partition) !void {
    for (partition.entries) |entry| {
        switch (entry) {
            .file => |file| {
                const parent_dir_path = std.Io.Dir.path.dirname(file.destination_path) orelse {
                    std.debug.panic("file entry with invalid destination path: '{s}'!", .{file.destination_path});
                };
                const parent_directory = try ensureFATDirectory(context, allocator, parent_dir_path);

                const file_name = std.Io.Dir.path.basename(file.destination_path);

                const name = try Name.create(allocator, file_name);
                defer name.deinit();

                try parent_directory.addFile(name, file.source_path);

                // std.debug.print("FILE: {s} -> {s}\n", .{ file.source_path, file.destination_path });
            },
            .dir => |dir| {
                _ = try ensureFATDirectory(context, allocator, dir.path);
                // std.debug.print("DIR: {s}\n", .{dir.path});
            },
        }
    }
}

fn ensureFATDirectory(context: *Context, allocator: std.mem.Allocator, path: []const u8) !Directory {
    var parent_directory = context.getRootDirectory();

    if (core.is_debug) std.debug.assert(path[0] == '/'); // paths are expected to be absolute

    // Root directory is the parent.
    if (path.len == 1) return parent_directory;

    var section_iter = std.mem.splitScalar(u8, path[1..], '/');
    while (section_iter.next()) |section| {
        const name = try Name.create(allocator, section);
        parent_directory = try parent_directory.getOrAddDirectory(name);
    }

    return parent_directory;
}

const ebpb_boot_code = [_]u8{
    0x0E, 0x1F, 0xBE, 0x77,
    0x7C, 0xAC, 0x22, 0xC0,
    0x74, 0x0B, 0x56, 0xB4,
    0x0E, 0xBB, 0x07, 0x00,
    0xCD, 0x10, 0x5E, 0xEB,
    0xF0, 0x32, 0xE4, 0xCD,
    0x16, 0xCD, 0x19, 0xEB,
    0xFE, 0x54, 0x68, 0x69,
    0x73, 0x20, 0x69, 0x73,
    0x20, 0x6E, 0x6F, 0x74,
    0x20, 0x61, 0x20, 0x62,
    0x6F, 0x6F, 0x74, 0x61,
    0x62, 0x6C, 0x65, 0x20,
    0x64, 0x69, 0x73, 0x6B,
    0x2E, 0x20, 0x20, 0x50,
    0x6C, 0x65, 0x61, 0x73,
    0x65, 0x20, 0x69, 0x6E,
    0x73, 0x65, 0x72, 0x74,
    0x20, 0x61, 0x20, 0x62,
    0x6F, 0x6F, 0x74, 0x61,
    0x62, 0x6C, 0x65, 0x20,
    0x66, 0x6C, 0x6F, 0x70,
    0x70, 0x79, 0x20, 0x61,
    0x6E, 0x64, 0x0D, 0x0A,
    0x70, 0x72, 0x65, 0x73,
    0x73, 0x20, 0x61, 0x6E,
    0x79, 0x20, 0x6B, 0x65,
    0x79, 0x20, 0x74, 0x6F,
    0x20, 0x74, 0x72, 0x79,
    0x20, 0x61, 0x67, 0x61,
    0x69, 0x6E, 0x20, 0x2E,
    0x2E, 0x2E, 0x20, 0x0D,
    0x0A,
};
