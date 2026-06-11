//! Simple flat filesystem stored on the data block device.
//!
//! On-disk layout (all integers are little-endian):
//!   Sector 0: reserved (MBR / bootloader)
//!   Sector 1: directory with 16 entries x 32 bytes = 512 bytes
//!     Entry layout:
//!       bytes  0-15: filename, null-terminated, max 15 chars + null
//!       bytes 16-19: file size in bytes (u32 LE)
//!       bytes 20-23: start sector (u32 LE), first data sector
//!       bytes 24-27: flags (u32 LE) bit 0 = slot in use
//!       bytes 28-31: reserved (zero)
//!   Sectors 2-511: file data (contiguous sector runs)
//!
//! Supports up to 16 files. Max file size depends on available sectors.

const std = @import("std");
const innigkeit = @import("innigkeit");

const log = innigkeit.debug.log.scoped(.simple_fs);

const DIR_SECTOR: u32 = 1;
const DATA_START_SECTOR: u32 = 2;
const DATA_END_SECTOR: u32 = 512; // exclusive / sectors 2..511 available for data
const MAX_ENTRIES: usize = 16;
const ENTRY_SIZE: usize = 32;

pub const DirEntry = extern struct {
    name: [16]u8,
    size: u32,
    start_sector: u32,
    flags: u32,
    _pad: u32 = 0,

    pub fn isInUse(self: DirEntry) bool {
        return self.flags & 1 != 0;
    }

    pub fn getName(self: *const DirEntry) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.name, 0) orelse 16;
        return self.name[0..len];
    }
};

comptime {
    std.debug.assert(@sizeOf(DirEntry) == ENTRY_SIZE);
}

/// Read the directory sector from disk into `dir_buf`.
fn readDirectory(dir_buf: *[512]u8) !void {
    if (!innigkeit.drivers.virtio.blk.isDataReady()) return error.NoDevice;
    const dev_idx = innigkeit.drivers.virtio.blk.dataDeviceIndex();
    innigkeit.drivers.virtio.blk.readSectors(dev_idx, DIR_SECTOR, dir_buf, 1) catch |err| {
        log.debug("simple_fs: readDirectory failed: {t}", .{err});
        return error.IoError;
    };
}

/// Write the directory sector to disk.
fn writeDirectory(dir_buf: *const [512]u8) !void {
    if (!innigkeit.drivers.virtio.blk.isDataReady()) return error.NoDevice;
    const dev_idx = innigkeit.drivers.virtio.blk.dataDeviceIndex();
    // writeSectors takes []const u8
    var tmp: [512]u8 = undefined;
    @memcpy(&tmp, dir_buf);
    innigkeit.drivers.virtio.blk.writeSectors(dev_idx, DIR_SECTOR, &tmp, 1) catch |err| {
        log.debug("simple_fs: writeDirectory failed: {t}", .{err});
        return error.IoError;
    };
}

/// Find a directory entry by exact name. Returns its index (0..15) or null.
fn findEntry(dir_buf: *const [512]u8, name: []const u8) ?usize {
    for (0..MAX_ENTRIES) |i| {
        const entry: *const DirEntry = @ptrCast(@alignCast(dir_buf[i * ENTRY_SIZE ..][0..ENTRY_SIZE]));
        if (!entry.isInUse()) continue;
        if (std.mem.eql(u8, entry.getName(), name)) return i;
    }
    return null;
}

/// Find a free directory slot. Returns its index (0..15) or null.
fn findFreeSlot(dir_buf: *const [512]u8) ?usize {
    for (0..MAX_ENTRIES) |i| {
        const entry: *const DirEntry = @ptrCast(@alignCast(dir_buf[i * ENTRY_SIZE ..][0..ENTRY_SIZE]));
        if (!entry.isInUse()) return i;
    }
    return null;
}

/// Allocate `sector_count` contiguous sectors for a new file.
/// Scans the directory to find the highest used sector, then places the new
/// file immediately after. Returns the start sector or an error.
fn allocateSectors(dir_buf: *const [512]u8, sector_count: u32) !u32 {
    // Widen to u64 throughout: `size` and `start_sector` come from disk, so
    // hostile values must not be able to wrap the end-of-file computation
    // below an existing file's start and defeat the bounds check.
    var high_sector: u64 = DATA_START_SECTOR;

    for (0..MAX_ENTRIES) |i| {
        const entry: *const DirEntry = @ptrCast(@alignCast(dir_buf[i * ENTRY_SIZE ..][0..ENTRY_SIZE]));
        if (!entry.isInUse()) continue;
        const file_sectors = (@as(u64, entry.size) + 511) / 512;
        const end = entry.start_sector + file_sectors;
        if (end > high_sector) high_sector = end;
    }

    if (high_sector + sector_count > DATA_END_SECTOR) return error.NoSpace;
    return @intCast(high_sector);
}

/// Flags for open().
pub const OpenFlags = packed struct(u32) {
    /// Create the file if it does not exist.
    create: bool = false,
    /// Truncate the file to zero length on open.
    truncate: bool = false,
    _: u30 = 0,
};

/// An open file handle (stored per-process).
pub const OpenFile = struct {
    start_sector: u32,
    /// Current file size in bytes (may grow on write).
    size: u32,
    /// Current read/write position.
    pos: u32 = 0,
    /// Index of this file's entry in the directory.
    dir_idx: u8,
    /// Whether the file was opened for writing.
    writable: bool,
};

/// Open or create a file.
///
/// `name` must be at most 15 bytes.
/// On success returns an `OpenFile` that the caller must eventually pass to
/// `close()` or `sync()` to flush any updated size to the directory.
pub fn open(name: []const u8, flags: OpenFlags) !OpenFile {
    if (name.len == 0 or name.len > 15) return error.InvalidArgument;

    var dir_buf: [512]u8 = undefined;
    try readDirectory(&dir_buf);

    if (findEntry(&dir_buf, name)) |idx| {
        // File exists.
        const entry: *DirEntry = @ptrCast(@alignCast(dir_buf[idx * ENTRY_SIZE ..][0..ENTRY_SIZE]));
        var file: OpenFile = .{
            .start_sector = entry.start_sector,
            .size = entry.size,
            .dir_idx = @intCast(idx),
            .writable = flags.create or flags.truncate,
        };
        if (flags.truncate) {
            file.size = 0;
            entry.size = 0;
            try writeDirectory(&dir_buf);
        }
        return file;
    }

    // File does not exist.
    if (!flags.create) return error.NotFound;

    const free_idx = findFreeSlot(&dir_buf) orelse return error.NoSpace;

    // Reserve space: pre-allocate 1 sector minimum so we have a start_sector.
    // Additional sectors are claimed lazily on write via a "high water mark"
    // in allocateSectors. Here we just need a stable start_sector.
    const start = try allocateSectors(&dir_buf, 0);

    const entry: *DirEntry = @ptrCast(@alignCast(dir_buf[free_idx * ENTRY_SIZE ..][0..ENTRY_SIZE]));
    entry.* = .{
        .name = [_]u8{0} ** 16,
        .size = 0,
        .start_sector = start,
        .flags = 1, // in use
        ._pad = 0,
    };
    @memcpy(entry.name[0..name.len], name);

    try writeDirectory(&dir_buf);

    return OpenFile{
        .start_sector = start,
        .size = 0,
        .dir_idx = @intCast(free_idx),
        .writable = true,
    };
}

/// Read up to `buf.len` bytes from `file` at its current position.
/// Advances `file.pos` by the number of bytes read.
/// Returns the number of bytes actually read (0 at EOF).
pub fn read(file: *OpenFile, buf: []u8) !usize {
    if (buf.len == 0) return 0;
    if (file.pos >= file.size) return 0;

    if (!innigkeit.drivers.virtio.blk.isDataReady()) return error.NoDevice;

    const dev_idx = innigkeit.drivers.virtio.blk.dataDeviceIndex();
    const to_read: usize = @min(buf.len, file.size - file.pos);
    const byte_offset: u64 = @as(u64, file.start_sector) * 512 + file.pos;

    innigkeit.drivers.virtio.blk.readBytes(dev_idx, byte_offset, buf[0..to_read]) catch |err| {
        log.debug("simple_fs read: readBytes failed: {t}", .{err});
        return error.IoError;
    };

    file.pos += @intCast(to_read);
    return to_read;
}

/// Write `buf` to `file` at its current position.
/// Advances `file.pos` and may extend `file.size`.
/// The caller must call `sync()` or `close()` afterwards to persist the size.
pub fn write(file: *OpenFile, buf: []const u8) !usize {
    if (!file.writable) return error.PermissionDenied;
    if (buf.len == 0) return 0;

    if (!innigkeit.drivers.virtio.blk.isDataReady()) return error.NoDevice;

    const dev_idx = innigkeit.drivers.virtio.blk.dataDeviceIndex();

    // We write in full-sector chunks using a bounce buffer.
    var in_pos: usize = 0;
    var remaining: usize = buf.len;
    var cur_byte: u64 = @as(u64, file.start_sector) * 512 + file.pos;

    while (remaining > 0) {
        // Determine which sector this falls in.
        const sector_offset: usize = @intCast(cur_byte % 512);
        const sector: u64 = cur_byte / 512;

        // Read-modify-write the sector.
        var sector_buf: [512]u8 = undefined;
        innigkeit.drivers.virtio.blk.readSectors(dev_idx, sector, &sector_buf, 1) catch |err| {
            log.debug("simple_fs write: readSectors failed: {t}", .{err});
            return error.IoError;
        };

        const space_in_sector: usize = 512 - sector_offset;
        const copy_len: usize = @min(remaining, space_in_sector);
        @memcpy(sector_buf[sector_offset..][0..copy_len], buf[in_pos..][0..copy_len]);

        innigkeit.drivers.virtio.blk.writeSectors(dev_idx, sector, &sector_buf, 1) catch |err| {
            log.debug("simple_fs write: writeSectors failed: {t}", .{err});
            return error.IoError;
        };

        in_pos += copy_len;
        remaining -= copy_len;
        cur_byte += copy_len;
        file.pos += @intCast(copy_len);
        if (file.pos > file.size) file.size = file.pos;
    }

    return buf.len;
}

/// Flush the updated file size to the on-disk directory.
pub fn sync(file: *OpenFile) !void {
    var dir_buf: [512]u8 = undefined;
    try readDirectory(&dir_buf);

    const entry: *DirEntry = @ptrCast(@alignCast(dir_buf[file.dir_idx * ENTRY_SIZE ..][0..ENTRY_SIZE]));
    entry.size = file.size;
    try writeDirectory(&dir_buf);
}

/// Close the file, flushing size to directory if the file is writable.
pub fn close(file: *OpenFile) void {
    if (file.writable) {
        sync(file) catch |err| {
            log.debug("simple_fs close: sync failed: {t}", .{err});
        };
    }
}

/// Test helper: write a directory entry into slot `idx` of a raw dir sector.
fn writeTestEntry(dir_buf: *[512]u8, idx: usize, name: []const u8, size: u32, start_sector: u32) void {
    var entry: DirEntry = .{
        .name = [_]u8{0} ** 16,
        .size = size,
        .start_sector = start_sector,
        .flags = 1, // in use
    };
    @memcpy(entry.name[0..name.len], name);
    @memcpy(dir_buf[idx * ENTRY_SIZE ..][0..ENTRY_SIZE], std.mem.asBytes(&entry));
}

test "simple_fs: allocateSectors bounds check does not wrap near u32 max" {
    var dir_buf: [512]u8 align(@alignOf(DirEntry)) = [_]u8{0} ** 512;

    // Empty directory: allocation starts at the first data sector.
    try std.testing.expectEqual(@as(u32, DATA_START_SECTOR), try allocateSectors(&dir_buf, 4));

    // Normal entry: 1024 bytes starting at sector 2 occupy sectors 2..3,
    // so the next allocation begins at sector 4.
    writeTestEntry(&dir_buf, 0, "a", 1024, DATA_START_SECTOR);
    try std.testing.expectEqual(@as(u32, 4), try allocateSectors(&dir_buf, 1));

    // Hostile on-disk entry near u32 max: start + sector count must not
    // wrap below DATA_END_SECTOR and defeat the bounds check.
    writeTestEntry(&dir_buf, 1, "evil", std.math.maxInt(u32), std.math.maxInt(u32));
    try std.testing.expectError(error.NoSpace, allocateSectors(&dir_buf, 1));
}
