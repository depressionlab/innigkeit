//! Per-process file-descriptor table.
//!
//! Maps small integers (0..max_descriptors) to tagged descriptors:
//!   - `.keyboard_in` (fd 0 by default): the kernel keyboard line buffer
//!   - `.terminal_out` (fd 1 and 2 by default): the boot terminal
//!   - `.file`: an open VFS node plus a per-descriptor byte offset
//!   - `.closed`: free slot
//!
//! ## Locking model
//!
//! A single short `TicketSpinLock` guards the slot array. Disk I/O is
//! interrupt-driven and may block, so the lock is NEVER held across a VFS
//! call. Instead, each operation follows a resolve/operate/commit
//! pattern:
//!
//!   1. resolve: take the lock, copy the descriptor (plus the slot's
//!      generation counter) out of the table, release the lock.
//!   2. operate: perform the (potentially blocking) VFS read/write on the
//!      private copy.
//!   3. commit: re-take the lock and write the advanced offset / updated
//!      size back, but only if the slot's generation still matches. The
//!      generation is bumped on every `closeFd`, so an in-flight operation
//!      racing with close + re-open of the same slot silently drops its
//!      offset update instead of corrupting the unrelated new descriptor.
//!
//! Concurrent operations on the *same* descriptor are last-writer-wins on
//! the offset (the same semantics POSIX gives unsynchronised sharing).
//! Pure metadata operations (`lseek`, `statFd`) touch no disk and run
//! entirely under the spinlock.
const FdTable = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");

const vfs = innigkeit.fs.vfs;

pub const max_descriptors = 32;

pub const Error = error{
    BadFd,
    NotWritable,
    InvalidArgument,
    NoDevice,
    Io,
};

/// File kind reported by `statFd` (ABI value of `Stat.kind`).
pub const Kind = enum(u8) {
    file = 0,
    directory = 1,
    tty = 2,
};

/// ABI struct returned by the fstat syscall (must match userspace).
pub const Stat = extern struct {
    size: u64,
    kind: u8,
    _pad: [7]u8 = @splat(0),
};

/// An open VFS file plus the per-descriptor cursor.
pub const FileDescriptor = struct {
    /// VFS node handle (its internal position is scratch state; the
    /// authoritative cursor is `offset`).
    node: vfs.OpenFile,
    /// Byte offset for the next read/write.
    offset: u64,
    /// Whether writes are permitted on this descriptor.
    writable: bool,
};

pub const Descriptor = union(enum) {
    closed,
    terminal_out,
    keyboard_in,
    file: FileDescriptor,
};

const Slot = struct {
    desc: Descriptor = .closed,
    /// Bumped on close; lets `commitFile` detect close/re-open races.
    gen: u32 = 0,
};

pub const Resolved = struct {
    desc: Descriptor,
    gen: u32,
};

lock: innigkeit.sync.TicketSpinLock = .{},
slots: [max_descriptors]Slot = @splat(.{}),

/// Re-initialise to the default layout: fd0 = keyboard, fd1/fd2 = terminal.
///
/// Called from `Process.create()`: slab slots are reused without re-running
/// the constructor, so all mutable state must be reset here explicitly.
/// Only call when no other thread can touch the table.
pub fn reset(self: *FdTable) void {
    self.lock = .{};
    for (&self.slots) |*slot| slot.* = .{};
    self.slots[0].desc = .keyboard_in;
    self.slots[1].desc = .terminal_out;
    self.slots[2].desc = .terminal_out;
}

/// Copy the descriptor at `fd` out of the table (step 1 of the locking
/// model). Returns null for out-of-range or closed descriptors.
pub fn resolve(self: *FdTable, fd: usize) ?Resolved {
    if (fd >= max_descriptors) return null;
    self.lock.lock();
    defer self.lock.unlock();
    const slot = &self.slots[fd];
    if (slot.desc == .closed) return null;
    return .{ .desc = slot.desc, .gen = slot.gen };
}

/// Insert an open VFS node into the lowest free slot. The node's cursor
/// starts at offset 0 regardless of the VFS handle's internal position.
pub fn insertFile(self: *FdTable, node: vfs.OpenFile, writable: bool) error{TooManyFiles}!u32 {
    self.lock.lock();
    defer self.lock.unlock();
    for (&self.slots, 0..) |*slot, i| {
        if (slot.desc != .closed) continue;
        slot.desc = .{ .file = .{ .node = node, .offset = 0, .writable = writable } };
        return @intCast(i);
    }
    return error.TooManyFiles;
}

/// Close `fd`. Returns the file payload (if it was a `.file`) so the caller
/// can run `vfs.close` on it *outside* the table lock; close may do disk I/O.
pub fn closeFd(self: *FdTable, fd: usize) error{BadFd}!?FileDescriptor {
    if (fd >= max_descriptors) return error.BadFd;
    self.lock.lock();
    defer self.lock.unlock();
    const slot = &self.slots[fd];
    switch (slot.desc) {
        .closed => return error.BadFd,
        .file => |file| {
            slot.desc = .closed;
            slot.gen +%= 1;
            return file;
        },
        else => {
            slot.desc = .closed;
            slot.gen +%= 1;
            return null;
        },
    }
}

/// Close every open descriptor, flushing writable files. Called during
/// process cleanup (kernel task context; blocking disk I/O is fine).
pub fn closeAll(self: *FdTable) void {
    for (0..max_descriptors) |fd| {
        const maybe_file = self.closeFd(fd) catch continue;
        if (maybe_file) |file| {
            var node = file.node;
            vfs.close(&node);
        }
    }
}

/// Write an updated descriptor back (step 3 of the locking model). Dropped
/// silently if the slot was closed or reused (generation mismatch).
pub fn commitFile(self: *FdTable, fd: usize, gen: u32, file: FileDescriptor) void {
    self.lock.lock();
    defer self.lock.unlock();
    const slot = &self.slots[fd];
    if (slot.gen != gen) return;
    switch (slot.desc) {
        .file => |*f| f.* = file,
        else => {},
    }
}

/// Read up to `buf.len` bytes from the file at `fd` into a *kernel* buffer,
/// starting at the descriptor's offset, then advance the offset.
/// Returns 0 at EOF. `buf` must not be user memory (the VFS read blocks).
pub fn readFile(self: *FdTable, fd: usize, buf: []u8) Error!usize {
    const resolved = self.resolve(fd) orelse return error.BadFd;
    var file = switch (resolved.desc) {
        .file => |f| f,
        else => return error.BadFd,
    };

    vfs.setPos(&file.node, file.offset) catch return error.InvalidArgument;
    const n = vfs.read(&file.node, buf) catch |err| return switch (err) {
        error.NoDevice => error.NoDevice,
        else => error.Io,
    };
    file.offset = vfs.getPos(&file.node);

    self.commitFile(fd, resolved.gen, file);
    return n;
}

/// Write `buf` (a *kernel* buffer) to the file at `fd` at the descriptor's
/// offset, then advance the offset. Returns the number of bytes written.
pub fn writeFile(self: *FdTable, fd: usize, buf: []const u8) Error!usize {
    const resolved = self.resolve(fd) orelse return error.BadFd;
    var file = switch (resolved.desc) {
        .file => |f| f,
        else => return error.BadFd,
    };
    if (!file.writable) return error.NotWritable;

    vfs.setPos(&file.node, file.offset) catch return error.InvalidArgument;
    const n = vfs.write(&file.node, buf) catch |err| return switch (err) {
        error.PermissionDenied => error.NotWritable,
        error.NoDevice => error.NoDevice,
        else => error.Io,
    };
    file.offset = vfs.getPos(&file.node);

    self.commitFile(fd, resolved.gen, file);
    return n;
}

/// Reposition the offset of the file at `fd`.
/// whence: 0 = SET, 1 = CUR, 2 = END. Returns the new offset.
/// Metadata only (no disk I/O) so it runs entirely under the lock.
pub fn lseek(self: *FdTable, fd: usize, offset: i64, whence: u32) Error!u64 {
    if (fd >= max_descriptors) return error.BadFd;
    self.lock.lock();
    defer self.lock.unlock();
    switch (self.slots[fd].desc) {
        .closed => return error.BadFd,
        .file => |*f| {
            const base: i64 = switch (whence) {
                0 => 0,
                1 => std.math.cast(i64, f.offset) orelse return error.InvalidArgument,
                2 => std.math.cast(i64, vfs.fileSize(&f.node)) orelse return error.InvalidArgument,
                else => return error.InvalidArgument,
            };
            const new_offset = std.math.add(i64, base, offset) catch return error.InvalidArgument;
            if (new_offset < 0) return error.InvalidArgument;
            f.offset = @intCast(new_offset);
            return f.offset;
        },
        // Terminals and the keyboard are not seekable.
        else => return error.InvalidArgument,
    }
}

/// Fill a `Stat` for `fd`. Metadata only; runs entirely under the lock.
pub fn statFd(self: *FdTable, fd: usize) Error!Stat {
    if (fd >= max_descriptors) return error.BadFd;
    self.lock.lock();
    defer self.lock.unlock();
    return switch (self.slots[fd].desc) {
        .closed => error.BadFd,
        .terminal_out, .keyboard_in => .{ .size = 0, .kind = @intFromEnum(Kind.tty) },
        .file => |*f| .{ .size = vfs.fileSize(&f.node), .kind = @intFromEnum(Kind.file) },
    };
}

/// Build a read-only simple_fs-backed VFS node spanning `size` bytes
/// starting at `start_sector` of the data device. Test helper: never
/// touches the on-disk directory, so it cannot corrupt the disk.
fn testNode(start_sector: u32, size: u32) vfs.OpenFile {
    return .{
        .is_ext4 = false,
        .simple = .{
            .start_sector = start_sector,
            .size = size,
            .pos = 0,
            .dir_idx = 0,
            .writable = false,
        },
        .ext4_ino = 0,
        .ext4_pos = 0,
        .ext4_size = 0,
        .ext4_writable = false,
    };
}

test "fd table: default descriptors and lowest-free slot reuse" {
    var table: FdTable = .{};
    table.reset();

    try std.testing.expect(table.resolve(0).?.desc == .keyboard_in);
    try std.testing.expect(table.resolve(1).?.desc == .terminal_out);
    try std.testing.expect(table.resolve(2).?.desc == .terminal_out);
    try std.testing.expect(table.resolve(3) == null);

    // New files land in the lowest free slot, starting at fd 3.
    try std.testing.expectEqual(@as(u32, 3), try table.insertFile(testNode(0, 1024), false));
    try std.testing.expectEqual(@as(u32, 4), try table.insertFile(testNode(0, 1024), true));

    // Closing frees the slot; the next open reuses it.
    try std.testing.expect((try table.closeFd(3)) != null);
    try std.testing.expectEqual(@as(u32, 3), try table.insertFile(testNode(0, 1024), false));
}

test "fd table: closed fd fails and a stale commit is dropped" {
    var table: FdTable = .{};
    table.reset();

    const fd = try table.insertFile(testNode(0, 1024), false);
    const resolved = table.resolve(fd).?;

    _ = try table.closeFd(fd);
    try std.testing.expect(table.resolve(fd) == null);
    try std.testing.expectError(error.BadFd, table.lseek(fd, 0, 0));
    try std.testing.expectError(error.BadFd, table.statFd(fd));
    try std.testing.expectError(error.BadFd, table.closeFd(fd)); // double close
    try std.testing.expectError(error.BadFd, table.closeFd(max_descriptors)); // out of range

    // Reuse the slot, then attempt a commit with the pre-close generation:
    // it must be dropped instead of clobbering the new descriptor.
    const fd2 = try table.insertFile(testNode(0, 2048), false);
    try std.testing.expectEqual(fd, fd2);
    var stale = resolved.desc.file;
    stale.offset = 999;
    table.commitFile(fd2, resolved.gen, stale);
    try std.testing.expectEqual(@as(u64, 0), table.resolve(fd2).?.desc.file.offset);

    // Terminals are not seekable.
    try std.testing.expectError(error.InvalidArgument, table.lseek(1, 0, 0));
}

test "fd table: lseek and positioned reads against the boot disk via vfs" {
    const blk = innigkeit.drivers.virtio.blk;
    if (!blk.isDataReady()) return error.SkipZigTest;

    // Reference bytes straight from the driver.
    var ref: [1024]u8 = undefined;
    try blk.readBytes(blk.dataDeviceIndex(), 0, &ref);

    // Synthetic read-only node over the first two sectors: exercises the
    // resolve -> blocking VFS read -> commit path on real disk contents.
    var table: FdTable = .{};
    table.reset();
    const fd = try table.insertFile(testNode(0, 1024), false);

    // SEEK_SET, then a positioned read advances the offset.
    try std.testing.expectEqual(@as(u64, 500), try table.lseek(fd, 500, 0));
    var buf: [100]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 100), try table.readFile(fd, &buf));
    try std.testing.expectEqualSlices(u8, ref[500..600], &buf);
    try std.testing.expectEqual(@as(u64, 700), try table.lseek(fd, 100, 1)); // SEEK_CUR from 600

    // SEEK_END lands on the size; reading at EOF returns 0.
    try std.testing.expectEqual(@as(u64, 1024), try table.lseek(fd, 0, 2));
    try std.testing.expectEqual(@as(usize, 0), try table.readFile(fd, &buf));

    // Negative results and bad whence are rejected.
    try std.testing.expectError(error.InvalidArgument, table.lseek(fd, -2048, 1));
    try std.testing.expectError(error.InvalidArgument, table.lseek(fd, 0, 3));

    // stat reports the synthetic size and the file kind.
    const st = try table.statFd(fd);
    try std.testing.expectEqual(@as(u64, 1024), st.size);
    try std.testing.expectEqual(@intFromEnum(Kind.file), st.kind);

    // Writes through a read-only descriptor are rejected.
    try std.testing.expectError(error.NotWritable, table.writeFile(fd, "x"));
}
