//! A page of anonymous memory.
//!
//! Called a `vm_anon` in uvm.
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
const Cache = innigkeit.memory.cache.Cache;
const PhysicalPage = innigkeit.memory.PhysicalPage;
const core = @import("core");

const log = innigkeit.debug.log.scoped(.address_space);

const AnonPage = @This();

lock: innigkeit.sync.RwLock = .{},

reference_count: u32 = 1,

physical_page: PhysicalPage.Index,

pub fn create(physical_page: PhysicalPage.Index) !*AnonPage {
    const anonymous_page = try globals.anonymous_page_cache.allocate();
    anonymous_page.* = .{
        .physical_page = physical_page,
    };
    return anonymous_page;
}

/// Increment the reference count.
///
/// When called the lock must be held.
pub fn incrementReferenceCount(self: *AnonPage) void {
    if (core.is_debug) {
        std.debug.assert(self.reference_count != 0);
        std.debug.assert(self.lock.isWriteLocked());
    }

    self.reference_count += 1;
}

/// Decrement the reference count.
///
/// When called the a write lock must be held, upon return the lock is unlocked.
pub fn decrementReferenceCount(self: *AnonPage, deallocate_page_list: *innigkeit.memory.PhysicalPage.List) void {
    if (core.is_debug) {
        std.debug.assert(self.reference_count != 0);
        std.debug.assert(self.lock.isWriteLocked());
    }

    const reference_count = self.reference_count;
    self.reference_count = reference_count - 1;

    if (reference_count == 1) {
        // reference count is now zero, destroy the anonymous page
        self.destroy(deallocate_page_list);
        return;
    }

    self.lock.writeUnlock();
}

/// Destroy the anonymous page.
///
/// Only called by `decrementReferenceCount` when the reference count is zero.
///
/// Called `uvm_anfree` in OpenBSD uvm.
fn destroy(self: *AnonPage, deallocate_page_list: *innigkeit.memory.PhysicalPage.List) void {
    if (core.is_debug) {
        std.debug.assert(self.lock.isWriteLocked());
        std.debug.assert(self.reference_count == 0);
    }

    deallocate_page_list.prepend(self.physical_page);

    self.lock.writeUnlock();
    globals.anonymous_page_cache.deallocate(self);
}

const globals = struct {
    /// Initialized during `init.initializeCaches`.
    var anonymous_page_cache: Cache(AnonPage, null) = undefined;
};

pub const init = struct {
    pub fn initializeCaches() !void {
        log.debug("initializing anonymous page cache", .{});

        globals.anonymous_page_cache.init(.{
            .name = try .fromSlice("anonymous page"),
        });
    }
};
