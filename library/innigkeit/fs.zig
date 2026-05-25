//! Userspace filesystem access.
//!
//! initfsRead reads from the kernel-embedded initfs (POSIX ustar archive).
//! This is the bootstrap filesystem which is available before any VFS server starts.
//! Future: vfsOpen/vfsRead/etc. will replace this once a VFS server is running.

const innigkeit = @import("innigkeit");

/// ABI struct for the initfs_read syscall (must match kernel's InitfsReadSpec).
const InitfsReadSpec = extern struct {
    name_ptr: usize,
    name_len: u32,
    _pad: u32 = 0,
    buf_ptr: usize,
    buf_len: usize,
};

/// Read `name` from initfs into `buf`. Returns the number of bytes copied.
///
/// If buf is shorter than the file, only buf.len bytes are copied (truncated).
/// Returns error.NotFound if the file doesn't exist in initfs.
pub fn initfsRead(name: []const u8, buf: []u8) innigkeit.Syscall.Error!usize {
    const spec = InitfsReadSpec{
        .name_ptr = @intFromPtr(name.ptr),
        .name_len = @intCast(name.len),
        .buf_ptr = @intFromPtr(buf.ptr),
        .buf_len = buf.len,
    };
    const result = innigkeit.Syscall.invoke(.initfs_read, .{@intFromPtr(&spec)});
    return innigkeit.Syscall.decode(result);
}

/// Return the size of `name` in initfs without copying data.
///
/// Returns error.NotFound if the file doesn't exist.
pub fn initfsSize(name: []const u8) innigkeit.Syscall.Error!usize {
    const spec = InitfsReadSpec{
        .name_ptr = @intFromPtr(name.ptr),
        .name_len = @intCast(name.len),
        .buf_ptr = 0,
        .buf_len = 0,
    };
    const result = innigkeit.Syscall.invoke(.initfs_read, .{@intFromPtr(&spec)});
    return innigkeit.Syscall.decode(result);
}

/// ABI struct for the blk_read syscall (must match kernel's BlkReadSpec).
const BlkReadSpec = extern struct {
    byte_offset: u64,
    buf_ptr: usize,
    buf_len: usize,
};

/// Read bytes from the data disk (virtio-blk device 1) at `byte_offset` into `buf`.
///
/// Returns error.NoDevice if no data disk is present.
pub fn blkRead(byte_offset: u64, buf: []u8) innigkeit.Syscall.Error!usize {
    const spec = BlkReadSpec{
        .byte_offset = byte_offset,
        .buf_ptr = @intFromPtr(buf.ptr),
        .buf_len = buf.len,
    };
    const result = innigkeit.Syscall.invoke(.blk_read, .{@intFromPtr(&spec)});
    return innigkeit.Syscall.decode(result);
}
