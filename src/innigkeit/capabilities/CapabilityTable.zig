const CapabilityTable = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");

const ObjectType = @import("ObjectType.zig").ObjectType;
const Rights = @import("Rights.zig").Rights;
const Slot = @import("Slot.zig").Slot;

const cap_count = innigkeit.config.capabilities.slots_per_process;
const null_idx = innigkeit.config.capabilities.null_slot;

lock: innigkeit.sync.TicketSpinLock = .{},
slots: [cap_count]Slot = undefined,
free_head: u32 = 0,

pub fn init(self: *CapabilityTable) void {
    self.lock = .{};
    for (&self.slots, 0..) |*slot, i| {
        slot.ptr_or_next = if (i + 1 < cap_count) i + 1 else null_idx;
        slot.type = .null;
        slot.rights = .{};
    }
    self.free_head = 0;
}

/// Insert a capability. Caller must hold the table lock.
pub fn insertLocked(
    self: *CapabilityTable,
    cap_type: ObjectType,
    ptr: *anyopaque,
    rights: Rights,
) error{Full}!u32 {
    if (core.is_debug) std.debug.assert(self.lock.isLockedByCurrent());
    const idx = self.free_head;
    if (idx >= cap_count) return error.Full;
    self.free_head = @intCast(self.slots[idx].ptr_or_next);
    self.slots[idx] = .{
        .ptr_or_next = @intFromPtr(ptr),
        .type = cap_type,
        .rights = rights,
    };
    return idx;
}

/// Insert a capability, acquiring the lock internally.
pub fn insert(
    self: *CapabilityTable,
    cap_type: ObjectType,
    ptr: *anyopaque,
    rights: Rights,
) error{Full}!u32 {
    self.lock.lock();
    defer self.lock.unlock();
    return self.insertLocked(cap_type, ptr, rights);
}

/// Return a borrow of the slot at `idx`. Caller must hold the table lock.
pub fn getLocked(self: *CapabilityTable, idx: u32) ?*Slot {
    if (core.is_debug) std.debug.assert(self.lock.isLockedByCurrent());
    if (idx >= cap_count) return null;
    const slot = &self.slots[idx];
    if (slot.type == .null) return null;
    return slot;
}

/// Copy a slot to a new index (with optional rights restriction). Caller must hold lock.
pub fn copyLocked(
    self: *CapabilityTable,
    src_idx: u32,
    new_rights: Rights,
) error{ NotFound, Full, RightsEscalation }!u32 {
    if (core.is_debug) std.debug.assert(self.lock.isLockedByCurrent());
    const src = self.getLocked(src_idx) orelse return error.NotFound;
    if (!rightsSubset(new_rights, src.rights)) return error.RightsEscalation;
    const ptr: *anyopaque = @ptrFromInt(src.ptr_or_next);
    refObject(src.type, ptr);
    return self.insertLocked(src.type, ptr, new_rights) catch |e| {
        unrefObject(src.type, ptr);
        return e;
    };
}

/// Remove a slot and drop its reference. Caller must hold lock.
pub fn removeLocked(self: *CapabilityTable, idx: u32) error{NotFound}!void {
    if (core.is_debug) std.debug.assert(self.lock.isLockedByCurrent());
    if (idx >= cap_count) return error.NotFound;
    const slot = &self.slots[idx];
    if (slot.type == .null) return error.NotFound;
    const removed = slot.*;
    slot.ptr_or_next = self.free_head;
    slot.type = .null;
    slot.rights = .{};
    self.free_head = idx;
    unrefObject(removed.type, @ptrFromInt(removed.ptr_or_next));
}

/// Destroy all capabilities in the table (called when a process exits).
pub fn deinitAll(self: *CapabilityTable) void {
    self.lock.lock();
    defer self.lock.unlock();
    for (&self.slots, 0..) |*slot, i| {
        if (slot.type == .null) continue;
        const t = slot.type;
        const ptr: *anyopaque = @ptrFromInt(slot.ptr_or_next);
        slot.ptr_or_next = self.free_head;
        slot.type = .null;
        self.free_head = @intCast(i);
        unrefObject(t, ptr);
    }
}

/// Snapshot of a slot's type, object pointer, and rights.
///
/// The pointed-to object's reference count has been incremented; the caller
/// must call `unrefObject` when done.
pub const SlotInfo = struct {
    cap_type: ObjectType,
    ptr: *anyopaque,
    rights: Rights,
};

/// Look up slot `idx`, bump its object's reference count, and return a snapshot.
///
/// Caller must hold the table lock. Returns null if the slot is empty or out of range.
/// The caller is responsible for calling `unrefObject` on the returned info.
pub fn getAndRefLocked(self: *CapabilityTable, idx: u32) ?SlotInfo {
    if (core.is_debug) std.debug.assert(self.lock.isLockedByCurrent());
    const slot = self.getLocked(idx) orelse return null;
    const info = SlotInfo{
        .cap_type = slot.type,
        .ptr = @ptrFromInt(slot.ptr_or_next),
        .rights = slot.rights,
    };
    refObject(info.cap_type, info.ptr);
    return info;
}

fn rightsSubset(sub: Rights, sup: Rights) bool {
    const sub_int: u16 = @bitCast(sub);
    const sup_int: u16 = @bitCast(sup);
    return (sub_int & sup_int) == sub_int;
}

pub fn refObject(cap_type: ObjectType, ptr: *anyopaque) void {
    switch (cap_type) {
        .null => unreachable,
        .frame => (@as(*@import("types/Frame.zig"), @ptrCast(@alignCast(ptr)))).ref(),
        .notify => (@as(*@import("types/Notify.zig"), @ptrCast(@alignCast(ptr)))).ref(),
        .endpoint => (@as(*@import("types/Endpoint.zig"), @ptrCast(@alignCast(ptr)))).ref(),
    }
}

pub fn unrefObject(cap_type: ObjectType, ptr: *anyopaque) void {
    switch (cap_type) {
        .null => unreachable,
        .frame => (@as(*@import("types/Frame.zig"), @ptrCast(@alignCast(ptr)))).unref(),
        .notify => (@as(*@import("types/Notify.zig"), @ptrCast(@alignCast(ptr)))).unref(),
        .endpoint => (@as(*@import("types/Endpoint.zig"), @ptrCast(@alignCast(ptr)))).unref(),
    }
}
