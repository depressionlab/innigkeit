//! FsProtocol and VfsProtocol definitions.
//!
//! FsProtocol: what filesystem drivers implement (initfsd, ext4d, fatd, xfsd, btrfsd).
//! VfsProtocol: user-facing VFS interface with path-addressed operations.
//!
//! Designed for XFS/btrfs future compatibility:
//!   - readFile with offset+len for large file support
//!   - readDir with cursor (u64) for huge directory support
//!   - create/write/link/unlink/sync for writes
//!   - fallocate for space pre-reservation (XFS loves this)
//!   - copy_file_range for reflinks (btrfs/XFS copy-on-write clones)
//!   - Stat with nanosecond timestamps, u64 inode, link count
//!
//! Message encoding:
//!   Request:  tag = @intFromEnum(Op), words[0..] = args, caps[0..] = cap args
//!   Success:  tag = 0, words[0..] = return values, caps[0..] = returned caps
//!   Error:    tag = error_code (non-zero FsError/VfsError enum value), others zero

const innigkeit = @import("innigkeit");
const std = @import("std");

/// File metadata, equivalent to POSIX stat with nanosecond timestamps.
pub const Stat = extern struct {
    inode: u64,
    size: u64,
    link_count: u32,
    mode: FileMode,
    uid: u32,
    gid: u32,
    block_size: u32, // preferred I/O block size
    blocks: u64, // 512-byte blocks allocated
    atime_ns: i64, // access time (nanoseconds since epoch)
    mtime_ns: i64, // modification time
    ctime_ns: i64, // status change time
    _pad: u64 = 0,
};

/// Unix-style file permissions and type packed into 32 bits.
pub const FileMode = packed struct(u32) {
    other_x: bool = false,
    other_w: bool = false,
    other_r: bool = false,
    group_x: bool = false,
    group_w: bool = false,
    group_r: bool = false,
    owner_x: bool = false,
    owner_w: bool = false,
    owner_r: bool = false,
    set_gid: bool = false,
    set_uid: bool = false,
    sticky: bool = false,
    type: FileType = .regular,
    _: u18 = 0,
};

/// File system object types.
pub const FileType = enum(u2) {
    regular = 0,
    directory = 1,
    symlink = 2,
    other = 3, // device, pipe, socket
};

/// Fixed-size directory entry header. The name follows inline (name_len bytes,
/// no null terminator). Entries are aligned to 8 bytes:
///   total size = 16 + name_len, rounded up to the next multiple of 8.
pub const DirEntry = extern struct {
    inode: u64,
    type: FileType,
    _pad: [3]u8 = .{0} ** 3,
    name_len: u8, // max 255
    // name follows inline (name_len bytes, no null terminator)
};

/// Flags controlling how a file is opened.
pub const OpenFlags = packed struct(u32) {
    read: bool = true,
    write: bool = false,
    create: bool = false, // create if missing
    create_excl: bool = false, // fail if exists (with create)
    truncate: bool = false,
    append: bool = false,
    _: u26 = 0,
};

/// Operation tags for the filesystem driver protocol.
pub const FsOp = enum(u64) {
    root = 0, // -> inode: u64
    stat = 1, // inode: u64 -> Stat
    read_file = 2, // inode: u64, offset: u64, len: u32 -> caps[0]=Frame, words[0]=bytes_read: u32
    read_dir = 3, // inode: u64, cursor: u64 -> caps[0]=Frame([]DirEntry), words[0]=next_cursor: u64
    create = 4, // parent: u64, type: FileType, caps[0]=name Frame -> words[0]=inode: u64
    write = 5, // inode: u64, offset: u64, caps[0]=data Frame -> words[0]=bytes_written: u32
    link = 6, // parent: u64, inode: u64, caps[0]=name Frame -> void
    unlink = 7, // parent: u64, caps[0]=name Frame -> void
    read_link = 8, // inode: u64 -> caps[0]=Frame (symlink target)
    truncate = 9, // inode: u64, size: u64 -> void
    sync = 10, // inode: u64 -> void (fsync)
    sync_all = 11, // -> void (sync entire filesystem)
    // Extended ops for XFS/btrfs (return FsError.not_supported if unsupported):
    fallocate = 12, // inode: u64, offset: u64, len: u64, keep_size: bool -> void
    copy_file_range = 13, // src_inode: u64, src_off: u64, dst_inode: u64, dst_off: u64, len: u64 -> words[0]=bytes_copied: u64
    _,
};

/// Error codes for filesystem operations (returned in response tag).
pub const FsError = enum(u64) {
    none = 0,
    not_found = 2,
    not_dir = 3,
    is_dir = 4,
    permission = 5,
    no_space = 6,
    io_error = 7,
    read_only = 8,
    not_supported = 9,
    exists = 10,
    not_empty = 11,
    name_too_long = 12,
};

/// Client for the filesystem driver protocol.
pub const FsClient = struct {
    handle: innigkeit.capabilities.Handle,

    /// Get the root directory inode number.
    pub fn root(self: FsClient) !u64 {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.root),
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
        return msg.words[0];
    }

    /// Get file metadata by inode number.
    pub fn stat(self: FsClient, inode: u64) !Stat {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.stat),
            .words = .{ inode, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
        var s: Stat = undefined;
        // Stat is 80 bytes; too big for 4 words (32 bytes). Use two messages or
        // accept that only part of Stat fits. For now, copy what fits (32 bytes).
        // In production, the server would put Stat in a Frame.
        @memcpy(
            @as([*]u8, @ptrCast(&s))[0..@min(@sizeOf(Stat), 32)],
            @as([*]const u8, @ptrCast(&msg.words))[0..@min(@sizeOf(Stat), 32)],
        );
        return s;
    }

    /// Read file data at `offset` for up to `len` bytes.
    /// Returns a Frame handle and actual bytes read.
    pub fn readFile(self: FsClient, inode: u64, offset: u64, len: u32) !struct { frame: innigkeit.capabilities.Handle, bytes: u32 } {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.read_file),
            .words = .{ inode, offset, @as(u64, len), 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
        return .{
            .frame = msg.caps[0],
            .bytes = @truncate(msg.words[0]),
        };
    }

    /// Read directory entries starting at `cursor`.
    /// Returns a Frame with packed DirEntry records and the next cursor.
    /// next_cursor == 0 means end of directory.
    pub fn readDir(self: FsClient, inode: u64, cursor: u64) !struct { frame: innigkeit.capabilities.Handle, next_cursor: u64 } {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.read_dir),
            .words = .{ inode, cursor, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
        return .{
            .frame = msg.caps[0],
            .next_cursor = msg.words[0],
        };
    }

    /// Create a new file system object in `parent` directory.
    /// The name is passed as a Frame capability (caps[0]).
    pub fn create(self: FsClient, parent: u64, file_type: FileType, name_frame: innigkeit.capabilities.Handle) !u64 {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.create),
            .words = .{ parent, @intFromEnum(file_type), 0, 0 },
            .caps = .{ name_frame, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
        return msg.words[0];
    }

    /// Write data to a file. Data is passed as a Frame capability.
    /// Returns the number of bytes written.
    pub fn write(self: FsClient, inode: u64, offset: u64, data_frame: innigkeit.capabilities.Handle) !u32 {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.write),
            .words = .{ inode, offset, 0, 0 },
            .caps = .{ data_frame, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
        return @truncate(msg.words[0]);
    }

    /// Create a hard link `inode` in `parent` with the given name.
    pub fn link(self: FsClient, parent: u64, inode: u64, name_frame: innigkeit.capabilities.Handle) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.link),
            .words = .{ parent, inode, 0, 0 },
            .caps = .{ name_frame, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
    }

    /// Remove a directory entry `name` from `parent`.
    pub fn unlink(self: FsClient, parent: u64, name_frame: innigkeit.capabilities.Handle) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.unlink),
            .words = .{ parent, 0, 0, 0 },
            .caps = .{ name_frame, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
    }

    /// Read a symlink target. Returns a Frame capability with the target path.
    pub fn readLink(self: FsClient, inode: u64) !innigkeit.capabilities.Handle {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.read_link),
            .words = .{ inode, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
        return msg.caps[0];
    }

    /// Truncate a file to `size` bytes.
    pub fn truncate(self: FsClient, inode: u64, size: u64) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.truncate),
            .words = .{ inode, size, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
    }

    /// Flush outstanding writes for `inode` to stable storage.
    pub fn sync(self: FsClient, inode: u64) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.sync),
            .words = .{ inode, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
    }

    /// Flush the entire filesystem to stable storage.
    pub fn syncAll(self: FsClient) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.sync_all),
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
    }

    /// Pre-allocate space for `inode` at `offset` for `len` bytes.
    /// If `keep_size` is true, the file size is not changed.
    /// Returns error.FsError with code not_supported on old filesystems.
    pub fn fallocate(self: FsClient, inode: u64, offset: u64, len: u64, keep_size: bool) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.fallocate),
            .words = .{ inode, offset, len, @intFromBool(keep_size) },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
    }

    /// Copy a range of data from one file to another without userspace roundtrip.
    /// Returns the number of bytes copied.
    /// Returns error.FsError with code not_supported if not available.
    pub fn copyFileRange(
        self: FsClient,
        src_inode: u64,
        src_off: u64,
        dst_inode: u64,
        dst_off: u64,
        len: u64,
    ) !u64 {
        // 5 u64 args don't fit in 4 message words; `len` is passed in caps[0]
        // as a raw integer (misuse of the caps field) until the server side
        // switches to a Frame-based encoding for full XFS/btrfs support.
        // words: src_inode, src_off, dst_inode, dst_off
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FsOp.copy_file_range),
            .words = .{ src_inode, src_off, dst_inode, dst_off },
            .caps = .{ @truncate(len), 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(FsError.none)) return error.FsError;
        return msg.words[0];
    }
};

/// Operation tags for the user-facing VFS protocol.
///
/// Supported URI schemes:
/// - `/path`         -> `fs:///path` (primary mount)
/// - `initfs://path` -> initfs driver
/// - `block://N`     -> raw block device N
/// - `block://N/P`   -> partition P of block device N
pub const VfsOp = enum(u64) {
    open = 0, // caps[0]=uri Frame, len: u32, flags: OpenFlags -> caps[0]=FileHandle Endpoint
    stat = 1, // caps[0]=uri Frame, len: u32 -> Stat inline in words (first 32 bytes)
    read_dir = 2, // caps[0]=uri Frame, len: u32, cursor: u64 -> caps[0]=entries Frame, words[0]=next_cursor: u64
    mkdir = 3, // caps[0]=uri Frame, len: u32 -> void
    unlink = 4, // caps[0]=uri Frame, len: u32 -> void
    rename = 5, // caps[0]=old Frame, words[0]=old_len: u32, caps[1]=new Frame, words[1]=new_len: u32 -> void
    _,
};

/// FileHandle operations (Endpoint returned by VfsOp.open).
pub const FileOp = enum(u64) {
    read = 0, // offset: u64, len: u32 -> caps[0]=data Frame, words[0]=bytes_read: u32
    write = 1, // offset: u64, caps[0]=data Frame -> words[0]=bytes_written: u32
    stat = 2, // -> Stat inline in words (first 32 bytes)
    sync = 3, // -> void
    close = 4, // -> void (server closes endpoint after reply)
    _,
};

/// Error codes for VFS operations (returned in response tag).
pub const VfsError = enum(u64) {
    none = 0,
    not_found = 2,
    permission = 5,
    io_error = 7,
    not_supported = 9,
    bad_uri = 20,
    _,
};

/// Client for the user-facing VFS protocol.
pub const VfsClient = struct {
    handle: innigkeit.capabilities.Handle,

    /// Open a file by URI. Returns a FileHandle endpoint capability.
    pub fn open(self: VfsClient, uri_frame: innigkeit.capabilities.Handle, len: u32, flags: OpenFlags) !innigkeit.capabilities.Handle {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(VfsOp.open),
            .words = .{ @as(u64, len), @as(u64, @bitCast(flags)), 0, 0 },
            .caps = .{ uri_frame, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(VfsError.none)) return error.VfsError;
        return msg.caps[0];
    }

    /// Stat a path. Returns partial Stat (first 32 bytes fit in 4 words).
    pub fn stat(self: VfsClient, uri_frame: innigkeit.capabilities.Handle, len: u32) !Stat {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(VfsOp.stat),
            .words = .{ @as(u64, len), 0, 0, 0 },
            .caps = .{ uri_frame, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(VfsError.none)) return error.VfsError;
        var s: Stat = std.mem.zeroes(Stat);
        @memcpy(
            @as([*]u8, @ptrCast(&s))[0..@min(@sizeOf(Stat), 32)],
            @as([*]const u8, @ptrCast(&msg.words))[0..@min(@sizeOf(Stat), 32)],
        );
        return s;
    }

    /// Read directory entries at `uri`, starting at `cursor`.
    pub fn readDir(self: VfsClient, uri_frame: innigkeit.capabilities.Handle, len: u32, cursor: u64) !struct { frame: innigkeit.capabilities.Handle, next_cursor: u64 } {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(VfsOp.read_dir),
            .words = .{ @as(u64, len), cursor, 0, 0 },
            .caps = .{ uri_frame, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(VfsError.none)) return error.VfsError;
        return .{
            .frame = msg.caps[0],
            .next_cursor = msg.words[0],
        };
    }

    /// Create a directory at `uri`.
    pub fn mkdir(self: VfsClient, uri_frame: innigkeit.capabilities.Handle, len: u32) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(VfsOp.mkdir),
            .words = .{ @as(u64, len), 0, 0, 0 },
            .caps = .{ uri_frame, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(VfsError.none)) return error.VfsError;
    }

    /// Remove a file or directory at `uri`.
    pub fn unlink(self: VfsClient, uri_frame: innigkeit.capabilities.Handle, len: u32) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(VfsOp.unlink),
            .words = .{ @as(u64, len), 0, 0, 0 },
            .caps = .{ uri_frame, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(VfsError.none)) return error.VfsError;
    }

    /// Rename/move a file system object.
    pub fn rename(
        self: VfsClient,
        old_frame: innigkeit.capabilities.Handle,
        old_len: u32,
        new_frame: innigkeit.capabilities.Handle,
        new_len: u32,
    ) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(VfsOp.rename),
            .words = .{ @as(u64, old_len), @as(u64, new_len), 0, 0 },
            .caps = .{ old_frame, new_frame, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(VfsError.none)) return error.VfsError;
    }
};

/// Client for an open file handle (Endpoint returned by VfsOp.open).
pub const FileHandle = struct {
    handle: innigkeit.capabilities.Handle,

    /// Read data from the file at `offset` for up to `len` bytes.
    /// Returns a Frame capability and actual bytes read.
    pub fn read(self: FileHandle, offset: u64, len: u32) !struct { frame: innigkeit.capabilities.Handle, bytes: u32 } {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FileOp.read),
            .words = .{ offset, @as(u64, len), 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(VfsError.none)) return error.VfsError;
        return .{
            .frame = msg.caps[0],
            .bytes = @truncate(msg.words[0]),
        };
    }

    /// Write data from `data_frame` to the file at `offset`.
    /// Returns the number of bytes written.
    pub fn write(self: FileHandle, offset: u64, data_frame: innigkeit.capabilities.Handle) !u32 {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FileOp.write),
            .words = .{ offset, 0, 0, 0 },
            .caps = .{ data_frame, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(VfsError.none)) return error.VfsError;
        return @truncate(msg.words[0]);
    }

    /// Get file metadata.
    pub fn stat(self: FileHandle) !Stat {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FileOp.stat),
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(VfsError.none)) return error.VfsError;
        var s: Stat = std.mem.zeroes(Stat);
        @memcpy(
            @as([*]u8, @ptrCast(&s))[0..@min(@sizeOf(Stat), 32)],
            @as([*]const u8, @ptrCast(&msg.words))[0..@min(@sizeOf(Stat), 32)],
        );
        return s;
    }

    /// Flush outstanding writes to stable storage.
    pub fn sync(self: FileHandle) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FileOp.sync),
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(VfsError.none)) return error.VfsError;
    }

    /// Close the file handle. The server closes the endpoint after replying.
    pub fn close(self: FileHandle) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(FileOp.close),
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(VfsError.none)) return error.VfsError;
    }
};
