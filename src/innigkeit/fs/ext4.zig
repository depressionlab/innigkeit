//! Read-only ext4 filesystem driver.
//!
//! Supports:
//!   - Superblock validation, feature flag enforcement
//!   - Block group descriptors (32-bit and 64-bit, full 64-bit inode-table address)
//!   - Inode table lookup with enhanced fields (uid, gid, timestamps, nlink)
//!   - Full extent tree (depths 0–5)
//!   - Inline data (EXT4_INLINE_DATA_FL) for small files
//!   - Directory iteration (linear scan, ext4_dir_entry_2)
//!   - Symlinks: inline fast-symlinks and data-block symlinks, with full
//!     POSIX path resolution (absolute and relative, up to 40 hops)
//!   - ".." path components
//!   - Path-based file lookup (absolute paths)
//!   - File data reads (arbitrary offset + length)
//!   - 8-entry LRU block cache to avoid redundant disk reads
//!
//! Mount-time feature enforcement:
//!   - INCOMPAT features beyond our supported set return error.IncompatibleFeatures
//!   - INCOMPAT_RECOVER (dirty journal) emits a warning but allows read-only access
//!
//! All on-disk integers are little-endian; the host is assumed to be
//! little-endian (x86_64 / aarch64).
//!
//! Block sizes up to 4096 bytes are supported.

const std = @import("std");
const innigkeit = @import("innigkeit");

const log = innigkeit.debug.log.scoped(.ext4);

const EXT4_MAGIC: u16 = 0xEF53;
const EXT4_ROOT_INO: u32 = 2;
const EXT4_EXTENT_MAGIC: u16 = 0xF30A;
const MAX_BLOCK_SIZE: u32 = 4096;
const MAX_SYMLINK_HOPS: u32 = 40;
const MAX_EXTENT_DEPTH: u16 = 5;

// i_mode file type bits
const S_IFMT: u16 = 0xF000;
const S_IFREG: u16 = 0x8000;
const S_IFDIR: u16 = 0x4000;
const S_IFLNK: u16 = 0xA000;

// i_flags
const EXT4_EXTENTS_FL: u32 = 0x00080000;
const EXT4_INLINE_DATA_FL: u32 = 0x10000000;

// Incompatible feature flags
const INCOMPAT_FILETYPE: u32 = 0x0002; // dir entries have file_type (assumed)
const INCOMPAT_RECOVER: u32 = 0x0004; // journal recovery needed (warn, allow RO)
const INCOMPAT_JOURNAL_DEV: u32 = 0x0008; // external journal (reject)
const INCOMPAT_META_BG: u32 = 0x0010; // meta_bg layout (reject - changes GDT location)
const INCOMPAT_EXTENTS: u32 = 0x0040; // extent trees (handled)
const INCOMPAT_64BIT: u32 = 0x0080; // 64-bit block addresses (handled)
const INCOMPAT_FLEX_BG: u32 = 0x0200; // flexible block groups (transparent for reads)
const INCOMPAT_INLINE_DATA: u32 = 0x8000; // inline data in inodes (handled)
const INCOMPAT_ENCRYPT: u32 = 0x10000; // encrypted inodes (reject)

// Features we handle transparently; everything else is an error.
const SUPPORTED_INCOMPAT: u32 = INCOMPAT_FILETYPE | INCOMPAT_EXTENTS |
    INCOMPAT_64BIT | INCOMPAT_FLEX_BG | INCOMPAT_INLINE_DATA;
// Allow but warn about dirty-journal flag so systems that didn't clean-unmount still work RO.
const WARN_INCOMPAT: u32 = INCOMPAT_RECOVER;

const CACHE_SIZE: usize = 8;

const CacheEntry = struct {
    dev_idx: usize = 0,
    block_num: u64 = std.math.maxInt(u64), // maxInt = empty slot
    data: [MAX_BLOCK_SIZE]u8 = undefined,
    stamp: u32 = 0,
};

var block_cache: [CACHE_SIZE]CacheEntry = blk: {
    var c: [CACHE_SIZE]CacheEntry = undefined;
    for (&c) |*e| e.* = CacheEntry{};
    break :blk c;
};
var cache_clock: u32 = 0;

fn cacheLookup(dev_idx: usize, block_num: u64, buf: *[MAX_BLOCK_SIZE]u8, block_size: u32) bool {
    for (&block_cache) |*e| {
        if (e.block_num == block_num and e.dev_idx == dev_idx) {
            cache_clock +%= 1;
            e.stamp = cache_clock;
            @memcpy(buf[0..block_size], e.data[0..block_size]);
            return true;
        }
    }
    return false;
}

fn cacheInsert(dev_idx: usize, block_num: u64, buf: *const [MAX_BLOCK_SIZE]u8, block_size: u32) void {
    // Find empty or LRU slot.
    var lru: usize = 0;
    var lru_stamp: u32 = block_cache[0].stamp;
    for (&block_cache, 0..) |*e, i| {
        if (e.block_num == std.math.maxInt(u64)) {
            lru = i;
            break;
        }
        if (e.stamp < lru_stamp) {
            lru_stamp = e.stamp;
            lru = i;
        }
    }
    cache_clock +%= 1;
    block_cache[lru] = .{
        .dev_idx = dev_idx,
        .block_num = block_num,
        .stamp = cache_clock,
    };
    @memcpy(block_cache[lru].data[0..block_size], buf[0..block_size]);
}

fn cacheInvalidate(dev_idx: usize) void {
    for (&block_cache) |*e| {
        if (e.dev_idx == dev_idx) e.block_num = std.math.maxInt(u64);
    }
}

fn cacheInvalidateBlock(dev_idx: usize, block_num: u64) void {
    for (&block_cache) |*e| {
        if (e.dev_idx == dev_idx and e.block_num == block_num)
            e.block_num = std.math.maxInt(u64);
    }
}

const SUPERBLOCK_OFFSET: u64 = 1024;
const SUPERBLOCK_SIZE: usize = 1024;

const SbInfo = struct {
    block_size: u32,
    inodes_count: u32,
    inodes_per_group: u32,
    blocks_per_group: u32,
    inode_size: u16,
    first_data_block: u32,
    desc_size: u32, // 32 or 64
    feature_incompat: u32,
    feature_compat: u32,
    feature_ro_compat: u32,
    volume_name: [17]u8, // null-terminated
};

const GroupDesc = struct {
    inode_table: u64, // full 64-bit physical block number
};

const Inode = struct {
    mode: u16,
    uid: u32, // uid_lo | (uid_hi << 16)
    gid: u32, // gid_lo | (gid_hi << 16)
    size: u64,
    flags: u32,
    nlink: u16,
    atime: u32,
    mtime: u32,
    ctime: u32,
    i_block: [60]u8,
};

const ExtentHeader = extern struct {
    magic: u16,
    entries: u16,
    max: u16,
    depth: u16,
    generation: u32,
};

const Extent = extern struct {
    block: u32,
    len: u16,
    start_hi: u16,
    start_lo: u32,
};

const ExtentIdx = extern struct {
    block: u32,
    leaf_lo: u32,
    leaf_hi: u16,
    _unused: u16,
};

comptime {
    std.debug.assert(@sizeOf(ExtentHeader) == 12);
    std.debug.assert(@sizeOf(Extent) == 12);
    std.debug.assert(@sizeOf(ExtentIdx) == 12);
}

const DirEntry = struct {
    inode: u32,
    rec_len: u16,
    name_len: u8,
    file_type: u8,
    name: []const u8,
};

/// Validating iterator over ext4_dir_entry_2 records in one directory block.
///
/// Every record is checked before it is exposed:
///   - rec_len >= 8 (also rejects rec_len == 0, which would loop forever),
///   - the whole record (off + rec_len) lies inside the block,
///   - the name (8 + name_len) fits inside the record.
///
/// Iteration terminates at the first malformed record, so callers can never
/// read past the block buffer or fail to make progress. Deleted records
/// (inode == 0) are still yielded so callers that need the physical record
/// chain (e.g. entry merging on delete) see every record.
const DirBlockIter = struct {
    buf: []const u8, // exactly one directory block
    off: u32 = 0,

    const Rec = struct {
        /// Byte offset of this record within the block.
        off: u32,
        entry: DirEntry,
    };

    fn init(buf: []const u8) DirBlockIter {
        return .{ .buf = buf };
    }

    fn next(self: *DirBlockIter) ?Rec {
        const off = self.off;
        if (@as(usize, off) + 8 > self.buf.len) return null;
        const ino = std.mem.readInt(u32, self.buf[off..][0..4], .little);
        const rec_len = std.mem.readInt(u16, self.buf[off + 4 ..][0..2], .little);
        if (rec_len < 8) return null;
        if (@as(usize, off) + rec_len > self.buf.len) return null;
        const name_len = self.buf[off + 6];
        if (8 + @as(u16, name_len) > rec_len) return null;
        const file_type = self.buf[off + 7];
        self.off = off + rec_len;
        return .{
            .off = off,
            .entry = .{
                .inode = ino,
                .rec_len = rec_len,
                .name_len = name_len,
                .file_type = file_type,
                .name = self.buf[off + 8 ..][0..name_len],
            },
        };
    }
};

/// ceil(size / unit), clamped to u32, without the overflowing
/// `(size + unit - 1) / unit` formulation. Used for block/group counts;
/// ext4 logical block numbers are 32-bit, so anything past maxInt(u32) is
/// unmappable anyway.
fn divCeilClampU32(size: u64, unit: u32) u32 {
    const n = size / unit + @intFromBool(size % unit != 0);
    return @intCast(@min(n, std.math.maxInt(u32)));
}

/// Combine the hi/lo halves of an on-disk block number and reject values
/// outside ext4's 48-bit physical block range (a hostile value would
/// otherwise overflow the `block * block_size` byte-offset computation).
fn combineBlockNum(hi: u32, lo: u32) !u64 {
    const v = (@as(u64, hi) << 32) | lo;
    if (v >= (1 << 48)) return error.CorruptFilesystem;
    return v;
}

pub const Ext4 = struct {
    sb: SbInfo,
    dev_idx: usize,

    pub fn mount(dev_idx: usize) !Ext4 {
        if (!innigkeit.drivers.virtio.blk.isDataReady()) return error.NoDevice;

        var raw: [SUPERBLOCK_SIZE]u8 align(8) = undefined;
        innigkeit.drivers.virtio.blk.readBytes(dev_idx, SUPERBLOCK_OFFSET, &raw) catch
            return error.IoError;

        const magic = std.mem.readInt(u16, raw[0x38..0x3A], .little);
        if (magic != EXT4_MAGIC) return error.BadMagic;

        const log_block_size = std.mem.readInt(u32, raw[0x18..0x1C], .little);
        // Bound the on-disk shift amount *before* shifting: a hostile value
        // would otherwise shift out of range (safety panic / UB), not error.
        if (log_block_size > std.math.log2_int(u32, MAX_BLOCK_SIZE / 1024)) return error.BlockSizeTooLarge;
        const block_size: u32 = @as(u32, 1024) << @intCast(log_block_size);

        const feature_incompat = std.mem.readInt(u32, raw[0x60..0x64], .little);
        const feature_compat = std.mem.readInt(u32, raw[0x5C..0x60], .little);
        const feature_ro_compat = std.mem.readInt(u32, raw[0x64..0x68], .little);
        const desc_size: u32 = if (feature_incompat & INCOMPAT_64BIT != 0) 64 else 32;

        // Validate incompatible features.
        const unsupported = feature_incompat & ~(SUPPORTED_INCOMPAT | WARN_INCOMPAT);
        if (unsupported != 0) {
            log.err("ext4: unsupported INCOMPAT features: 0x{x}", .{unsupported});
            return error.IncompatibleFeatures;
        }
        if (feature_incompat & INCOMPAT_RECOVER != 0) {
            log.warn("ext4: filesystem was not cleanly unmounted; some data may be stale (read-only access)", .{});
        }

        var vol: [17]u8 = .{0} ** 17;
        @memcpy(vol[0..16], raw[0x78..0x88]);

        const vol_name_len = std.mem.indexOfScalar(u8, vol[0..16], 0) orelse 16;
        if (vol_name_len > 0) {
            log.info("ext4[{}]: volume \"{s}\" bs={} incompat=0x{x}", .{
                dev_idx, vol[0..vol_name_len], block_size, feature_incompat,
            });
        }

        cacheInvalidate(dev_idx);

        return .{
            .dev_idx = dev_idx,
            .sb = .{
                .block_size = block_size,
                .inodes_count = std.mem.readInt(u32, raw[0x00..0x04], .little),
                .inodes_per_group = std.mem.readInt(u32, raw[0x28..0x2C], .little),
                .blocks_per_group = std.mem.readInt(u32, raw[0x20..0x24], .little),
                .inode_size = std.mem.readInt(u16, raw[0x58..0x5A], .little),
                .first_data_block = std.mem.readInt(u32, raw[0x14..0x18], .little),
                .desc_size = desc_size,
                .feature_incompat = feature_incompat,
                .feature_compat = feature_compat,
                .feature_ro_compat = feature_ro_compat,
                .volume_name = vol,
            },
        };
    }

    fn readBlock(self: *const Ext4, block_num: u64, buf: *[MAX_BLOCK_SIZE]u8) !void {
        if (cacheLookup(self.dev_idx, block_num, buf, self.sb.block_size)) return;
        const off = block_num * self.sb.block_size;
        innigkeit.drivers.virtio.blk.readBytes(
            self.dev_idx,
            off,
            buf[0..self.sb.block_size],
        ) catch return error.IoError;
        cacheInsert(self.dev_idx, block_num, buf, self.sb.block_size);
    }

    fn readGroupDesc(self: *const Ext4, group: u32) !GroupDesc {
        const desc_table_block: u64 = self.sb.first_data_block + 1;
        const byte_offset: u64 =
            desc_table_block * self.sb.block_size +
            @as(u64, group) * self.sb.desc_size;

        var raw: [64]u8 = undefined;
        innigkeit.drivers.virtio.blk.readBytes(
            self.dev_idx,
            byte_offset,
            raw[0..self.sb.desc_size],
        ) catch return error.IoError;

        const lo = std.mem.readInt(u32, raw[0x08..0x0C], .little);
        const hi: u32 = if (self.sb.desc_size >= 64)
            std.mem.readInt(u32, raw[0x28..0x2C], .little)
        else
            0;

        return .{ .inode_table = try combineBlockNum(hi, lo) };
    }

    fn readInode(self: *const Ext4, inode_num: u32) !Inode {
        if (inode_num == 0) return error.InvalidInode;

        const idx = inode_num - 1;
        const group = idx / self.sb.inodes_per_group;
        const local = idx % self.sb.inodes_per_group;

        const gd = try self.readGroupDesc(group);
        const inode_byte_off: u64 =
            gd.inode_table * self.sb.block_size +
            @as(u64, local) * self.sb.inode_size;

        const read_size: usize = @min(self.sb.inode_size, 256);
        var raw: [256]u8 = undefined;
        innigkeit.drivers.virtio.blk.readBytes(
            self.dev_idx,
            inode_byte_off,
            raw[0..read_size],
        ) catch return error.IoError;

        const mode = std.mem.readInt(u16, raw[0x00..0x02], .little);
        const uid_lo = std.mem.readInt(u16, raw[0x02..0x04], .little);
        const size_lo = std.mem.readInt(u32, raw[0x04..0x08], .little);
        const atime = std.mem.readInt(u32, raw[0x08..0x0C], .little);
        const ctime = std.mem.readInt(u32, raw[0x0C..0x10], .little);
        const mtime = std.mem.readInt(u32, raw[0x10..0x14], .little);
        const nlink = std.mem.readInt(u16, raw[0x1A..0x1C], .little);
        const flags = std.mem.readInt(u32, raw[0x20..0x24], .little);
        const size_hi: u32 = if (read_size >= 0x70)
            std.mem.readInt(u32, raw[0x6C..0x70], .little)
        else
            0;
        const uid_hi: u16 = if (read_size >= 0x7A)
            std.mem.readInt(u16, raw[0x78..0x7A], .little)
        else
            0;
        const gid_lo = std.mem.readInt(u16, raw[0x18..0x1A], .little);
        const gid_hi: u16 = if (read_size >= 0x7C)
            std.mem.readInt(u16, raw[0x7A..0x7C], .little)
        else
            0;

        var i_block: [60]u8 = undefined;
        @memcpy(&i_block, raw[0x28..0x64]);

        return .{
            .mode = mode,
            .uid = (@as(u32, uid_hi) << 16) | uid_lo,
            .gid = (@as(u32, gid_hi) << 16) | gid_lo,
            .size = (@as(u64, size_hi) << 32) | size_lo,
            .flags = flags,
            .nlink = nlink,
            .atime = atime,
            .mtime = mtime,
            .ctime = ctime,
            .i_block = i_block,
        };
    }

    // Extent tree
    //
    // Iterative descent: reuses a single scratch buffer per level, so stack
    // usage is O(1) regardless of depth. Max depth enforced at MAX_EXTENT_DEPTH.

    fn mapBlock(self: *const Ext4, inode: *const Inode, logical: u32) !u64 {
        if (inode.flags & EXT4_EXTENTS_FL == 0) {
            if (inode.flags & EXT4_INLINE_DATA_FL != 0) return 0; // inline, handled above
            return error.IndirectBlocksUnsupported;
        }

        // Start with the 60-byte inline node embedded in i_block.
        var hdr: ExtentHeader = undefined;
        @memcpy(std.mem.asBytes(&hdr), inode.i_block[0..@sizeOf(ExtentHeader)]);
        if (std.mem.littleToNative(u16, hdr.magic) != EXT4_EXTENT_MAGIC)
            return error.BadExtentMagic;

        var depth = std.mem.littleToNative(u16, hdr.depth);
        if (depth > MAX_EXTENT_DEPTH) return error.ExtentDepthTooLarge;

        // Node data pointer: starts at i_block, may switch to scratch after first level.
        var scratch: [MAX_BLOCK_SIZE]u8 = undefined;
        var node: []const u8 = &inode.i_block;

        while (depth > 0) : (depth -= 1) {
            const n_entries = std.mem.littleToNative(u16, hdr.entries);
            var chosen: u64 = 0;
            var i: u16 = 0;
            while (i < n_entries) : (i += 1) {
                const off = 12 + @as(usize, i) * @sizeOf(ExtentIdx);
                if (off + @sizeOf(ExtentIdx) > node.len) break;
                var idx_entry: ExtentIdx = undefined;
                @memcpy(std.mem.asBytes(&idx_entry), node[off..][0..@sizeOf(ExtentIdx)]);
                if (std.mem.littleToNative(u32, idx_entry.block) <= logical) {
                    const leaf_lo = std.mem.littleToNative(u32, idx_entry.leaf_lo);
                    const leaf_hi = std.mem.littleToNative(u16, idx_entry.leaf_hi);
                    chosen = (@as(u64, leaf_hi) << 32) | leaf_lo;
                } else break;
            }
            if (chosen == 0) return 0;

            try self.readBlock(chosen, &scratch);
            @memcpy(std.mem.asBytes(&hdr), scratch[0..@sizeOf(ExtentHeader)]);
            if (std.mem.littleToNative(u16, hdr.magic) != EXT4_EXTENT_MAGIC)
                return error.BadExtentMagic;
            node = scratch[0..self.sb.block_size];
        }

        // Leaf node: scan Extent entries.
        const n_entries = std.mem.littleToNative(u16, hdr.entries);
        var i: u16 = 0;
        while (i < n_entries) : (i += 1) {
            const off = 12 + @as(usize, i) * @sizeOf(Extent);
            if (off + @sizeOf(Extent) > node.len) break;
            var ext: Extent = undefined;
            @memcpy(std.mem.asBytes(&ext), node[off..][0..@sizeOf(Extent)]);
            const ee_block = std.mem.littleToNative(u32, ext.block);
            const ee_len = std.mem.littleToNative(u16, ext.len) & 0x7FFF;
            if (logical >= ee_block and logical < ee_block + ee_len) {
                const start_lo = std.mem.littleToNative(u32, ext.start_lo);
                const start_hi = std.mem.littleToNative(u16, ext.start_hi);
                return (@as(u64, start_hi) << 32 | start_lo) + (logical - ee_block);
            }
        }
        return 0; // sparse hole
    }

    fn readDataInode(
        self: *const Ext4,
        inode: *const Inode,
        buf: []u8,
        offset: u64,
    ) !usize {
        // Inline data: small files/symlinks stored directly in i_block.
        if (inode.flags & EXT4_INLINE_DATA_FL != 0) {
            const available: u64 = @min(inode.size, 60);
            if (offset >= available) return 0;
            const n: usize = @intCast(@min(@as(u64, buf.len), available - offset));
            @memcpy(buf[0..n], inode.i_block[@intCast(offset)..][0..n]);
            return n;
        }

        if (offset >= inode.size) return 0;
        const to_read: usize = @intCast(@min(@as(u64, buf.len), inode.size - offset));

        var done: usize = 0;
        var block_buf: [MAX_BLOCK_SIZE]u8 = undefined;
        while (done < to_read) {
            const pos: u64 = offset + done;
            const logical_block: u32 = @intCast(pos / self.sb.block_size);
            const block_off: u32 = @intCast(pos % self.sb.block_size);

            const phys = try self.mapBlock(inode, logical_block);
            if (phys != 0) {
                try self.readBlock(phys, &block_buf);
            } else {
                @memset(block_buf[0..self.sb.block_size], 0);
            }

            const chunk = @min(to_read - done, self.sb.block_size - block_off);
            @memcpy(buf[done..][0..chunk], block_buf[block_off..][0..chunk]);
            done += chunk;
        }
        return done;
    }

    fn readlinkInode(self: *const Ext4, inode: *const Inode, buf: []u8) !usize {
        // Fast symlink: target fits in i_block (or inline data).
        if (inode.size <= 60 and inode.flags & EXT4_EXTENTS_FL == 0) {
            const n: usize = @intCast(@min(inode.size, buf.len));
            @memcpy(buf[0..n], inode.i_block[0..n]);
            return n;
        }
        return self.readDataInode(inode, buf, 0);
    }

    fn iterDir(
        self: *const Ext4,
        dir_inode: u32,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), DirEntry) bool,
    ) !void {
        const inode = try self.readInode(dir_inode);
        if (inode.mode & S_IFMT != S_IFDIR) return error.NotADirectory;

        var block_buf: [MAX_BLOCK_SIZE]u8 = undefined;
        var bytes_read: u64 = 0;
        while (bytes_read < inode.size) {
            const lb: u32 = @intCast(bytes_read / self.sb.block_size);
            const phys = try self.mapBlock(&inode, lb);
            if (phys != 0) try self.readBlock(phys, &block_buf) else @memset(block_buf[0..self.sb.block_size], 0);

            var it: DirBlockIter = .init(block_buf[0..self.sb.block_size]);
            while (it.next()) |rec| {
                if (rec.entry.inode != 0 and rec.entry.name_len > 0) {
                    if (!cb(ctx, rec.entry)) return;
                }
            }
            bytes_read += self.sb.block_size;
        }
    }

    fn lookupInDir(self: *const Ext4, dir_inode: u32, name: []const u8) !u32 {
        const inode = try self.readInode(dir_inode);
        if (inode.mode & S_IFMT != S_IFDIR) return error.NotADirectory;

        var block_buf: [MAX_BLOCK_SIZE]u8 = undefined;
        var bytes_read: u64 = 0;
        while (bytes_read < inode.size) {
            const lb: u32 = @intCast(bytes_read / self.sb.block_size);
            const phys = try self.mapBlock(&inode, lb);
            if (phys != 0) try self.readBlock(phys, &block_buf) else @memset(block_buf[0..self.sb.block_size], 0);

            var it: DirBlockIter = .init(block_buf[0..self.sb.block_size]);
            while (it.next()) |rec| {
                if (rec.entry.inode != 0 and std.mem.eql(u8, rec.entry.name, name)) {
                    return rec.entry.inode;
                }
            }
            bytes_read += self.sb.block_size;
        }
        return error.NotFound;
    }

    // Path resolution with symlinks and ".."
    //
    // Uses a mutable work buffer so symlink targets and remaining path are
    // composed without heap allocation. Absolute symlinks restart from root;
    // relative symlinks restart from the directory containing the link.

    pub fn lookup(self: *Ext4, path: []const u8) !u32 {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;
        if (path.len >= 4096) return error.PathTooLong;

        var work: [4096]u8 = undefined;
        var work_len: usize = path.len;
        @memcpy(work[0..path.len], path);

        var cur_dir: u32 = EXT4_ROOT_INO;
        var pos: usize = 1; // skip the leading '/'
        var symhops: u32 = 0;

        while (pos < work_len) {
            // Skip slashes.
            while (pos < work_len and work[pos] == '/') pos += 1;
            if (pos >= work_len) break;

            // Extract component.
            const cstart = pos;
            while (pos < work_len and work[pos] != '/') pos += 1;
            const component = work[cstart..pos];
            // pos now points at the first '/' after the component (or == work_len).
            const more_path = (pos < work_len);

            if (std.mem.eql(u8, component, ".")) continue;

            if (std.mem.eql(u8, component, "..")) {
                // Walk to parent; ignore error (root's parent is root).
                cur_dir = self.lookupInDir(cur_dir, "..") catch cur_dir;
                continue;
            }

            const child_ino = try self.lookupInDir(cur_dir, component);
            const child = try self.readInode(child_ino);

            if ((child.mode & S_IFMT) == S_IFLNK) {
                // Read symlink target.
                symhops += 1;
                if (symhops > MAX_SYMLINK_HOPS) return error.TooManySymlinks;

                var tbuf: [4096]u8 = undefined;
                const tlen = try self.readlinkInode(&child, &tbuf);
                if (tlen == 0) return error.BadSymlink;
                const target = tbuf[0..tlen];

                // Compose target + separator + remaining path into work.
                const remaining_len = work_len - pos;
                const need_sep = remaining_len > 0;
                const prefix_len = tlen + (if (need_sep) @as(usize, 1) else 0);
                if (prefix_len + remaining_len >= work.len) return error.PathTooLong;
                if (remaining_len > 0) {
                    std.mem.copyBackwards(
                        u8,
                        work[prefix_len..][0..remaining_len],
                        work[pos..work_len],
                    );
                }
                @memcpy(work[0..tlen], target);
                if (need_sep) work[tlen] = '/';
                work_len = prefix_len + remaining_len;
                pos = 0;

                if (target[0] == '/') {
                    cur_dir = EXT4_ROOT_INO;
                }
                // Relative symlinks: cur_dir stays at the directory that held the link.
                continue;
            }

            if (more_path) {
                if ((child.mode & S_IFMT) != S_IFDIR) return error.NotADirectory;
                cur_dir = child_ino;
            } else {
                return child_ino;
            }
        }
        return cur_dir;
    }

    /// Read up to buf.len bytes from inode_num at offset. Returns bytes read (0 = EOF).
    pub fn readFileInode(self: *Ext4, inode_num: u32, buf: []u8, offset: u64) !usize {
        const inode = try self.readInode(inode_num);
        if (inode.mode & S_IFMT != S_IFREG) return error.NotAFile;
        return self.readDataInode(&inode, buf, offset);
    }

    /// Read up to buf.len bytes from path at offset.
    pub fn readFile(self: *Ext4, path: []const u8, buf: []u8, offset: u64) !usize {
        return self.readFileInode(try self.lookup(path), buf, offset);
    }

    /// Read the symlink target at path into buf. Returns bytes written.
    pub fn readlink(self: *Ext4, path: []const u8, buf: []u8) !usize {
        const ino = try self.lookupNoFollow(path);
        const inode = try self.readInode(ino);
        if ((inode.mode & S_IFMT) != S_IFLNK) return error.NotASymlink;
        return self.readlinkInode(&inode, buf);
    }

    /// Like lookup() but does NOT follow a symlink at the final component.
    pub fn lookupNoFollow(self: *Ext4, path: []const u8) !u32 {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;
        if (path.len >= 4096) return error.PathTooLong;

        // Find the last component, look up the parent via lookup(), then
        // call lookupInDir() without symlink-following for the final name.
        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        const parent_path = if (last_slash == 0) "/" else path[0..last_slash];
        const name = path[last_slash + 1 ..];
        if (name.len == 0) return self.lookup(path); // trailing slash -> lookup the dir

        const parent_ino = try self.lookup(parent_path);
        return self.lookupInDir(parent_ino, name);
    }

    /// Iterate directory entries. callback returns false to stop early.
    pub fn readDir(
        self: *Ext4,
        dir_inode: u32,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), DirEntry) bool,
    ) !void {
        return self.iterDir(dir_inode, ctx, callback);
    }

    pub const Stat = struct {
        inode: u32,
        size: u64,
        mode: u16,
        uid: u32,
        gid: u32,
        nlink: u16,
        atime: u32,
        mtime: u32,
        ctime: u32,
        is_dir: bool,
        is_file: bool,
        is_link: bool,
    };

    pub fn statInode(self: *Ext4, inode_num: u32) !Stat {
        const inode = try self.readInode(inode_num);
        const ft = inode.mode & S_IFMT;
        return .{
            .inode = inode_num,
            .size = inode.size,
            .mode = inode.mode,
            .uid = inode.uid,
            .gid = inode.gid,
            .nlink = inode.nlink,
            .atime = inode.atime,
            .mtime = inode.mtime,
            .ctime = inode.ctime,
            .is_dir = ft == S_IFDIR,
            .is_file = ft == S_IFREG,
            .is_link = ft == S_IFLNK,
        };
    }

    pub fn stat(self: *Ext4, path: []const u8) !Stat {
        return self.statInode(try self.lookup(path));
    }

    /// Write support (journal-unaware; does not log to the ext4 journal).
    /// Safe for filesystems created with `mkfs.ext4 -O ^has_journal`.
    /// On journaled filesystems this may leave the FS in a recoverable-dirty
    /// state; run `e2fsck` on the host if inconsistencies appear.
    fn writeBlock(self: *const Ext4, block_num: u64, buf: *const [MAX_BLOCK_SIZE]u8) !void {
        cacheInvalidateBlock(self.dev_idx, block_num);
        innigkeit.drivers.virtio.blk.writeBytes(
            self.dev_idx,
            block_num * self.sb.block_size,
            buf[0..self.sb.block_size],
        ) catch return error.IoError;
    }

    /// Allocate one free block in the filesystem. Updates the block bitmap and
    /// the group descriptor's free-block counter. Returns the allocated block number.
    fn allocBlock(self: *Ext4) !u64 {
        const blocks_count = blk: {
            var raw: [SUPERBLOCK_SIZE]u8 align(8) = undefined;
            innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, SUPERBLOCK_OFFSET, &raw) catch
                return error.IoError;
            const lo = std.mem.readInt(u32, raw[0x04..0x08], .little);
            const hi = std.mem.readInt(u32, raw[0x150..0x154], .little);
            break :blk (@as(u64, hi) << 32) | lo;
        };

        const num_groups: u32 = @intCast(
            (blocks_count + self.sb.blocks_per_group - 1) / self.sb.blocks_per_group,
        );

        for (0..num_groups) |g| {
            const group: u32 = @intCast(g);
            // Read the block bitmap for this group.
            const bitmap_block = try self.readGroupDescBitmapBlock(group);
            var bitmap: [MAX_BLOCK_SIZE]u8 = undefined;
            try self.readBlock(bitmap_block, &bitmap);

            const first_block = self.sb.first_data_block + @as(u64, group) * self.sb.blocks_per_group;
            const blocks_in_group: u32 = @intCast(@min(
                self.sb.blocks_per_group,
                blocks_count - @as(u64, group) * self.sb.blocks_per_group,
            ));

            // Scan bitmap for a free bit.
            for (0..blocks_in_group) |b| {
                const byte_idx = b / 8;
                const bit_idx: u3 = @intCast(b % 8);
                if (bitmap[byte_idx] & (@as(u8, 1) << bit_idx) == 0) {
                    // Found a free block; mark it used.
                    bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
                    var bm_buf: [MAX_BLOCK_SIZE]u8 = std.mem.zeroes([MAX_BLOCK_SIZE]u8);
                    @memcpy(bm_buf[0..self.sb.block_size], bitmap[0..self.sb.block_size]);
                    try self.writeBlock(bitmap_block, &bm_buf);
                    try self.decrementGroupFreeBlocks(group);
                    try self.decrementSbFreeBlocks();
                    return first_block + b;
                }
            }
        }
        return error.NoSpace;
    }

    fn readGroupDescBitmapBlock(self: *const Ext4, group: u32) !u64 {
        const desc_table_block: u64 = self.sb.first_data_block + 1;
        const byte_offset: u64 = desc_table_block * self.sb.block_size +
            @as(u64, group) * self.sb.desc_size;
        var raw: [64]u8 = undefined;
        innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, byte_offset, raw[0..self.sb.desc_size]) catch
            return error.IoError;
        const lo = std.mem.readInt(u32, raw[0x00..0x04], .little);
        const hi: u32 = if (self.sb.desc_size >= 64) std.mem.readInt(u32, raw[0x20..0x24], .little) else 0;
        return try combineBlockNum(hi, lo);
    }

    fn decrementGroupFreeBlocks(self: *const Ext4, group: u32) !void {
        const desc_table_block: u64 = self.sb.first_data_block + 1;
        const byte_offset: u64 = desc_table_block * self.sb.block_size +
            @as(u64, group) * self.sb.desc_size;
        var raw: [64]u8 = undefined;
        innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, byte_offset, raw[0..self.sb.desc_size]) catch
            return error.IoError;
        const cur = std.mem.readInt(u16, raw[0x0C..0x0E], .little);
        std.mem.writeInt(u16, raw[0x0C..0x0E], cur -| 1, .little);
        innigkeit.drivers.virtio.blk.writeBytes(self.dev_idx, byte_offset, raw[0..self.sb.desc_size]) catch
            return error.IoError;
    }

    fn decrementSbFreeBlocks(self: *const Ext4) !void {
        var raw: [SUPERBLOCK_SIZE]u8 align(8) = undefined;
        innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, SUPERBLOCK_OFFSET, &raw) catch
            return error.IoError;
        const cur = std.mem.readInt(u32, raw[0x0C..0x10], .little);
        std.mem.writeInt(u32, raw[0x0C..0x10], cur -| 1, .little);
        innigkeit.drivers.virtio.blk.writeBytes(self.dev_idx, SUPERBLOCK_OFFSET, &raw) catch
            return error.IoError;
    }

    fn incrementSbFreeBlocks(self: *const Ext4) !void {
        var raw: [SUPERBLOCK_SIZE]u8 align(8) = undefined;
        innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, SUPERBLOCK_OFFSET, &raw) catch
            return error.IoError;
        const cur = std.mem.readInt(u32, raw[0x0C..0x10], .little);
        std.mem.writeInt(u32, raw[0x0C..0x10], cur +| 1, .little);
        innigkeit.drivers.virtio.blk.writeBytes(self.dev_idx, SUPERBLOCK_OFFSET, &raw) catch
            return error.IoError;
    }

    fn freeBlock(self: *Ext4, block_num: u64) !void {
        if (block_num == 0) return;
        const group: u32 = @intCast((block_num - self.sb.first_data_block) / self.sb.blocks_per_group);
        const local: u64 = (block_num - self.sb.first_data_block) % self.sb.blocks_per_group;

        const bitmap_block = try self.readGroupDescBitmapBlock(group);
        var bitmap: [MAX_BLOCK_SIZE]u8 = undefined;
        try self.readBlock(bitmap_block, &bitmap);

        const byte_idx = local / 8;
        const bit_idx: u3 = @intCast(local % 8);
        bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
        var bm_buf: [MAX_BLOCK_SIZE]u8 = std.mem.zeroes([MAX_BLOCK_SIZE]u8);
        @memcpy(bm_buf[0..self.sb.block_size], bitmap[0..self.sb.block_size]);
        try self.writeBlock(bitmap_block, &bm_buf);

        // Update group free-block count.
        const desc_table_block: u64 = self.sb.first_data_block + 1;
        const byte_offset: u64 = desc_table_block * self.sb.block_size +
            @as(u64, group) * self.sb.desc_size;
        var raw: [64]u8 = undefined;
        innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, byte_offset, raw[0..self.sb.desc_size]) catch
            return error.IoError;
        const cur = std.mem.readInt(u16, raw[0x0C..0x0E], .little);
        std.mem.writeInt(u16, raw[0x0C..0x0E], cur + 1, .little);
        innigkeit.drivers.virtio.blk.writeBytes(self.dev_idx, byte_offset, raw[0..self.sb.desc_size]) catch
            return error.IoError;
        try self.incrementSbFreeBlocks();
    }

    /// Allocate a fresh inode. Returns the inode number (1-based).
    fn allocInode(self: *Ext4, mode: u16) !u32 {
        const num_groups: u32 = @intCast(
            (@as(u64, self.sb.inodes_count) + self.sb.inodes_per_group - 1) / self.sb.inodes_per_group,
        );
        for (0..num_groups) |g| {
            const group: u32 = @intCast(g);
            const inode_bitmap_block = try self.readGroupDescInodeBitmapBlock(group);
            var bitmap: [MAX_BLOCK_SIZE]u8 = undefined;
            try self.readBlock(inode_bitmap_block, &bitmap);

            const inodes_in_group: u32 = @intCast(@min(
                self.sb.inodes_per_group,
                self.sb.inodes_count - @as(u64, group) * self.sb.inodes_per_group,
            ));
            for (0..inodes_in_group) |b| {
                const byte_idx = b / 8;
                const bit_idx: u3 = @intCast(b % 8);
                if (bitmap[byte_idx] & (@as(u8, 1) << bit_idx) == 0) {
                    bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
                    var bm_buf: [MAX_BLOCK_SIZE]u8 = std.mem.zeroes([MAX_BLOCK_SIZE]u8);
                    @memcpy(bm_buf[0..self.sb.block_size], bitmap[0..self.sb.block_size]);
                    try self.writeBlock(inode_bitmap_block, &bm_buf);

                    const ino_num: u32 = @intCast(@as(u64, group) * self.sb.inodes_per_group + b + 1);
                    try self.decrementGroupFreeInodes(group);
                    try self.decrementSbFreeInodes();

                    // Write a zeroed inode with the given mode and nlink=1.
                    try self.writeRawInode(ino_num, mode, 1);
                    return ino_num;
                }
            }
        }
        return error.NoSpace;
    }

    fn readGroupDescInodeBitmapBlock(self: *const Ext4, group: u32) !u64 {
        const desc_table_block: u64 = self.sb.first_data_block + 1;
        const byte_offset: u64 = desc_table_block * self.sb.block_size +
            @as(u64, group) * self.sb.desc_size;
        var raw: [64]u8 = undefined;
        innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, byte_offset, raw[0..self.sb.desc_size]) catch
            return error.IoError;
        const lo = std.mem.readInt(u32, raw[0x04..0x08], .little);
        const hi: u32 = if (self.sb.desc_size >= 64) std.mem.readInt(u32, raw[0x24..0x28], .little) else 0;
        return (@as(u64, hi) << 32) | lo;
    }

    fn decrementGroupFreeInodes(self: *const Ext4, group: u32) !void {
        const desc_table_block: u64 = self.sb.first_data_block + 1;
        const byte_offset: u64 = desc_table_block * self.sb.block_size +
            @as(u64, group) * self.sb.desc_size;
        var raw: [64]u8 = undefined;
        innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, byte_offset, raw[0..self.sb.desc_size]) catch
            return error.IoError;
        const cur = std.mem.readInt(u16, raw[0x0E..0x10], .little);
        std.mem.writeInt(u16, raw[0x0E..0x10], cur -| 1, .little);
        innigkeit.drivers.virtio.blk.writeBytes(self.dev_idx, byte_offset, raw[0..self.sb.desc_size]) catch
            return error.IoError;
    }

    fn decrementSbFreeInodes(self: *const Ext4) !void {
        var raw: [SUPERBLOCK_SIZE]u8 align(8) = undefined;
        innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, SUPERBLOCK_OFFSET, &raw) catch
            return error.IoError;
        const cur = std.mem.readInt(u32, raw[0x10..0x14], .little);
        std.mem.writeInt(u32, raw[0x10..0x14], cur -| 1, .little);
        innigkeit.drivers.virtio.blk.writeBytes(self.dev_idx, SUPERBLOCK_OFFSET, &raw) catch
            return error.IoError;
    }

    fn writeRawInode(self: *const Ext4, inode_num: u32, mode: u16, nlink: u16) !void {
        const idx = inode_num - 1;
        const group = idx / self.sb.inodes_per_group;
        const local = idx % self.sb.inodes_per_group;
        const gd = try self.readGroupDesc(group);
        const off: u64 = gd.inode_table * self.sb.block_size +
            @as(u64, local) * self.sb.inode_size;
        var raw: [256]u8 = std.mem.zeroes([256]u8);
        std.mem.writeInt(u16, raw[0x00..0x02], mode, .little);
        std.mem.writeInt(u16, raw[0x1A..0x1C], nlink, .little);
        // EXT4_EXTENTS_FL so new files use the extent tree.
        std.mem.writeInt(u32, raw[0x20..0x24], EXT4_EXTENTS_FL, .little);
        // Initialize the extent header inside i_block.
        std.mem.writeInt(u16, raw[0x28..0x2A], EXT4_EXTENT_MAGIC, .little); // magic
        std.mem.writeInt(u16, raw[0x2A..0x2C], 0, .little); // entries = 0
        std.mem.writeInt(u16, raw[0x2C..0x2E], 4, .little); // max = 4 inline extents
        std.mem.writeInt(u16, raw[0x2E..0x30], 0, .little); // depth = 0
        innigkeit.drivers.virtio.blk.writeBytes(self.dev_idx, off, raw[0..@min(self.sb.inode_size, 256)]) catch
            return error.IoError;
    }

    /// Persist inode fields (size, flags, nlink, i_block) back to disk.
    fn writeInode(self: *const Ext4, inode_num: u32, inode: *const Inode) !void {
        const idx = inode_num - 1;
        const group = idx / self.sb.inodes_per_group;
        const local = idx % self.sb.inodes_per_group;
        const gd = try self.readGroupDesc(group);
        const off: u64 = gd.inode_table * self.sb.block_size +
            @as(u64, local) * self.sb.inode_size;

        const read_size: usize = @min(self.sb.inode_size, 256);
        var raw: [256]u8 = std.mem.zeroes([256]u8);
        // Read existing to preserve fields we don't manage.
        innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, off, raw[0..read_size]) catch
            return error.IoError;

        const size_lo: u32 = @truncate(inode.size);
        const size_hi: u32 = @truncate(inode.size >> 32);
        std.mem.writeInt(u16, raw[0x00..0x02], inode.mode, .little);
        std.mem.writeInt(u32, raw[0x04..0x08], size_lo, .little);
        if (read_size >= 0x70) std.mem.writeInt(u32, raw[0x6C..0x70], size_hi, .little);
        std.mem.writeInt(u16, raw[0x1A..0x1C], inode.nlink, .little);
        std.mem.writeInt(u32, raw[0x20..0x24], inode.flags, .little);
        @memcpy(raw[0x28..0x64], &inode.i_block);

        innigkeit.drivers.virtio.blk.writeBytes(self.dev_idx, off, raw[0..read_size]) catch
            return error.IoError;
    }

    /// Append a directory entry for `name` -> `child_ino` in `dir_ino`.
    /// Only works when the last directory block has enough space; otherwise
    /// allocates a new block.
    fn addDirEntry(self: *Ext4, dir_ino: u32, name: []const u8, child_ino: u32, file_type: u8) !void {
        var dir = try self.readInode(dir_ino);
        if (dir.mode & S_IFMT != S_IFDIR) return error.NotADirectory;
        if (name.len > 255) return error.NameTooLong;

        const needed_len: u16 = @intCast((8 + name.len + 3) & ~@as(usize, 3)); // round to 4

        // Try to fit in the last existing block.
        if (dir.size > 0) {
            const last_lb: u32 = @intCast((dir.size - 1) / self.sb.block_size);
            const last_phys = try self.mapBlock(&dir, last_lb);
            if (last_phys != 0) {
                var block_buf: [MAX_BLOCK_SIZE]u8 = undefined;
                try self.readBlock(last_phys, &block_buf);

                var it: DirBlockIter = .init(block_buf[0..self.sb.block_size]);
                while (it.next()) |rec| {
                    const off = rec.off;
                    const rec_len = rec.entry.rec_len;
                    const actual_used: u16 = @intCast((8 + @as(u32, rec.entry.name_len) + 3) & ~@as(u32, 3));
                    if (rec_len < actual_used) break; // corrupt padding; bail to new-block path
                    const slack: u16 = rec_len - actual_used;
                    if (off + rec_len >= self.sb.block_size or slack >= needed_len) {
                        // Last real entry or one with enough slack: split here.
                        const insert_off = off + actual_used;
                        if (insert_off + needed_len <= self.sb.block_size) {
                            // Trim current entry's rec_len, add new entry after.
                            std.mem.writeInt(u16, block_buf[off + 4 ..][0..2], actual_used, .little);
                            const new_rec_len: u16 = @intCast(self.sb.block_size - insert_off);
                            std.mem.writeInt(u32, block_buf[insert_off..][0..4], child_ino, .little);
                            std.mem.writeInt(u16, block_buf[insert_off + 4 ..][0..2], new_rec_len, .little);
                            block_buf[insert_off + 6] = @intCast(name.len);
                            block_buf[insert_off + 7] = file_type;
                            @memcpy(block_buf[insert_off + 8 ..][0..name.len], name);
                            var write_buf: [MAX_BLOCK_SIZE]u8 = std.mem.zeroes([MAX_BLOCK_SIZE]u8);
                            @memcpy(write_buf[0..self.sb.block_size], block_buf[0..self.sb.block_size]);
                            try self.writeBlock(last_phys, &write_buf);
                            return;
                        }
                    }
                }
            }
        }

        // Need a new block for the directory.
        const new_block = try self.allocBlock();
        var block_buf: [MAX_BLOCK_SIZE]u8 = std.mem.zeroes([MAX_BLOCK_SIZE]u8);
        std.mem.writeInt(u32, block_buf[0..4], child_ino, .little);
        const rec_len: u16 = @intCast(self.sb.block_size);
        std.mem.writeInt(u16, block_buf[4..6], rec_len, .little);
        block_buf[6] = @intCast(name.len);
        block_buf[7] = file_type;
        @memcpy(block_buf[8..][0..name.len], name);
        try self.writeBlock(new_block, &block_buf);

        // Append a new leaf extent to the inode.
        try self.appendExtent(&dir, dir_ino, @intCast(dir.size / self.sb.block_size), new_block);
        dir.size += self.sb.block_size;
        try self.writeInode(dir_ino, &dir);
    }

    /// Append a single leaf extent mapping logical block `lb` -> physical `pb`
    /// into the inode's inline extent tree. Panics if the tree is full (>4 extents).
    fn appendExtent(self: *const Ext4, inode: *const Inode, inode_num: u32, lb: u32, pb: u64) !void {
        var i_block = inode.i_block;
        var hdr: ExtentHeader = undefined;
        @memcpy(std.mem.asBytes(&hdr), i_block[0..@sizeOf(ExtentHeader)]);
        const magic = std.mem.littleToNative(u16, hdr.magic);
        const entries = std.mem.littleToNative(u16, hdr.entries);
        const max = std.mem.littleToNative(u16, hdr.max);
        if (magic != EXT4_EXTENT_MAGIC) return error.BadExtentMagic;
        if (std.mem.littleToNative(u16, hdr.depth) != 0) return error.ExtentTreeTooDeep;
        if (entries >= max) return error.ExtentTreeFull;

        // Write a new Extent entry at the next slot.
        const slot_off = 12 + @as(usize, entries) * @sizeOf(Extent);
        var ext: Extent = .{
            .block = std.mem.nativeToLittle(u32, lb),
            .len = std.mem.nativeToLittle(u16, 1),
            .start_hi = std.mem.nativeToLittle(u16, @intCast(pb >> 32)),
            .start_lo = std.mem.nativeToLittle(u32, @truncate(pb)),
        };
        @memcpy(i_block[slot_off..][0..@sizeOf(Extent)], std.mem.asBytes(&ext));

        // Bump entries count in the header.
        std.mem.writeInt(u16, i_block[2..4], entries + 1, .little);

        // Write back by constructing a temporary Inode with the updated i_block.
        var updated = inode.*;
        updated.i_block = i_block;
        try self.writeInode(inode_num, &updated);
    }

    /// Write `data` to a regular file at `offset`, extending it if needed.
    /// The file's extent tree must remain a depth-0 (leaf-only) tree.
    /// Returns the number of bytes written.
    pub fn writeFileInode(self: *Ext4, inode_num: u32, data: []const u8, offset: u64) !usize {
        var inode = try self.readInode(inode_num);
        if (inode.mode & S_IFMT != S_IFREG) return error.NotAFile;
        if (data.len == 0) return 0;

        var written: usize = 0;
        while (written < data.len) {
            const pos: u64 = offset + written;
            const lb: u32 = @intCast(pos / self.sb.block_size);
            const block_off: u32 = @intCast(pos % self.sb.block_size);

            // Map or allocate the physical block.
            const phys: u64 = blk: {
                const mapped = try self.mapBlock(&inode, lb);
                if (mapped != 0) break :blk mapped;
                const new_phys = try self.allocBlock();
                const zero: [MAX_BLOCK_SIZE]u8 = std.mem.zeroes([MAX_BLOCK_SIZE]u8);
                try self.writeBlock(new_phys, &zero);
                try self.appendExtent(&inode, inode_num, lb, new_phys);
                inode = try self.readInode(inode_num);
                break :blk new_phys;
            };

            // Read-modify-write the block.
            var block_buf: [MAX_BLOCK_SIZE]u8 = undefined;
            try self.readBlock(phys, &block_buf);
            const chunk = @min(data.len - written, self.sb.block_size - block_off);
            @memcpy(block_buf[block_off..][0..chunk], data[written..][0..chunk]);
            var write_buf: [MAX_BLOCK_SIZE]u8 = std.mem.zeroes([MAX_BLOCK_SIZE]u8);
            @memcpy(write_buf[0..self.sb.block_size], block_buf[0..self.sb.block_size]);
            try self.writeBlock(phys, &write_buf);
            cacheInvalidateBlock(self.dev_idx, phys);

            written += chunk;
        }

        // Update file size if extended.
        const new_end = offset + written;
        if (new_end > inode.size) {
            inode.size = new_end;
            try self.writeInode(inode_num, &inode);
        }
        return written;
    }

    pub fn writeFile(self: *Ext4, path: []const u8, data: []const u8, offset: u64) !usize {
        return self.writeFileInode(try self.lookup(path), data, offset);
    }

    /// Truncate a file to `new_size` bytes. Frees any blocks past `new_size`.
    pub fn truncateInode(self: *Ext4, inode_num: u32, new_size: u64) !void {
        var inode = try self.readInode(inode_num);
        if (inode.mode & S_IFMT != S_IFREG) return error.NotAFile;
        if (new_size >= inode.size) {
            inode.size = new_size;
            try self.writeInode(inode_num, &inode);
            return;
        }

        // Free blocks past new_size.
        const first_free_lb = divCeilClampU32(new_size, self.sb.block_size);
        const old_last_lb = divCeilClampU32(inode.size, self.sb.block_size);
        var lb = first_free_lb;
        while (lb < old_last_lb) : (lb += 1) {
            const phys = self.mapBlock(&inode, lb) catch continue;
            if (phys != 0) self.freeBlock(phys) catch {};
        }

        // Truncate the inline extent tree (remove entries with block >= first_free_lb).
        var i_block = inode.i_block;
        var hdr: ExtentHeader = undefined;
        @memcpy(std.mem.asBytes(&hdr), i_block[0..@sizeOf(ExtentHeader)]);
        if (std.mem.littleToNative(u16, hdr.magic) == EXT4_EXTENT_MAGIC and
            std.mem.littleToNative(u16, hdr.depth) == 0)
        {
            const n = std.mem.littleToNative(u16, hdr.entries);
            var new_n: u16 = 0;
            for (0..n) |i| {
                const off = 12 + i * @sizeOf(Extent);
                var ext: Extent = undefined;
                @memcpy(std.mem.asBytes(&ext), i_block[off..][0..@sizeOf(Extent)]);
                if (std.mem.littleToNative(u32, ext.block) < first_free_lb) {
                    // Possibly trim the length of the last retained extent.
                    const ee_block = std.mem.littleToNative(u32, ext.block);
                    const ee_len = std.mem.littleToNative(u16, ext.len) & 0x7FFF;
                    if (ee_block + ee_len > first_free_lb) {
                        const trimmed: u16 = @intCast(first_free_lb - ee_block);
                        std.mem.writeInt(u16, i_block[off + 4 ..][0..2], trimmed, .little);
                    }
                    @memcpy(i_block[12 + new_n * @sizeOf(Extent) ..][0..@sizeOf(Extent)], i_block[off..][0..@sizeOf(Extent)]);
                    new_n += 1;
                }
            }
            std.mem.writeInt(u16, i_block[2..4], new_n, .little);
            inode.i_block = i_block;
        }

        inode.size = new_size;
        try self.writeInode(inode_num, &inode);
    }

    /// Create a new regular file at `path`. The parent directory must exist.
    /// Returns the new inode number.
    pub fn createFile(self: *Ext4, path: []const u8) !u32 {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;

        // Ensure it doesn't already exist.
        if (self.lookup(path)) |_| return error.AlreadyExists else |_| {}

        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidPath;
        const parent_path = if (last_slash == 0) "/" else path[0..last_slash];
        const name = path[last_slash + 1 ..];
        if (name.len == 0 or name.len > 255) return error.InvalidPath;

        const parent_ino = try self.lookup(parent_path);
        const ino = try self.allocInode(S_IFREG | 0o644);
        try self.addDirEntry(parent_ino, name, ino, 1); // 1 = regular file
        return ino;
    }

    /// Delete a regular file at `path` (unlink). Frees data blocks + inode.
    pub fn deleteFile(self: *Ext4, path: []const u8) !void {
        const ino = try self.lookup(path);
        const inode = try self.readInode(ino);
        if (inode.mode & S_IFMT != S_IFREG) return error.NotAFile;

        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidPath;
        const parent_path = if (last_slash == 0) "/" else path[0..last_slash];
        const name = path[last_slash + 1 ..];
        const parent_ino = try self.lookup(parent_path);

        // Remove the directory entry.
        try self.removeDirEntry(parent_ino, name);

        // If nlink reaches 0, free all data blocks and the inode.
        if (inode.nlink <= 1) {
            try self.truncateInode(ino, 0);
            try self.freeInode(ino, inode.mode);
        }
    }

    fn removeDirEntry(self: *Ext4, dir_ino: u32, name: []const u8) !void {
        var dir = try self.readInode(dir_ino);
        if (dir.mode & S_IFMT != S_IFDIR) return error.NotADirectory;

        var block_buf: [MAX_BLOCK_SIZE]u8 = undefined;
        var bytes_read: u64 = 0;
        while (bytes_read < dir.size) {
            const lb: u32 = @intCast(bytes_read / self.sb.block_size);
            const phys = try self.mapBlock(&dir, lb);
            if (phys != 0) try self.readBlock(phys, &block_buf) else {
                bytes_read += self.sb.block_size;
                continue;
            }

            var it: DirBlockIter = .init(block_buf[0..self.sb.block_size]);
            var prev: ?DirBlockIter.Rec = null;
            while (it.next()) |rec| {
                if (rec.entry.inode != 0 and std.mem.eql(u8, rec.entry.name, name)) {
                    if (prev) |p| {
                        // Merge this record into the previous one (extend prev
                        // rec_len). Both records were validated to lie inside
                        // the block and are adjacent, so the sum fits in u16.
                        std.mem.writeInt(u16, block_buf[p.off + 4 ..][0..2], p.entry.rec_len + rec.entry.rec_len, .little);
                    } else {
                        // First entry: zero the inode field to mark as deleted.
                        std.mem.writeInt(u32, block_buf[rec.off..][0..4], 0, .little);
                    }
                    var write_buf: [MAX_BLOCK_SIZE]u8 = std.mem.zeroes([MAX_BLOCK_SIZE]u8);
                    @memcpy(write_buf[0..self.sb.block_size], block_buf[0..self.sb.block_size]);
                    try self.writeBlock(phys, &write_buf);
                    return;
                }
                prev = rec;
            }
            bytes_read += self.sb.block_size;
        }
        return error.NotFound;
    }

    fn freeInode(self: *Ext4, inode_num: u32, mode: u16) !void {
        _ = mode;
        const idx = inode_num - 1;
        const group: u32 = @intCast(idx / self.sb.inodes_per_group);
        const local: u32 = @intCast(idx % self.sb.inodes_per_group);

        const inode_bitmap_block = try self.readGroupDescInodeBitmapBlock(group);
        var bitmap: [MAX_BLOCK_SIZE]u8 = undefined;
        try self.readBlock(inode_bitmap_block, &bitmap);
        const byte_idx = local / 8;
        const bit_idx: u3 = @intCast(local % 8);
        bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
        var bm_buf: [MAX_BLOCK_SIZE]u8 = std.mem.zeroes([MAX_BLOCK_SIZE]u8);
        @memcpy(bm_buf[0..self.sb.block_size], bitmap[0..self.sb.block_size]);
        try self.writeBlock(inode_bitmap_block, &bm_buf);

        // Update free inode count in group descriptor.
        const desc_table_block: u64 = self.sb.first_data_block + 1;
        const byte_offset: u64 = desc_table_block * self.sb.block_size +
            @as(u64, group) * self.sb.desc_size;
        var raw: [64]u8 = undefined;
        innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, byte_offset, raw[0..self.sb.desc_size]) catch
            return error.IoError;
        const cur = std.mem.readInt(u16, raw[0x0E..0x10], .little);
        std.mem.writeInt(u16, raw[0x0E..0x10], cur + 1, .little);
        innigkeit.drivers.virtio.blk.writeBytes(self.dev_idx, byte_offset, raw[0..self.sb.desc_size]) catch
            return error.IoError;

        // Increment sb free inode count.
        var sb_raw: [SUPERBLOCK_SIZE]u8 align(8) = undefined;
        innigkeit.drivers.virtio.blk.readBytes(self.dev_idx, SUPERBLOCK_OFFSET, &sb_raw) catch
            return error.IoError;
        const sb_cur = std.mem.readInt(u32, sb_raw[0x10..0x14], .little);
        std.mem.writeInt(u32, sb_raw[0x10..0x14], sb_cur + 1, .little);
        innigkeit.drivers.virtio.blk.writeBytes(self.dev_idx, SUPERBLOCK_OFFSET, &sb_raw) catch
            return error.IoError;
    }
};

/// Test helper: write one ext4_dir_entry_2 record into `buf` at `off`.
fn writeTestDirRec(buf: []u8, off: usize, ino: u32, rec_len: u16, name_len: u8, file_type: u8, name: []const u8) void {
    std.mem.writeInt(u32, buf[off..][0..4], ino, .little);
    std.mem.writeInt(u16, buf[off + 4 ..][0..2], rec_len, .little);
    buf[off + 6] = name_len;
    buf[off + 7] = file_type;
    @memcpy(buf[off + 8 ..][0..name.len], name);
}

test "ext4: dir block iterator yields valid entries" {
    var block = [_]u8{0} ** 1024;
    // "." (inode 11, dir) followed by "hello" (inode 42, regular file) whose
    // rec_len covers the rest of the block, as ext4 lays out directory blocks.
    writeTestDirRec(&block, 0, 11, 12, 1, 2, ".");
    writeTestDirRec(&block, 12, 42, 1024 - 12, 5, 1, "hello");

    var it: DirBlockIter = .init(&block);

    const a = it.next() orelse return error.MissingEntry;
    try std.testing.expectEqual(@as(u32, 0), a.off);
    try std.testing.expectEqual(@as(u32, 11), a.entry.inode);
    try std.testing.expectEqual(@as(u8, 2), a.entry.file_type);
    try std.testing.expectEqualSlices(u8, ".", a.entry.name);

    const b = it.next() orelse return error.MissingEntry;
    try std.testing.expectEqual(@as(u32, 12), b.off);
    try std.testing.expectEqual(@as(u32, 42), b.entry.inode);
    try std.testing.expectEqual(@as(u16, 1012), b.entry.rec_len);
    try std.testing.expectEqualSlices(u8, "hello", b.entry.name);

    // The second record extends to the block end, so iteration is done.
    try std.testing.expect(it.next() == null);
}

test "ext4: dir block iterator terminates on malformed records" {
    var block = [_]u8{0} ** 1024;

    // (a) rec_len == 0 must not loop forever: rejected immediately.
    writeTestDirRec(&block, 0, 7, 0, 1, 1, "x");
    var it_zero: DirBlockIter = .init(&block);
    try std.testing.expect(it_zero.next() == null);

    // (b) rec_len overrunning the block end: the valid first entry is
    // yielded, the overrunning second entry terminates iteration.
    @memset(&block, 0);
    writeTestDirRec(&block, 0, 11, 12, 1, 2, ".");
    writeTestDirRec(&block, 12, 42, 2048, 5, 1, "hello"); // 12 + 2048 > 1024
    var it_overrun: DirBlockIter = .init(&block);
    const first = it_overrun.next() orelse return error.MissingEntry;
    try std.testing.expectEqual(@as(u32, 11), first.entry.inode);
    try std.testing.expect(it_overrun.next() == null);

    // (c) name_len overrunning rec_len: 8 + 20 > 12, rejected.
    @memset(&block, 0);
    writeTestDirRec(&block, 0, 9, 12, 20, 1, "abc");
    var it_name: DirBlockIter = .init(&block);
    try std.testing.expect(it_name.next() == null);
}
