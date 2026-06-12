//! Userspace filesystem access.
//!
//! `File` is the general-purpose API: it opens paths through the kernel VFS
//! (ext4 when mounted, simple_fs otherwise) into the per-process
//! file-descriptor table and supports read/write/seek/stat/close plus
//! `std.Io` reader/writer integration.
//!
//! initfsRead reads from the kernel-embedded initfs (POSIX ustar archive).
//! This is the bootstrap filesystem which is available before any VFS server starts.
//! Future: vfsOpen/vfsRead/etc. will replace this once a VFS server is running.

const std = @import("std");
const innigkeit = @import("innigkeit");

/// Flags for `File.open`.
pub const OpenFlags = packed struct(u32) {
    /// Open for writing; creates the file if it does not exist.
    /// Requires the storage entitlement.
    write: bool = false,
    _: u31 = 0,
};

/// Origin for `File.seek`.
pub const Whence = enum(u32) {
    set = 0,
    cur = 1,
    end = 2,
};

/// Descriptor kind reported by `File.stat`.
pub const Kind = enum(u8) {
    file = 0,
    directory = 1,
    tty = 2,
    _,
};

/// ABI struct filled by the fstat syscall (must match the kernel's
/// FdTable.Stat).
pub const Stat = extern struct {
    size: u64,
    kind: u8,
    _pad: [7]u8 = @splat(0),

    pub fn getKind(self: Stat) Kind {
        return @enumFromInt(self.kind);
    }
};

/// A file opened through the kernel VFS into the per-process fd table.
///
/// ```zig
/// const f = try innigkeit.fs.File.open("notes.txt", .{});
/// defer f.close();
/// var buf: [256]u8 = undefined;
/// const n = try f.read(&buf);
/// ```
pub const File = struct {
    fd: u32,

    /// Open `path` (leading '/' optional; the VFS is rooted at "/").
    pub fn open(path: []const u8, flags: OpenFlags) innigkeit.Syscall.Error!File {
        const result = innigkeit.Syscall.invoke(.open, .{
            @intFromPtr(path.ptr),
            path.len,
            @as(usize, @as(u32, @bitCast(flags))),
        });
        return .{ .fd = @intCast(try innigkeit.Syscall.decode(result)) };
    }

    /// Read up to `buf.len` bytes at the current offset; advances the offset.
    /// Returns the number of bytes read (0 at EOF).
    pub fn read(self: File, buf: []u8) innigkeit.Syscall.Error!usize {
        const result = innigkeit.Syscall.invoke(.read, .{
            @as(usize, self.fd),
            @intFromPtr(buf.ptr),
            buf.len,
        });
        return innigkeit.Syscall.decode(result);
    }

    /// Write `data` at the current offset; advances the offset.
    /// Returns the number of bytes written.
    pub fn write(self: File, data: []const u8) innigkeit.Syscall.Error!usize {
        const result = innigkeit.Syscall.invoke(.write, .{
            @as(usize, self.fd),
            @intFromPtr(data.ptr),
            data.len,
        });
        return innigkeit.Syscall.decode(result);
    }

    /// Write all of `data`, looping on partial writes.
    pub fn writeAll(self: File, data: []const u8) innigkeit.Syscall.Error!void {
        var remaining = data;
        while (remaining.len > 0) {
            const n = try self.write(remaining);
            if (n == 0) return error.IoError;
            remaining = remaining[n..];
        }
    }

    /// Reposition the file offset. Returns the new offset.
    pub fn seek(self: File, offset: i64, whence: Whence) innigkeit.Syscall.Error!u64 {
        const result = innigkeit.Syscall.invoke(.lseek, .{
            @as(usize, self.fd),
            @as(usize, @bitCast(offset)),
            @as(usize, @intFromEnum(whence)),
        });
        return @intCast(try innigkeit.Syscall.decode(result));
    }

    /// Query size and kind of the descriptor.
    pub fn stat(self: File) innigkeit.Syscall.Error!Stat {
        var out: Stat = undefined;
        const result = innigkeit.Syscall.invoke(.fstat, .{
            @as(usize, self.fd),
            @intFromPtr(&out),
        });
        _ = try innigkeit.Syscall.decode(result);
        return out;
    }

    /// Close the descriptor. Errors (e.g. double close) are ignored.
    pub fn close(self: File) void {
        _ = innigkeit.Syscall.invoke(.close, .{@as(usize, self.fd)});
    }

    /// Return a `Reader` whose `.interface` is a `std.Io.Reader` usable with
    /// stdlib APIs. `buffer` is the reader's internal buffer; it must outlive
    /// the returned value. Do not move the result after first use.
    pub fn reader(self: File, buffer: []u8) Reader {
        return .init(self, buffer);
    }

    /// Return a `Writer` whose `.interface` is an unbuffered `std.Io.Writer`
    /// (matching the io.zig style: every write goes directly to the syscall).
    /// Do not move the result after first use.
    pub fn writer(self: File) Writer {
        return .init(self);
    }

    /// `std.Io.Reader` adapter over a `File`.
    pub const Reader = struct {
        file: File,
        interface: std.Io.Reader,

        pub fn init(file: File, buffer: []u8) Reader {
            return .{
                .file = file,
                .interface = .{
                    .vtable = &.{ .stream = stream },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn stream(
            r: *std.Io.Reader,
            w: *std.Io.Writer,
            limit: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            const self: *Reader = @alignCast(@fieldParentPtr("interface", r));
            const dest = limit.slice(try w.writableSliceGreedy(1));
            const n = self.file.read(dest) catch return error.ReadFailed;
            if (n == 0) return error.EndOfStream;
            w.advance(n);
            return n;
        }
    };

    /// `std.Io.Writer` adapter over a `File`.
    pub const Writer = struct {
        file: File,
        interface: std.Io.Writer,

        pub fn init(file: File) Writer {
            return .{
                .file = file,
                .interface = .{
                    .vtable = &.{ .drain = drain },
                    // Unbuffered: every write goes directly to the syscall.
                    .buffer = &.{},
                },
            };
        }

        fn drain(
            w: *std.Io.Writer,
            data: []const []const u8,
            splat: usize,
        ) std.Io.Writer.Error!usize {
            const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
            // Flush anything already buffered (end > 0 only when buffer != &.{}).
            if (w.end > 0) {
                self.file.writeAll(w.buffer[0..w.end]) catch return error.WriteFailed;
                w.end = 0;
            }
            const pattern = data[data.len - 1];
            var n: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                self.file.writeAll(bytes) catch return error.WriteFailed;
                n += bytes.len;
            }
            for (0..splat) |_| {
                self.file.writeAll(pattern) catch return error.WriteFailed;
            }
            return n + splat * pattern.len;
        }
    };
};

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

/// Write bytes to the data disk (virtio-blk device 1) at `byte_offset` from `buf`.
///
/// `byte_offset` and `buf.len` must be multiples of 512 (sector size).
/// Returns error.NoDevice if no data disk is present.
pub fn blkWrite(byte_offset: u64, buf: []const u8) innigkeit.Syscall.Error!void {
    const spec = BlkReadSpec{
        .byte_offset = byte_offset,
        .buf_ptr = @intFromPtr(buf.ptr),
        .buf_len = buf.len,
    };
    const result = innigkeit.Syscall.invoke(.blk_write, .{@intFromPtr(&spec)});
    _ = try innigkeit.Syscall.decode(result);
}

/// Return the size in 512-byte sectors of virtio-blk device `dev_idx`.
pub fn blkDiskSize(dev_idx: u32) innigkeit.Syscall.Error!u64 {
    const result = innigkeit.Syscall.invoke(.blk_disk_size, .{@as(usize, dev_idx)});
    return @intCast(try innigkeit.Syscall.decode(result));
}

/// Open or create a file on the simple flat filesystem.
///
/// `name` must be at most 15 bytes.
/// `flags`: bit 0 = create if not exists, bit 1 = truncate on open.
/// Returns a file descriptor (>= 3) on success.
pub fn fsOpen(name: []const u8, flags: u32) innigkeit.Syscall.Error!u32 {
    const result = innigkeit.Syscall.invoke(.fs_open, .{
        @intFromPtr(name.ptr),
        @as(usize, name.len),
        @as(usize, flags),
    });
    return @intCast(try innigkeit.Syscall.decode(result));
}

/// Read up to `buf.len` bytes from `fd` into `buf`.
///
/// Returns the number of bytes actually read (0 at EOF).
pub fn fsRead(fd: u32, buf: []u8) innigkeit.Syscall.Error!usize {
    const result = innigkeit.Syscall.invoke(.fs_read, .{
        @as(usize, fd),
        @intFromPtr(buf.ptr),
        buf.len,
    });
    return innigkeit.Syscall.decode(result);
}

/// Write `data` to `fd`.
///
/// Returns the number of bytes written.
pub fn fsWrite(fd: u32, data: []const u8) innigkeit.Syscall.Error!usize {
    const result = innigkeit.Syscall.invoke(.fs_write, .{
        @as(usize, fd),
        @intFromPtr(data.ptr),
        data.len,
    });
    return innigkeit.Syscall.decode(result);
}

/// Close `fd`.
pub fn fsClose(fd: u32) innigkeit.Syscall.Error!void {
    const result = innigkeit.Syscall.invoke(.fs_close, .{@as(usize, fd)});
    _ = try innigkeit.Syscall.decode(result);
}
