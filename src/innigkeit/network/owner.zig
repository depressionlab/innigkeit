//! Who a socket belongs to.
//!
//! Socket ids are small indices into global tables. Userspace never sees them:
//! it holds `capabilities.NetSocket` handles, and each table slot records the
//! owning object. Every table operation takes the caller's owner; a mismatch is
//! indistinguishable from a closed or invalid id (docs/security-audit.md F4).

pub const Owner = enum(usize) {
    /// Kernel-internal users (the in-kernel test harness, the fuzz channel).
    /// Syscall handlers never pass this, so user code can neither use nor
    /// close a socket opened by the kernel.
    kernel = 0,
    _,

    /// A `capabilities.NetSocket`, identified by its address. That address is a
    /// stable identity because the object closes everything it owns before it
    /// is freed (`NetSocket.unref`), so a slot can never outlive its owner.
    pub fn of(object: *const anyopaque) Owner {
        return @fromBackingInt(@intFromPtr(object));
    }
};
