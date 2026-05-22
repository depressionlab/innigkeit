const Context = @This();

const std = @import("std");
const core = @import("core");
const filesystem = @import("filesystem");

const FAT = @import("root.zig");
const root = @import("../main.zig");

io: std.Io,
fat_partition: []u8,
fat_table: []filesystem.fat.FAT32Entry,
next_cluster: u32,
number_of_clusters: u32,

root_cluster: u32,

sector_size: core.Size,
sectors_per_cluster: u32,
cluster_size: core.Size,

cluster_begin_sector: u32,
directory_entries_per_cluster: usize,

date_time: FAT.DateTime,

pub fn init(
    io: std.Io,
    fat_partition: []u8,
    fat_begin: u32,
    number_of_fat_entries: u32,
    sector_size: core.Size,
    root_cluster: u32,
    sectors_per_cluster: u32,
    cluster_begin_sector: u32,
    number_of_clusters: u32,
) Context {
    if (core.is_debug) std.debug.assert(root_cluster == 2); // TODO: Remove this requirement

    const cluster_size = sector_size.multiplyScalar(sectors_per_cluster);
    return .{
        .io = io,
        .fat_partition = fat_partition,
        .fat_table = root.asPtr(
            [*]filesystem.fat.FAT32Entry,
            fat_partition,
            fat_begin,
            sector_size,
        )[0..number_of_fat_entries],
        .next_cluster = 3,
        .root_cluster = root_cluster,
        .sector_size = sector_size,
        .sectors_per_cluster = sectors_per_cluster,
        .cluster_size = cluster_size,
        .cluster_begin_sector = cluster_begin_sector,
        .directory_entries_per_cluster = cluster_size.divide(core.Size.of(filesystem.fat.DirectoryEntry)),
        .date_time = FAT.DateTime.create(io),
        .number_of_clusters = number_of_clusters,
    };
}

pub fn setFAT(self: *Context, index: u32, entry: filesystem.fat.FAT32Entry) void {
    self.fat_table[index] = entry;
}

pub fn nextCluster(self: *Context) !u32 {
    const cluster = self.next_cluster;

    if (cluster >= self.number_of_clusters) return error.NoFreeClusters;

    self.next_cluster += 1;
    return cluster;
}

pub fn clusterSlice(self: Context, cluster_index: u32, number_of_clusters: usize) []u8 {
    const start = self.cluster_begin_sector + (cluster_index - 2) * self.sectors_per_cluster;
    const size = self.sector_size.multiplyScalar(self.sectors_per_cluster * number_of_clusters);
    return root.asPtr(
        [*]u8,
        self.fat_partition,
        start,
        self.sector_size,
    )[0..size.value];
}

pub fn getRootDirectory(self: *Context) FAT.Directory {
    return .{
        .context = self,
        .cluster = self.root_cluster,
        .directory_entries = blk: {
            const root_directory_ptr: [*]filesystem.fat.DirectoryEntry =
                @ptrCast(self.clusterSlice(self.root_cluster, 1).ptr);
            break :blk root_directory_ptr[0..self.directory_entries_per_cluster];
        },
    };
}

pub fn copyFile(
    self: *Context,
    entry: *filesystem.fat.DirectoryEntry.StandardDirectoryEntry,
    path: []const u8,
) !void {
    const io = self.io;

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const file_size = core.Size.from(try file.length(io), .byte);
    const clusters_required = self.cluster_size.amountToCover(file_size);
    if (core.is_debug) std.debug.assert(clusters_required != 0);

    var current_cluster = try self.nextCluster();

    entry.high_cluster_number = @truncate(current_cluster >> 16);
    entry.low_cluster_number = @truncate(current_cluster);
    entry.size = @intCast(file_size.value);

    var reader_buffer: [0x1000]u8 = undefined;
    var file_reader = file.reader(io, &reader_buffer);

    var i: usize = 0;

    while (i < clusters_required) : (i += 1) {
        const cluster_ptr = self.clusterSlice(current_cluster, 1);

        const read = try file_reader.interface.readSliceShort(cluster_ptr);

        const is_last_cluster = i == clusters_required - 1;

        // only for the last cluster will the amount read be less than a full cluster
        if (core.is_debug) std.debug.assert(read == cluster_ptr.len or is_last_cluster);

        if (is_last_cluster) {
            self.setFAT(current_cluster, filesystem.fat.FAT32Entry.end_of_chain);
        } else {
            const next_cluster = try self.nextCluster();
            self.setFAT(current_cluster, @enumFromInt(next_cluster));
            current_cluster = next_cluster;
        }
    }
}
