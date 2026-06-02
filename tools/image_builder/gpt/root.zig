const std = @import("std");
const core = @import("core");
const filesystem = @import("filesystem");
const UUID = @import("uuid").UUID;
const root = @import("../main.zig");

const ImageDescription = @import("../image/ImageDescription.zig");
pub const Partition = @import("Partition.zig");

pub fn create(allocator: std.mem.Allocator, image_description: ImageDescription, disk_image: []u8, random: std.Random, gpt_partitions: []Partition) !void {
    if (core.is_debug) std.debug.assert(
        std.mem.isAligned(disk_image.len, root.disk_block_size.value),
    );

    const number_of_blocks = disk_image.len / root.disk_block_size.value;

    const number_of_partition_entries: u32 = if (image_description.partitions.len <
        filesystem.gpt.minimum_number_of_partition_entries)
        filesystem.gpt.minimum_number_of_partition_entries
    else
        @intCast(image_description.partitions.len);

    const partition_array_size_in_blocks: u64 = root.disk_block_size.amountToCover(
        filesystem.gpt.PartitionEntry.size.multiplyScalar(number_of_partition_entries),
    );

    const first_usable_block = 2 + partition_array_size_in_blocks;

    const last_usable_block = number_of_blocks - 2 - partition_array_size_in_blocks;

    if (core.is_debug) std.debug.assert(last_usable_block - first_usable_block > 0);

    // Block 0 = Protective MBR
    protectiveMBR(disk_image, number_of_blocks);

    // Block 2 = Primary Partition Entry Array
    const entries: []filesystem.gpt.PartitionEntry = root.asPtr(
        [*]filesystem.gpt.PartitionEntry,
        disk_image,
        2,
        root.disk_block_size,
    )[0..number_of_partition_entries];

    const partition_table_crc = partition_table_crc: {
        const partition_alignment =
            filesystem.gpt.recommended_alignment_of_partitions.divide(root.disk_block_size);
        var next_free_block = first_usable_block;

        for (image_description.partitions, 0..) |partition, i| {
            const starting_block = std.mem.alignForward(
                usize,
                next_free_block,
                partition_alignment,
            );

            if (starting_block > last_usable_block) {
                @panic("exceeded disk image size!");
            }

            const desired_blocks_in_partition = blk: {
                if (partition.size == 0) {
                    if (i != image_description.partitions.len - 1) {
                        @panic("partition with zero size that is not the last partition!");
                    }
                    break :blk std.mem.alignBackward(
                        usize,
                        last_usable_block - starting_block,
                        partition_alignment,
                    );
                }

                break :blk root.disk_block_size.amountToCover(
                    .from(partition.size, .byte),
                );
            };

            const ending_block = blk: {
                const ending_block = starting_block + desired_blocks_in_partition - 1;

                const aligned_ending_block = std.mem.alignForward(usize, ending_block, partition_alignment) - 1;

                if (aligned_ending_block <= last_usable_block) break :blk aligned_ending_block;

                std.debug.panic("partition {d}: aligned end block is larger than the last usable block!", .{i});
            };

            if (ending_block < starting_block)
                @panic("ending block is less than starting block!");

            const blocks_in_partition = (ending_block - starting_block) + 1;

            entries[i] = .{
                .partition_type_guid = switch (partition.partition_type) {
                    .efi => filesystem.gpt.partition_types.efi_system_partition,
                    .bios_boot => filesystem.gpt.partition_types.bios_boot_partition,
                    .data => filesystem.gpt.partition_types.linux_filesystem_data,
                },
                .unique_partition_guid = UUID.generateV4(random),
                .starting_lba = starting_block,
                .ending_lba = ending_block,
            };

            const encoded_name = try std.unicode.utf8ToUtf16LeAllocZ(allocator, partition.name);
            defer allocator.free(encoded_name);

            @memcpy(entries[i].partition_name[0..encoded_name.len], encoded_name);

            gpt_partitions[i] = .{
                .start_block = starting_block,
                .block_count = blocks_in_partition,
            };

            next_free_block = ending_block + 1;
        }

        const entry_bytes = std.mem.sliceAsBytes(entries);
        break :partition_table_crc filesystem.gpt.Crc32.hash(entry_bytes);
    };

    const disk_guid = UUID.generateV4(random);

    // Block 1 = Primary GPT Header
    const primary_header = fillInPrimaryGptHeader(
        disk_image,
        number_of_blocks,
        first_usable_block,
        last_usable_block,
        disk_guid,
        number_of_partition_entries,
        partition_table_crc,
    );

    // Block (NUM - 1) = Backup GPT Header
    const backup_header = root.asPtr(
        *filesystem.gpt.Header,
        disk_image,
        number_of_blocks - 1,
        root.disk_block_size,
    );
    primary_header.copyToOtherHeader(backup_header, partition_array_size_in_blocks);

    // Block (NUM - 1 - number of partition entries) = Backup Partition Entry Array
    const backup_partition_entry_array: []filesystem.gpt.PartitionEntry = root.asPtr(
        [*]filesystem.gpt.PartitionEntry,
        disk_image,
        backup_header.partition_entry_lba,
        root.disk_block_size,
    )[0..number_of_partition_entries];
    @memcpy(backup_partition_entry_array, entries);
}

fn protectiveMBR(disk_image: []u8, number_of_blocks: usize) void {
    const mbr_ptr = root.asPtr(
        *filesystem.mbr.MBR,
        disk_image,
        0,
        root.disk_block_size,
    );
    filesystem.gpt.protectiveMBR(mbr_ptr, number_of_blocks);
}

fn fillInPrimaryGptHeader(
    disk_image: []u8,
    number_of_blocks: usize,
    first_usable_block: usize,
    last_usable_block: usize,
    guid: UUID,
    number_of_partition_entries: u32,
    partition_table_crc: u32,
) *filesystem.gpt.Header {
    const primary_header: *filesystem.gpt.Header = root.asPtr(
        *filesystem.gpt.Header,
        disk_image,
        1,
        root.disk_block_size,
    );
    primary_header.* = .{
        .my_lba = 1,
        .alternate_lba = number_of_blocks - 1,
        .first_usable_lba = first_usable_block,
        .last_usable_lba = last_usable_block,
        .disk_guid = guid,
        .partition_entry_lba = 2,
        .number_of_partition_entries = number_of_partition_entries,
        .size_of_partition_entry = @intCast(filesystem.gpt.PartitionEntry.size.value),
        .partition_entry_array_crc32 = partition_table_crc,
    };
    primary_header.updateHash();
    return primary_header;
}
