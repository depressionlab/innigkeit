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

var block_cache: [CACHE_SIZE]CacheEntry = .{.{}} ** CACHE_SIZE;
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
    for (block_cache, 0..) |*e, i| {
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
        const block_size: u32 = @as(u32, 1024) << @intCast(log_block_size);
        if (block_size > MAX_BLOCK_SIZE) return error.BlockSizeTooLarge;

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

        return .{ .inode_table = (@as(u64, hi) << 32) | lo };
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

    fn mapBlock(self: *const Ext4, inode: *const Inode, logical: u32) !u32 {
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
                const phys: u64 = (@as(u64, start_hi) << 32 | start_lo) + (logical - ee_block);
                return @intCast(phys);
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

            var off: u32 = 0;
            while (off + 8 <= self.sb.block_size) {
                const ino_num = std.mem.readInt(u32, block_buf[off..][0..4], .little);
                const rec_len = std.mem.readInt(u16, block_buf[off + 4 ..][0..2], .little);
                if (rec_len < 8) break;
                const nl = block_buf[off + 6];
                const ft = block_buf[off + 7];
                if (ino_num != 0 and nl > 0 and off + 8 + nl <= self.sb.block_size) {
                    const entry: DirEntry = .{
                        .inode = ino_num,
                        .rec_len = rec_len,
                        .name_len = nl,
                        .file_type = ft,
                        .name = block_buf[off + 8 ..][0..nl],
                    };
                    if (!cb(ctx, entry)) return;
                }
                off += rec_len;
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

            var off: u32 = 0;
            while (off + 8 <= self.sb.block_size) {
                const ino_num = std.mem.readInt(u32, block_buf[off..][0..4], .little);
                const rec_len = std.mem.readInt(u16, block_buf[off + 4 ..][0..2], .little);
                if (rec_len < 8) break;
                const nl = block_buf[off + 6];
                if (ino_num != 0 and nl == name.len and off + 8 + nl <= self.sb.block_size) {
                    if (std.mem.eql(u8, block_buf[off + 8 ..][0..nl], name)) return ino_num;
                }
                off += rec_len;
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
};
