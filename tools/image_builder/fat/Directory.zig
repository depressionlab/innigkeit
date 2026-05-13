const Directory = @This();

const std = @import("std");
const core = @import("core");
const filesystem = @import("filesystem");

const FAT = @import("root.zig");

context: *FAT.Context,
cluster: u32,
directory_entries: []filesystem.fat.DirectoryEntry,

pub fn getOrAddDirectory(self: Directory, name: FAT.Name) !Directory {
    if (core.is_debug) std.debug.assert(name.long_name == null); // TODO: support long names

    if (self.findEntry(name)) |entry| {
        if (core.is_debug) std.debug.assert(entry.standard.attributes.directory); // pre-existing entry is not a directory

        const cluster: u32 = @as(u32, entry.standard.high_cluster_number) << 16 | entry.standard.low_cluster_number;

        // TODO: length is assumed to be one cluster
        const directory_ptr: [*]filesystem.fat.DirectoryEntry = @ptrCast(
            self.context.clusterSlice(cluster, 1).ptr,
        );
        const directory_entries: []filesystem.fat.DirectoryEntry = directory_ptr[0..self.context.directory_entries_per_cluster];

        return .{
            .context = self.context,
            .cluster = cluster,
            .directory_entries = directory_entries,
        };
    }

    return self.addDirectory(name);
}

fn findEntry(self: Directory, name: FAT.Name) ?*filesystem.fat.DirectoryEntry {
    if (core.is_debug) std.debug.assert(name.long_name == null); // TODO: support long names

    for (self.directory_entries) |*entry| {
        if (entry.isUnusedEntry()) continue;
        if (entry.isLastEntry()) break;

        if (entry.isLongFileNameEntry()) {
            continue; // TODO: long names
        }

        if (entry.standard.short_file_name.equal(name.short_name)) return entry;
    }

    return null;
}

fn addDirectory(self: Directory, name: FAT.Name) !Directory {
    if (name.long_name) |long_name| {
        try self.addLongFileName(name.short_name, long_name);
    }

    const entry = self.firstUnusedEntry() orelse return error.NoFreeDirectoryEntries;

    const new_cluster = try self.context.nextCluster();

    entry.* = .{
        .standard = .{
            .short_file_name = name.short_name,
            .attributes = .{
                .directory = true,
            },
            .creation_datetime_subsecond = self.context.date_time.subsecond,
            .creation_time = self.context.date_time.time,
            .creation_date = self.context.date_time.date,
            .last_accessed_date = self.context.date_time.date,
            .high_cluster_number = @truncate(new_cluster >> 16),
            .last_modification_time = self.context.date_time.time,
            .last_modification_date = self.context.date_time.date,
            .low_cluster_number = @truncate(new_cluster),
            .size = 0,
        },
    };

    // TODO: We assume that no directories exceed a single cluster
    self.context.setFAT(new_cluster, filesystem.fat.FAT32Entry.end_of_chain);

    // TODO: length is assumed to be one cluster
    const directory_ptr: [*]filesystem.fat.DirectoryEntry = @ptrCast(self.context.clusterSlice(new_cluster, 1).ptr);
    const directory_entries: []filesystem.fat.DirectoryEntry = directory_ptr[0..self.context.directory_entries_per_cluster];

    // '.' directory
    directory_entries[0] = filesystem.fat.DirectoryEntry{
        .standard = filesystem.fat.DirectoryEntry.StandardDirectoryEntry{
            .short_file_name = .{
                .name = [_]u8{ '.', ' ', ' ', ' ', ' ', ' ', ' ', ' ' },
            },
            .attributes = .{
                .directory = true,
            },
            .creation_datetime_subsecond = self.context.date_time.subsecond,
            .creation_time = self.context.date_time.time,
            .creation_date = self.context.date_time.date,
            .last_accessed_date = self.context.date_time.date,
            .high_cluster_number = @truncate(new_cluster >> 16),
            .last_modification_time = self.context.date_time.time,
            .last_modification_date = self.context.date_time.date,
            .low_cluster_number = @truncate(new_cluster),
            .size = 0,
        },
    };

    // '..' directory
    directory_entries[1] = filesystem.fat.DirectoryEntry{
        .standard = filesystem.fat.DirectoryEntry.StandardDirectoryEntry{
            .short_file_name = .{
                .name = [_]u8{ '.', '.', ' ', ' ', ' ', ' ', ' ', ' ' },
            },
            .attributes = .{
                .directory = true,
            },
            .creation_datetime_subsecond = self.context.date_time.subsecond,
            .creation_time = self.context.date_time.time,
            .creation_date = self.context.date_time.date,
            .last_accessed_date = self.context.date_time.date,
            .high_cluster_number = @truncate(self.cluster >> 16),
            .last_modification_time = self.context.date_time.time,
            .last_modification_date = self.context.date_time.date,
            .low_cluster_number = @truncate(self.cluster),
            .size = 0,
        },
    };

    return Directory{
        .context = self.context,
        .cluster = new_cluster,
        .directory_entries = directory_entries,
    };
}

pub fn addFile(self: Directory, name: FAT.Name, source_path: []const u8) !void {
    if (name.long_name) |long_name| {
        try self.addLongFileName(name.short_name, long_name);
    }

    const entry = self.firstUnusedEntry() orelse return error.NoFreeDirectoryEntries;

    entry.* = filesystem.fat.DirectoryEntry{
        .standard = filesystem.fat.DirectoryEntry.StandardDirectoryEntry{
            .short_file_name = name.short_name,
            .attributes = .{
                .archive = true,
            },
            .creation_datetime_subsecond = self.context.date_time.subsecond,
            .creation_time = self.context.date_time.time,
            .creation_date = self.context.date_time.date,
            .last_accessed_date = self.context.date_time.date,
            .high_cluster_number = 0, // set by `copyFile`
            .last_modification_time = self.context.date_time.time,
            .last_modification_date = self.context.date_time.date,
            .low_cluster_number = 0, // set by `copyFile`
            .size = 0, // set by `copyFile`
        },
    };
    try self.context.copyFile(
        &entry.standard,
        source_path,
    );
}

fn addLongFileName(self: Directory, short_name: filesystem.fat.ShortFileName, long_name: []const u8) !void {
    if (core.is_debug) std.debug.assert(long_name[long_name.len - 1] == 0);

    const number_of_long_name_entries_required = (long_name.len /
        filesystem.fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_characters) + 1;

    if (core.is_debug) std.debug.assert(number_of_long_name_entries_required <=
        filesystem.fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_long_name_entries);

    const short_name_checksum = short_name.checksum();

    var sequence_number_counter: u8 = @intCast(number_of_long_name_entries_required);

    var start_index = std.mem.alignBackwardAnyAlign(
        usize,
        long_name.len,
        filesystem.fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_characters,
    );

    while (sequence_number_counter >= 1) : (sequence_number_counter -= 1) {
        const entry = self.firstUnusedEntry() orelse return error.NoFreeDirectoryEntries;

        const sequence_number = if (sequence_number_counter == number_of_long_name_entries_required)
            sequence_number_counter | filesystem.fat.DirectoryEntry.LongFileNameEntry.last_entry
        else
            sequence_number_counter;

        entry.* = filesystem.fat.DirectoryEntry{
            .long_file_name = filesystem.fat.DirectoryEntry.LongFileNameEntry{
                .sequence_number = sequence_number,
                .checksum_of_short_name = short_name_checksum,
            },
        };

        const distance_from_end_of_buffer = long_name.len - start_index;
        const window_length = if (distance_from_end_of_buffer <
            filesystem.fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_characters)
            distance_from_end_of_buffer
        else
            filesystem.fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_characters;

        const window = long_name[start_index..][0..window_length];

        for (window, 0..) |char, i| {
            switch (i) {
                0...4 => entry.long_file_name.first_characters[i] = char,
                5...10 => entry.long_file_name.middle_characters[i - 5] = char,
                11...12 => entry.long_file_name.final_characters[i - 11] = char,
                else => return error.InvalidLongFileName,
            }
        }

        if (start_index != 0) start_index -= filesystem.fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_characters;
    }
}

fn firstUnusedEntry(self: Directory) ?*filesystem.fat.DirectoryEntry {
    for (self.directory_entries) |*entry| {
        if (core.is_debug) std.debug.assert(!entry.isUnusedEntry()); // we only add more entries, never remove them
        if (entry.isLastEntry()) return entry;
    }
    return null;
}
