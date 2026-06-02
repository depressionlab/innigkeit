//! Minimal VFS shim: picks ext4 (if present on the data disk) or simple_fs.
//!
//! Call `vfs.init()` once from stage4 after virtio-blk is ready.
//! Thereafter `vfs.open/read/write/close/sync` behave like simple_fs
//! but route through ext4 when available.

const std = @import("std");
const innigkeit = @import("innigkeit");
const simple_fs = @import("simple_fs.zig");
const Ext4 = @import("ext4.zig").Ext4;

const log = innigkeit.debug.log.scoped(.vfs);

var ext4_mounted: bool = false;
var ext4_fs: Ext4 = undefined;

/// Try to mount ext4 on the data device.  Falls back to simple_fs silently.
pub fn init() void {
    if (!innigkeit.drivers.virtio.blk.isDataReady()) return;
    const dev = innigkeit.drivers.virtio.blk.dataDeviceIndex();
    ext4_fs = Ext4.mount(dev) catch |err| {
        log.debug("vfs: ext4 mount failed ({t}), using simple_fs", .{err});
        return;
    };
    ext4_mounted = true;
    log.info("vfs: ext4 mounted on device {}", .{dev});
}

pub fn isExt4() bool {
    return ext4_mounted;
}

pub const OpenFlags = simple_fs.OpenFlags;

pub const OpenFile = struct {
    /// Variant tag.
    is_ext4: bool,
    /// Simple_fs path (used when is_ext4 == false).
    simple: simple_fs.OpenFile,
    /// Ext4 inode and position (used when is_ext4 == true).
    ext4_ino: u32,
    ext4_pos: u64,
    ext4_size: u64,
    ext4_writable: bool,
};

pub fn open(name: []const u8, flags: OpenFlags) !OpenFile {
    if (!ext4_mounted) {
        const f = try simple_fs.open(name, flags);
        return OpenFile{ .is_ext4 = false, .simple = f, .ext4_ino = 0, .ext4_pos = 0, .ext4_size = 0, .ext4_writable = false };
    }

    // Build an absolute path: files live in the root directory.
    var path_buf: [64]u8 = undefined;
    if (name.len + 1 >= path_buf.len) return error.InvalidArgument;
    path_buf[0] = '/';
    @memcpy(path_buf[1..][0..name.len], name);
    const path = path_buf[0 .. name.len + 1];

    if (flags.create) {
        // Create if not found.
        const ino = ext4_fs.lookup(path) catch ext4_fs.createFile(path) catch |e| return e;
        if (flags.truncate) {
            ext4_fs.truncateInode(ino, 0) catch |e| return e;
        }
        const stat = try ext4_fs.statInode(ino);
        return OpenFile{ .is_ext4 = true, .simple = undefined, .ext4_ino = ino, .ext4_pos = if (flags.truncate) 0 else stat.size, .ext4_size = stat.size, .ext4_writable = true };
    }

    const ino = ext4_fs.lookup(path) catch return error.NotFound;
    const stat = try ext4_fs.statInode(ino);
    if (!stat.is_file) return error.NotFound;
    return OpenFile{ .is_ext4 = true, .simple = undefined, .ext4_ino = ino, .ext4_pos = 0, .ext4_size = stat.size, .ext4_writable = false };
}

pub fn read(file: *OpenFile, buf: []u8) !usize {
    if (!file.is_ext4) return simple_fs.read(&file.simple, buf);

    if (file.ext4_pos >= file.ext4_size) return 0;
    const n = try ext4_fs.readFileInode(file.ext4_ino, buf, file.ext4_pos);
    file.ext4_pos += n;
    return n;
}

pub fn write(file: *OpenFile, buf: []const u8) !usize {
    if (!file.is_ext4) return simple_fs.write(&file.simple, buf);

    if (!file.ext4_writable) return error.PermissionDenied;
    const n = try ext4_fs.writeFileInode(file.ext4_ino, buf, file.ext4_pos);
    file.ext4_pos += n;
    if (file.ext4_pos > file.ext4_size) file.ext4_size = file.ext4_pos;
    return n;
}

pub fn sync(file: *OpenFile) !void {
    if (!file.is_ext4) return simple_fs.sync(&file.simple);
    // Ext4 writes are synchronous (each write goes to disk immediately).
}

pub fn close(file: *OpenFile) void {
    if (!file.is_ext4) {
        simple_fs.close(&file.simple);
        return;
    }
    // Nothing to flush. ext4 writes are synchronous.
}
