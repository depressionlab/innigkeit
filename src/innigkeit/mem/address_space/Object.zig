//! A memory object describing a file or device.
//!
//! Called a `uvm_object` in uvm.
//!
//! Based on UVM:
//!   * [Design and Implementation of the UVM Virtual Memory System](https://chuck.cranor.org/p/diss.pdf) by Charles D. Cranor
//!   * [Zero-Copy Data Movement Mechanisms for UVM](https://citeseerx.ist.psu.edu/document?repid=rep1&type=pdf&doi=8961abccddf8ff24f7b494cd64d5cf62604b0018) by Charles D. Cranor and Gurudatta M. Parulkar
//!   * [The UVM Virtual Memory System](https://www.usenix.org/legacy/publications/library/proceedings/usenix99/full_papers/cranor/cranor.pdf) by Charles D. Cranor and Gurudatta M. Parulkar
//!
//! Made with reference to [OpenBSD implementation of UVM](https://github.com/openbsd/src/tree/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm)
//!

const std = @import("std");

const innigkeit = @import("innigkeit");
const PhysicalPage = innigkeit.mem.PhysicalPage;
const core = @import("core");

const PhysicalPageChunkMap = @import("chunk_map.zig").ChunkMap(PhysicalPage);

const Object = @This();

lock: innigkeit.sync.RwLock = .{},

reference_count: u32 = 1,

physical_page_chunks: PhysicalPageChunkMap = .{},

/// Increment the reference count.
///
/// When called a write lock must be held.
pub fn incrementReferenceCount(self: *Object) void {
    if (core.is_debug) {
        std.debug.assert(self.reference_count != 0);
        std.debug.assert(self.lock.isWriteLocked());
    }

    self.reference_count += 1;
}

/// Decrement the reference count.
///
/// When called a write lock must be held, upon return the lock is unlocked.
pub fn decrementReferenceCount(self: *Object) void {
    if (core.is_debug) {
        std.debug.assert(self.reference_count != 0);
        std.debug.assert(self.lock.isWriteLocked());
    }

    const reference_count = self.reference_count;
    self.reference_count = reference_count - 1;
    self.lock.writeUnlock();

    if (reference_count == 1) {
        @branchHint(.cold);
        // Object destruction requires an object cache and pager integration.
        // No pager is wired up yet so no Object is ever created; this branch
        // is dead code for now.
        @panic("Object.decrementReferenceCount: object destruction not yet implemented");
    }
}

pub const Reference = struct {
    object: ?*Object,
    start_offset: core.Size,

    /// Prints the anonymous map reference.
    pub fn print(self: Reference, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        if (self.object) |object| {
            try writer.writeAll("Object.Reference{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("start_offset: {f}\n", .{self.start_offset});

            try writer.splatByteAll(' ', new_indent);
            try object.print(
                writer,
                new_indent,
            );
            try writer.writeAll(",\n");

            try writer.splatByteAll(' ', indent);
            try writer.writeAll("}");
        } else {
            try writer.writeAll("Object.Reference{ none }");
        }
    }

    pub inline fn format(_: Reference, _: *std.Io.Writer) !void {
        @compileError("use `Reference.print` instead");
    }
};

/// Prints the object.
///
/// Locks the spinlock.
pub fn print(self: *Object, writer: *std.Io.Writer, indent: usize) !void {
    const new_indent = indent + 2;

    self.lock.readLock();
    defer self.lock.readUnlock();

    try writer.writeAll("Object{\n");

    try writer.splatByteAll(' ', new_indent);
    try writer.print("reference_count: {d},\n", .{self.reference_count});

    try writer.splatByteAll(' ', indent);
    try writer.writeAll("}");
}

pub inline fn format(_: *const *Object, _: *std.Io.Writer) !void {
    @compileError("use `Object.print` instead");
}
