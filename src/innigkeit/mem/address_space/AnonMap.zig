//! An area of anonymous memory.
//!
//! Called a `vm_amap` in uvm.
//!
//! Based on UVM:
//!   * [Design and Implementation of the UVM Virtual Memory System](https://chuck.cranor.org/p/diss.pdf) by Charles D. Cranor
//!   * [Zero-Copy Data Movement Mechanisms for UVM](https://citeseerx.ist.psu.edu/document?repid=rep1&type=pdf&doi=8961abccddf8ff24f7b494cd64d5cf62604b0018) by Charles D. Cranor and Gurudatta M. Parulkar
//!   * [The UVM Virtual Memory System](https://www.usenix.org/legacy/publications/library/proceedings/usenix99/full_papers/cranor/cranor.pdf) by Charles D. Cranor and Gurudatta M. Parulkar
//!
//! Made with reference to [OpenBSD implementation of UVM](https://github.com/openbsd/src/tree/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm)
//!

const std = @import("std");

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

const AddressSpace = @import("AddressSpace.zig");
const AnonPage = @import("AnonPage.zig");
const Entry = @import("Entry.zig");

const AnonPageChunkMap = @import("chunk_map.zig").ChunkMap(AnonPage);
const log = innigkeit.debug.log.scoped(.address_space);

const AnonMap = @This();

lock: innigkeit.sync.RwLock = .{},

reference_count: u32 = 1,

number_of_pages: PageCount,

pages_in_use: PageCount = .zero,

anonymous_page_chunks: AnonPageChunkMap = .{},

// /// If `true` this anonymous map is shared between multiple entries.
// shared: bool, // TODO: properly support shared anonymous maps

pub fn create(size: core.Size) error{OutOfMemory}!*AnonMap {
    if (core.is_debug) std.debug.assert(size.aligned(architecture.paging.standard_page_size_alignment));

    const anonymous_map = globals.anonymous_map_cache.allocate() catch return error.OutOfMemory;

    anonymous_map.* = .{ .number_of_pages = .fromSize(size) };

    return anonymous_map;
}

/// Increment the reference count.
///
/// When called a write lock must be held.
pub fn incrementReferenceCount(self: *AnonMap) void {
    if (core.is_debug) {
        std.debug.assert(self.reference_count != 0);
        std.debug.assert(self.lock.isWriteLocked());
    }

    self.reference_count += 1;
}

/// Decrement the reference count.
///
/// When called a write lock must be held, upon return the lock is unlocked.
pub fn decrementReferenceCount(self: *AnonMap, deallocate_page_list: *innigkeit.mem.PhysicalPage.List) void {
    if (core.is_debug) {
        std.debug.assert(self.reference_count != 0);
        std.debug.assert(self.lock.isWriteLocked());
    }

    const reference_count = self.reference_count;
    self.reference_count = reference_count - 1;

    if (reference_count == 1) {
        // reference count is now zero, destroy the anonymous map
        self.destroy(deallocate_page_list);
        return;
    }

    // TODO: once `shared` is supported:
    // https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_amap.c#L1342-L1347

    self.lock.writeUnlock();
}

/// Destroy the anonymous map.
///
/// Only called by `decrementReferenceCount` when the reference count is zero.
///
/// Called `amap_wipeout` in OpenBSD uvm.
fn destroy(self: *AnonMap, deallocate_page_list: *innigkeit.mem.PhysicalPage.List) void {
    if (core.is_debug) {
        std.debug.assert(self.lock.isWriteLocked());
        std.debug.assert(self.reference_count == 0);
    }

    var iter = self.anonymous_page_chunks.chunks.valueIterator();

    while (iter.next()) |chunk| {
        for (chunk) |opt_page| {
            const page = opt_page orelse continue;
            page.lock.writeLock();
            page.decrementReferenceCount(deallocate_page_list);
        }
    }
    self.anonymous_page_chunks.deinit();
    self.anonymous_page_chunks.chunks = .{};

    self.lock.writeUnlock();
    globals.anonymous_map_cache.deallocate(self);
}

/// Ensure an entries `needs_copy` flag is false, by copying the anonymous map if needed.
///
/// The `entries_lock` must be locked for writing.
///
/// - An entry with no anonymous map will get a new anonymous map.
/// - If the entry has an anonymous map it must be unlocked.
///
/// Called `amap_copy` in OpenBSD uvm.
pub fn copy(self: *AddressSpace, entry: *Entry, faulting_address: innigkeit.VirtualAddress) error{OutOfMemory}!void {
    _ = faulting_address;

    if (core.is_debug) std.debug.assert(self.entries_lock.isWriteLocked());

    if (entry.anonymous_map_reference.anonymous_map == null) {
        // no anonymous map, create one

        // FIXME: rather than `try` - wait for memory to be available and trigger memory reclaimation
        entry.anonymous_map_reference.anonymous_map = try create(entry.range.size);
        entry.anonymous_map_reference.start_offset = .zero;

        entry.needs_copy = false;

        return;
    }

    @panic("NOT IMPLEMENTED - AnonMap.copy"); // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_amap.c#L576
}

pub const Reference = struct {
    anonymous_map: ?*AnonMap,
    start_offset: core.Size,

    /// Lookup up a page in the referenced anonymous map for the given entry and faulting address.
    ///
    /// The anonymous map is asserted to be non-null.
    /// The faulting address is asserted to be within the entry's range and aligned to the page size.
    ///
    /// The anonymous map must be locked by the caller. (read or write)
    ///
    /// Called `amap_lookups` in OpenBSD uvm, but this implementation only returns a single page.
    pub fn lookup(self: Reference, entry: *const Entry, faulting_address: innigkeit.VirtualAddress) ?*AnonPage {
        if (core.is_debug) {
            std.debug.assert(self.anonymous_map != null);
            std.debug.assert(self.start_offset.aligned(architecture.paging.standard_page_size_alignment));
            std.debug.assert(entry.anonymous_map_reference.anonymous_map == self.anonymous_map);
            std.debug.assert(entry.anonymous_map_reference.start_offset.equal(self.start_offset));
            std.debug.assert(faulting_address.pageAligned());
            std.debug.assert(entry.range.containsAddress(faulting_address));
        }

        const anonymous_map = self.anonymous_map.?;

        const target_index = targetIndex(entry, self, faulting_address);
        if (core.is_debug) std.debug.assert(target_index < anonymous_map.number_of_pages.count);

        return anonymous_map.anonymous_page_chunks.get(target_index);
    }

    pub const AddOperation = enum {
        add,
        replace,
    };

    /// Add or replace an anonymous page in the referenced anonymous map.
    ///
    /// The anonymous map must be locked by the caller.
    ///
    /// Called `amap_add` in OpenBSD uvm.
    pub fn add(
        self: Reference,
        entry: *const Entry,
        faulting_address: innigkeit.VirtualAddress,
        anonymous_page: *AnonPage,
        operation: AddOperation,
    ) error{OutOfMemory}!void {
        if (core.is_debug) {
            std.debug.assert(self.anonymous_map != null);
            std.debug.assert(entry.anonymous_map_reference.anonymous_map == self.anonymous_map);
            std.debug.assert(entry.anonymous_map_reference.start_offset.equal(self.start_offset));
            std.debug.assert(faulting_address.pageAligned());
            std.debug.assert(entry.range.containsAddress(faulting_address));
        }

        log.verbose("adding anonymous page for {f} to anonymous map", .{faulting_address});

        const anonymous_map = self.anonymous_map.?;

        const target_index = targetIndex(entry, self, faulting_address);
        if (core.is_debug) std.debug.assert(target_index < anonymous_map.number_of_pages.count);

        const chunk = anonymous_map.anonymous_page_chunks.ensureChunk(target_index) catch
            return error.OutOfMemory;

        const chunk_offset = AnonPageChunkMap.chunkOffset(target_index);

        switch (operation) {
            .add => {
                if (core.is_debug) std.debug.assert(chunk[chunk_offset] == null);
                anonymous_map.pages_in_use.increment();
            },
            .replace => @panic("NOT IMPLEMENTED"), // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_amap.c#L1223
        }
        chunk[chunk_offset] = anonymous_page;
    }

    /// Returns the page offset of the given address in the given entry.
    ///
    /// Asserts that the address is within the entry's range.
    fn targetIndex(entry: *const Entry, reference: Reference, faulting_address: innigkeit.VirtualAddress) u32 {
        if (core.is_debug) std.debug.assert(entry.range.containsAddress(faulting_address));

        return @intCast(
            entry.range.address.difference(faulting_address).divide(architecture.paging.standard_page_size) +
                reference.start_offset.divide(architecture.paging.standard_page_size),
        );
    }

    /// Prints the anonymous map reference.
    pub fn print(self: Reference, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        if (self.anonymous_map) |anonymous_map| {
            try writer.writeAll("AnonMap.Reference{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("start_offset: {f}\n", .{self.start_offset});

            try writer.splatByteAll(' ', new_indent);
            try anonymous_map.print(
                writer,
                new_indent,
            );
            try writer.writeAll(",\n");

            try writer.splatByteAll(' ', indent);
            try writer.writeAll("}");
        } else {
            try writer.writeAll("AnonMap.Reference{ none }");
        }
    }

    pub inline fn format(_: Reference, _: *std.Io.Writer) !void {
        @compileError("use `Reference.print` instead");
    }
};

pub const PageCount = extern struct {
    count: u32,

    pub const zero: PageCount = .{ .count = 0 };

    pub inline fn increment(self: *PageCount) void {
        self.count += 1;
    }

    pub fn increaseBySize(self: *PageCount, size: core.Size) void {
        self.count += @intCast(size.divide(architecture.paging.standard_page_size));
    }

    pub fn equal(self: PageCount, other: PageCount) bool {
        return self.count == other.count;
    }

    pub fn fromSize(size: core.Size) PageCount {
        return .{
            .count = @intCast(size.divide(architecture.paging.standard_page_size)),
        };
    }

    pub fn toSize(self: PageCount) core.Size {
        return architecture.paging.standard_page_size.multiplyScalar(self.count);
    }
};

/// Prints the anonymous map.
///
/// Locks the spinlock.
pub fn print(self: *AnonMap, writer: *std.Io.Writer, indent: usize) !void {
    const new_indent = indent + 2;

    self.lock.readLock();
    defer self.lock.readUnlock();

    try writer.writeAll("AnonMap{\n");

    try writer.splatByteAll(' ', new_indent);
    try writer.print("reference_count: {d}\n", .{self.reference_count});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("number_of_pages: {d}\n", .{self.number_of_pages.count});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("pages_in_use: {d}\n", .{self.pages_in_use.count});

    try writer.splatByteAll(' ', indent);
    try writer.writeAll("}");
}

pub inline fn format(_: *const *AnonMap, _: *std.Io.Writer) !void {
    @compileError("use `AnonMap.print` instead");
}

const globals = struct {
    /// Initialized during `init.initializeCaches`.
    var anonymous_map_cache: innigkeit.mem.cache.Cache(AnonMap, null) = undefined;
};

pub const init = struct {
    pub fn initializeCaches() !void {
        log.debug("initializing anonymous map cache", .{});

        globals.anonymous_map_cache.init(.{
            .name = try .fromSlice("anonymous map"),
        });
    }
};
