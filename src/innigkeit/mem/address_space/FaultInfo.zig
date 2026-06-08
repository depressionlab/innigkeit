//! A memory object describing a file or device.
//!
//! A combination of `uvm_faultinfo` and `uvm_faultctx` from OpenBSD uvm.
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
const PhysicalPage = innigkeit.mem.PhysicalPage;
const core = @import("core");

const AddressSpace = @import("AddressSpace.zig");
const AnonMap = @import("AnonMap.zig");
const AnonPage = @import("AnonPage.zig");
const Entry = @import("Entry.zig");
const Object = @import("Object.zig");

const log = innigkeit.debug.log.scoped(.address_space);

const FaultInfo = @This();

address_space: *AddressSpace,

/// The access type of the fault
access_type: innigkeit.mem.PageFaultDetails.AccessType,

/// The address that caused the fault rouded down to the nearest page.
faulting_address: innigkeit.VirtualAddress,

entry: *Entry = undefined,
entries_version: u32 = undefined,

/// The protection we want to enter the page in at.
///
/// This protection can be more restrictive than the protection of the entry.
enter_protection: innigkeit.mem.MapType.Protection = undefined,

wired: bool = false,

promote_to_anonymous_map: bool = false,

anonymous_map_lock_type: core.LockType = .read,
object_lock_type: core.LockType = .read,

const FaultCheckError =
    AddressSpace.HandlePageFaultError ||
    error{
        /// Restart the fault check.
        Restart,
    };

/// Look up entry, check protection, handle needs-copy.
///
///  - Lookup the entry that containing the faulting address.
///  - Check the protection of the entry.
///  - Handle the `needs_copy` flag of the entry.
///  - Lookup anons (if AnonMap exists).
///
/// Called `uvm_faultcheck` in OpenBSD uvm.
pub fn faultCheck(
    self: *FaultInfo,
    anonymous_page: *?*AnonPage,
    fault_type: innigkeit.mem.PageFaultDetails.FaultType,
) FaultCheckError!void {
    _ = fault_type;

    // lookup entry and lock `entries_lock` for reading
    if (!self.faultLookup(.read)) {
        return error.NotMapped;
    }

    log.verbose("fault_lookup found entry with range {f} and protection {f}", .{
        self.entry.range,
        self.entry.protection,
    });

    // check protection
    blk: {
        switch (self.access_type) {
            .read => if (self.entry.protection.read) break :blk,
            .write => if (self.entry.protection.write) break :blk,
            .execute => if (self.entry.protection.execute) break :blk,
        }

        self.address_space.entries_lock.readUnlock();
        return error.Protection;
    }

    // set the protection we want to enter the page in at
    self.enter_protection = self.entry.protection;
    if (self.entry.wired_count != 0) {
        self.wired = true;
        // wired needs full access
        if (self.enter_protection.write) {
            self.access_type = .write;
        } else if (self.enter_protection.execute) {
            self.access_type = .execute;
        }
        // wiring needs write lock
        self.anonymous_map_lock_type = .write;
        self.object_lock_type = .write;
    }

    // handle `needs_copy`
    if (self.entry.needs_copy) {
        if (self.access_type == .write or self.entry.object_reference.object == null) {
            self.address_space.entries_lock.readUnlock();

            log.verbose("clearing needs_copy by copying anonymous map", .{});

            try self.anonymousMapCopy();

            return error.Restart;
        } else if (self.enter_protection.read and self.enter_protection.write and self.access_type == .read) {
            // ensure the page is entered read only since `needs_copy` is still true
            self.enter_protection = .{ .read = true };
        }
    }

    log.verbose("page enter protection: {f}", .{self.enter_protection});

    const anonymous_map_reference = self.entry.anonymous_map_reference;
    const object_reference = self.entry.object_reference;

    if (core.is_debug) std.debug.assert(anonymous_map_reference.anonymous_map != null or object_reference.object != null);

    if (anonymous_map_reference.anonymous_map) |anonymous_map| {
        // we have an anonymous map so lock it and try to extract the page

        if (self.access_type == .write) {
            // assume we are going to COW
            self.anonymous_map_lock_type = .write;
        }
        switch (self.anonymous_map_lock_type) {
            .read => anonymous_map.lock.readLock(),
            .write => anonymous_map.lock.writeLock(),
        }

        anonymous_page.* = anonymous_map_reference.lookup(
            self.entry,
            self.faulting_address,
        );

        if (anonymous_page.* == null) {
            log.verbose("anonymous page not found in anonymous map", .{});
        } else {
            log.verbose("anonymous page found in anonymous map", .{});
        }
    } else {
        log.verbose("anonymous page not found in anonymous map", .{});
        anonymous_page.* = null;
    }

    if (self.access_type == .write) {
        // if we have an object we are going to dirty it so acquire a write lock
        self.object_lock_type = .write;
    }
}

/// Handle a object or zero fill fault.
///
/// Called `uvm_fault_lower` in OpenBSD uvm.
pub fn faultObjectOrZeroFill(self: *FaultInfo) error{ Restart, OutOfMemory }!void {
    log.verbose("handling object or zero fill fault", .{});

    const opt_anonymous_map = self.entry.anonymous_map_reference.anonymous_map;
    const opt_object = self.entry.object_reference.object;

    if (core.is_debug) {
        std.debug.assert(opt_anonymous_map == null or switch (self.anonymous_map_lock_type) {
            .read => opt_anonymous_map.?.lock.isReadLocked(),
            .write => opt_anonymous_map.?.lock.isWriteLocked(),
        });
    }

    const object_page: ObjectPage = if (opt_object) |object| blk: {
        const object_page: ObjectPage = if (true) {
            @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_fault.c#L1370
        } else .need_io;

        if (core.is_debug) {
            std.debug.assert(switch (self.object_lock_type) {
                .read => object.lock.isReadLocked(),
                .write => object.lock.isWriteLocked(),
            });
        }

        // we have a backing object are we going to promote to an anonymous page?
        self.promote_to_anonymous_map = self.access_type == .write and self.entry.copy_on_write;

        break :blk object_page;
    } else blk: {
        // need an anonymous page for zero fill
        self.promote_to_anonymous_map = true;
        break :blk .zero_fill;
    };

    log.verbose(
        "determined object page {t} with promote_to_anonymous_map {}",
        .{ object_page, self.promote_to_anonymous_map },
    );

    switch (object_page) {
        .physical_page => {
            @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_fault.c#L1414-L1416
        },
        .zero_fill => {},
        .need_io => {
            @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_fault.c#L1419-L1421
        },
    }

    if (core.is_debug) std.debug.assert(object_page != .need_io);

    var anonymous_page: *AnonPage = undefined;
    var physical_page: PhysicalPage.Index = undefined;

    if (self.promote_to_anonymous_map) {
        const anonymous_map = opt_anonymous_map.?;

        // promoting requires a write lock
        if (!self.faultAnonymousMapLockUpgrade(anonymous_map)) {
            log.verbose("anonymous map lock upgrade failed", .{});

            // lock upgrade failed, `faultAnonymousMapLockUpgrade` left the anonymous_map lock unlocked
            // unlock everything else and restart the fault
            self.unlockAll(
                null, // left unlocked by `faultAnonymousMapLockUpgrade`
                opt_object,
            );
            return error.Restart;
        }
        if (core.is_debug) {
            std.debug.assert(anonymous_map.lock.isWriteLocked());
            std.debug.assert(opt_object == null or switch (self.object_lock_type) {
                .read => opt_object.?.lock.isReadLocked(),
                .write => opt_object.?.lock.isWriteLocked(),
            });
        }

        try self.promote(
            object_page,
            &anonymous_page,
            &physical_page,
        );

        switch (object_page) {
            .zero_fill => {},
            .physical_page => @panic("NOT IMPLEMENTED"), // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_fault.c#L1473
            .need_io => unreachable,
        }

        try self.entry.anonymous_map_reference.add(
            self.entry,
            self.faulting_address,
            anonymous_page,
            .add,
        ); // TODO: on error maybe we need https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_fault.c#L1508-L1523
    } else {
        @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_fault.c#L1430
    }

    if (core.is_debug) {
        std.debug.assert(opt_anonymous_map == null or switch (self.anonymous_map_lock_type) {
            .read => opt_anonymous_map.?.lock.isReadLocked(),
            .write => opt_anonymous_map.?.lock.isWriteLocked(),
        });
        std.debug.assert(opt_object == null or switch (self.object_lock_type) {
            .read => opt_object.?.lock.isReadLocked(),
            .write => opt_object.?.lock.isWriteLocked(),
        });
    }

    {
        const map_type: innigkeit.mem.MapType = .{
            .type = self.address_space.context,
            .protection = self.enter_protection,
        };

        log.verbose("mapping {f} with {f}", .{ self.faulting_address, map_type });

        self.address_space.page_table_lock.lock();
        defer self.address_space.page_table_lock.unlock();

        // all resources are present time to actually map them in
        innigkeit.mem.mapSinglePage(
            self.address_space.page_table,
            self.faulting_address,
            physical_page,
            map_type,
            innigkeit.mem.PhysicalPage.allocator,
        ) catch {
            self.unlockAll(opt_anonymous_map, opt_object);
            return error.OutOfMemory;
        };
    }

    if (self.wired) {
        @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_fault.c#L1573-L1589
    }

    // TODO: might need https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_fault.c#L1571-L1604

    self.unlockAll(opt_anonymous_map, opt_object);
}

/// Handle a fault where the anonymous map already has a page for the faulting address.
///
/// Three sub-cases:
///   - Read access: map the existing page read-only.
///   - Write access, sole owner (refcount == 1): map writable in-place.
///   - Write access, shared page (refcount > 1): copy-on-write, soallocate a
///     new physical page, copy content, replace in the amap, unshare.
///
/// Called `uvm_fault_upper` in OpenBSD uvm.
pub fn faultUpper(self: *FaultInfo, anonymous_page: *AnonPage) error{ Restart, OutOfMemory }!void {
    const anonymous_map = self.entry.anonymous_map_reference.anonymous_map.?;
    const opt_object = self.entry.object_reference.object;

    // Lock the anonymous page before inspecting its refcount.
    anonymous_page.lock.writeLock();

    var physical_page = anonymous_page.physical_page;

    if (self.access_type == .write and anonymous_page.reference_count > 1) {
        // Copy-on-write: this page is shared; we must make a private copy.

        // Upgrade the anonymous map lock from read -> write (needed to replace
        // the slot). faultAnonymousMapLockUpgrade releases the lock on failure.
        if (!self.faultAnonymousMapLockUpgrade(anonymous_map)) {
            anonymous_page.lock.writeUnlock();
            // anonymous_map lock already released; manually unlock the rest.
            if (opt_object) |object| {
                switch (self.object_lock_type) {
                    .read => object.lock.readUnlock(),
                    .write => object.lock.writeUnlock(),
                }
            }
            self.address_space.entries_lock.readUnlock();
            return error.Restart;
        }

        // Allocate a new physical page.
        const new_phys = innigkeit.mem.PhysicalPage.allocator.allocate() catch {
            anonymous_page.lock.writeUnlock();
            self.unlockAll(anonymous_map, opt_object);
            return error.OutOfMemory;
        };

        // Copy content from old page to new page via the direct-map window.
        const page_size = architecture.paging.standard_page_size.value;
        const src = anonymous_page.physical_page.baseAddress().toDirectMap()
            .toPtr(*align(page_size) const volatile [page_size]u8);
        const dst = new_phys.baseAddress().toDirectMap()
            .toPtr(*align(page_size) volatile [page_size]u8);
        @memcpy(dst, src);

        // Allocate a new AnonPage wrapper for the new physical page.
        const new_anon = AnonPage.create(new_phys) catch {
            var pl: PhysicalPage.List = .{};
            pl.prepend(new_phys);
            innigkeit.mem.PhysicalPage.allocator.deallocate(pl);
            anonymous_page.lock.writeUnlock();
            self.unlockAll(anonymous_map, opt_object);
            return error.OutOfMemory;
        };

        // Decrement the old page's refcount; decrementReferenceCount unlocks it.
        var free_list: PhysicalPage.List = .{};
        anonymous_page.decrementReferenceCount(&free_list);

        // Replace the old slot in the amap with the new page.
        self.entry.anonymous_map_reference.add(
            self.entry,
            self.faulting_address,
            new_anon,
            .replace,
        ) catch {
            // OOM replacing slot: free the page we just allocated.
            var pl: PhysicalPage.List = .{};
            pl.prepend(new_phys);
            innigkeit.mem.PhysicalPage.allocator.deallocate(pl);
            innigkeit.mem.PhysicalPage.allocator.deallocate(free_list);
            self.unlockAll(anonymous_map, opt_object);
            return error.OutOfMemory;
        };

        physical_page = new_phys;
        innigkeit.mem.PhysicalPage.allocator.deallocate(free_list);
    } else {
        // No CoW needed: read access or we are the sole owner.
        anonymous_page.lock.writeUnlock();
    }

    // Map the physical page (new or existing) into the page table.
    {
        const map_type: innigkeit.mem.MapType = .{
            .type = self.address_space.context,
            .protection = self.enter_protection,
        };

        log.verbose("faultUpper: mapping {f} with {f}", .{ self.faulting_address, map_type });

        self.address_space.page_table_lock.lock();
        defer self.address_space.page_table_lock.unlock();

        innigkeit.mem.mapSinglePage(
            self.address_space.page_table,
            self.faulting_address,
            physical_page,
            map_type,
            innigkeit.mem.PhysicalPage.allocator,
        ) catch {
            self.unlockAll(anonymous_map, opt_object);
            return error.OutOfMemory;
        };
    }

    self.unlockAll(anonymous_map, opt_object);
}

/// Look up the entry that contains the faulting address.
///
/// If entry is found returns `true`, fills in `fault_info.entry` and `entries_lock` is left locked.
///
/// If `write_lock` is `true` the `entries_lock` is acquired in write mode.
///
/// Called `uvmfault_lookup` in OpenBSD uvm.
fn faultLookup(self: *FaultInfo, lock_type: core.LockType) bool {
    switch (lock_type) {
        .read => self.address_space.entries_lock.readLock(),
        .write => self.address_space.entries_lock.writeLock(),
    }

    const entry_index = self.address_space.entryIndexByAddress(self.faulting_address) orelse {
        switch (lock_type) {
            .read => self.address_space.entries_lock.readUnlock(),
            .write => self.address_space.entries_lock.writeUnlock(),
        }

        return false;
    };

    self.entry = self.address_space.entries.items[entry_index];

    return true;
}

/// Promote data to a new anonymous page.
///  - Allocate an anonymous page and a page.
///  - Fill its contents
///
/// If the promotion was successful `anonymous_page` and `page` are filled.
///
/// On error everything is unlocked.
///
/// Called `uvmfault_promote` in OpenBSD uvm.
fn promote(
    self: *FaultInfo,
    object_page: ObjectPage,
    anonymous_page: **AnonPage,
    physical_page: *PhysicalPage.Index,
) error{ Restart, OutOfMemory }!void {
    log.verbose("promoting to an anonymous page", .{});

    const anonymous_map = self.entry.anonymous_map_reference.anonymous_map.?;
    if (core.is_debug) std.debug.assert(anonymous_map.lock.isWriteLocked());

    const opt_object = switch (object_page) {
        .zero_fill => null,
        .physical_page => self.entry.object_reference.object,
        .need_io => unreachable,
    };
    if (core.is_debug) std.debug.assert(opt_object == null or (opt_object.?.lock.isReadLocked() or opt_object.?.lock.isWriteLocked()));

    const allocated_physical_page = innigkeit.mem.PhysicalPage.allocator.allocate() catch {
        self.unlockAll(self.entry.anonymous_map_reference.anonymous_map, self.entry.object_reference.object);
        return error.OutOfMemory;
    };
    physical_page.* = allocated_physical_page;

    anonymous_page.* = AnonPage.create(allocated_physical_page) catch {
        var pl: PhysicalPage.List = .{};
        pl.prepend(allocated_physical_page);
        innigkeit.mem.PhysicalPage.allocator.deallocate(pl);
        self.unlockAll(self.entry.anonymous_map_reference.anonymous_map, self.entry.object_reference.object);
        return error.OutOfMemory;
    };

    log.verbose(
        "allocated anonymous page for {f} at {f}",
        .{ self.faulting_address, allocated_physical_page.baseAddress() },
    );

    switch (object_page) {
        .zero_fill => {
            log.verbose("zero filling anonymous page", .{});
            const mapped_page = allocated_physical_page.baseAddress().toDirectMap()
                .toPtr(*align(architecture.paging.standard_page_size.value) volatile [architecture.paging.standard_page_size.value]u8);
            @memset(mapped_page, 0);
        },
        .physical_page => @panic("NOT IMPLEMENTED"), // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_fault.c#L545
        .need_io => unreachable,
    }
}

/// Clear the `needs_copy` flag.
///
/// Lock is unlocked on successful return.
///
/// The `entries_lock` must be unlocked.
///
/// Called `uvmfault_amapcopy` in OpenBSD uvm.
fn anonymousMapCopy(self: *FaultInfo) error{ NotMapped, OutOfMemory }!void {
    // lookup entry and lock `entries_lock` for writing
    if (!self.faultLookup(.write)) return error.NotMapped;
    defer self.address_space.entries_lock.writeUnlock();

    if (!self.entry.needs_copy) return; // someone else already copied the anonymous map

    try AnonMap.copy(
        self.address_space,
        self.entry,
        self.faulting_address,
    );
}

/// Upgrade the anonymous map lock from read to write.
///
/// Returns `true` if the upgrade was successful.
///
/// Returns `false` if the upgrade failed, in this case the lock is left unlocked.
///
/// Called `uvm_fault_upper_upgrade` in OpenBSD uvm.
fn faultAnonymousMapLockUpgrade(self: *FaultInfo, anonymous_map: *AnonMap) bool {
    if (core.is_debug) {
        std.debug.assert(switch (self.anonymous_map_lock_type) {
            .read => anonymous_map.lock.isReadLocked(),
            .write => anonymous_map.lock.isWriteLocked(),
        });
    }

    // fast path
    if (self.anonymous_map_lock_type == .write) {
        return true;
    }

    // try for upgrade
    // if we don't succeed unlock everything and restart the fault and next time get a write lock
    self.anonymous_map_lock_type = .write;
    if (!anonymous_map.lock.tryUpgradeLock()) {
        // `tryUpgradeLock` leaves the lock unlocked if it fails
        return false;
    }

    if (core.is_debug) {
        std.debug.assert(switch (self.anonymous_map_lock_type) {
            .read => anonymous_map.lock.isReadLocked(),
            .write => anonymous_map.lock.isWriteLocked(),
        });
    }

    return true;
}

/// Unlock everything passed in.
///
/// Called `uvmfault_unlockall` in OpenBSD uvm.
fn unlockAll(self: *FaultInfo, opt_anonymous_map: ?*AnonMap, opt_object: ?*Object) void {
    if (opt_object) |object| {
        switch (self.object_lock_type) {
            .read => object.lock.readUnlock(),
            .write => object.lock.writeUnlock(),
        }
    }

    if (opt_anonymous_map) |anonymous_map| {
        switch (self.anonymous_map_lock_type) {
            .read => anonymous_map.lock.readUnlock(),
            .write => anonymous_map.lock.writeUnlock(),
        }
    }

    self.address_space.entries_lock.readUnlock();
}

const ObjectPage = union(enum) {
    need_io,
    zero_fill,
    physical_page: PhysicalPage.Index,
};
