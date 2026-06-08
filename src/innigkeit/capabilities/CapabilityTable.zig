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
        .generation = objectGeneration(cap_type, ptr),
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

/// Look up slot `idx`, validate it has not been revoked, bump its reference count,
/// and return a snapshot.
///
/// Caller must hold the table lock. Returns null if the slot is empty, out of range,
/// or revoked (object generation differs from the stored generation).
/// The caller is responsible for calling `unrefObject` on the returned info.
pub fn getAndRefLocked(self: *CapabilityTable, idx: u32) ?SlotInfo {
    if (core.is_debug) std.debug.assert(self.lock.isLockedByCurrent());
    const slot = self.getLocked(idx) orelse return null;
    const ptr: *anyopaque = @ptrFromInt(slot.ptr_or_next);
    if (slot.generation != objectGeneration(slot.type, ptr)) return null;
    const info = SlotInfo{ .cap_type = slot.type, .ptr = ptr, .rights = slot.rights };
    refObject(info.cap_type, info.ptr);
    return info;
}

/// Revoke the capability at `idx` by incrementing the underlying object's generation.
///
/// After this call every slot in every table that points to the same object (regardless
/// of which process holds it) will fail `getAndRefLocked` with null (EBADF).
/// The slot itself is NOT removed: it stays in place with stale generation so the
/// process can still see it exists (and optionally delete it). Requires the slot to
/// have `.revoke` rights.
///
/// Caller must hold the table lock.
pub fn revokeLocked(self: *CapabilityTable, idx: u32) error{ NotFound, NoRevokeRight }!void {
    if (core.is_debug) std.debug.assert(self.lock.isLockedByCurrent());
    const slot = self.getLocked(idx) orelse return error.NotFound;
    if (!slot.rights.revoke) return error.NoRevokeRight;
    incrementObjectGeneration(slot.type, @ptrFromInt(slot.ptr_or_next));
}

/// Map each non-null ObjectType tag to its Zig type.
fn TypeForTag(comptime tag: ObjectType) type {
    return switch (tag) {
        .null => unreachable,
        .frame => @import("types/Frame.zig"),
        .notify => @import("types/Notify.zig"),
        .endpoint => @import("types/Endpoint.zig"),
        .reply => @import("types/Reply.zig"),
        .secure_vault => @import("types/SecureVault.zig"),
        .gpu_buffer => @import("types/GpuBuffer.zig"),
    };
}

/// Read the current generation counter of a capability object.
fn objectGeneration(cap_type: ObjectType, ptr: *anyopaque) u32 {
    return switch (cap_type) {
        .null => unreachable,
        inline else => |tag| @as(*TypeForTag(tag), @ptrCast(@alignCast(ptr))).generation.load(.acquire),
    };
}

/// Atomically increment the generation counter, invalidating all existing slots
/// that point to this object (they will see a generation mismatch on next lookup).
fn incrementObjectGeneration(cap_type: ObjectType, ptr: *anyopaque) void {
    switch (cap_type) {
        .null => unreachable,
        inline else => |tag| _ = @as(*TypeForTag(tag), @ptrCast(@alignCast(ptr))).generation.fetchAdd(1, .acq_rel),
    }
}

fn rightsSubset(sub: Rights, sup: Rights) bool {
    const sub_int: u16 = @bitCast(sub);
    const sup_int: u16 = @bitCast(sup);
    return (sub_int & sup_int) == sub_int;
}

pub fn refObject(cap_type: ObjectType, ptr: *anyopaque) void {
    switch (cap_type) {
        .null => unreachable,
        inline else => |tag| @as(*TypeForTag(tag), @ptrCast(@alignCast(ptr))).ref(),
    }
}

pub fn unrefObject(cap_type: ObjectType, ptr: *anyopaque) void {
    switch (cap_type) {
        .null => unreachable,
        inline else => |tag| @as(*TypeForTag(tag), @ptrCast(@alignCast(ptr))).unref(),
    }
}

const Notify = @import("types/Notify.zig");

test "capability: fresh slot passes generation check" {
    const notify = try Notify.create();
    defer notify.unref();

    var table: CapabilityTable = undefined;
    table.init();
    table.lock.lock();
    defer table.lock.unlock();

    notify.ref();
    const slot_idx = try table.insertLocked(.notify, notify, .all);

    const info = table.getAndRefLocked(slot_idx);
    try std.testing.expect(info != null);
    unrefObject(info.?.cap_type, info.?.ptr);
}

test "capability: revoke invalidates all slots pointing to the same object" {
    const notify = try Notify.create();
    defer notify.unref();

    var table: CapabilityTable = undefined;
    table.init();
    table.lock.lock();
    defer table.lock.unlock();

    // Insert the same object twice (two independent capability slots).
    notify.ref();
    const slot_a = try table.insertLocked(.notify, notify, .all);
    notify.ref();
    const slot_b = try table.insertLocked(.notify, notify, .{ .read = true });

    // Both valid before revocation.
    {
        const a = table.getAndRefLocked(slot_a);
        try std.testing.expect(a != null);
        unrefObject(a.?.cap_type, a.?.ptr);
        const b = table.getAndRefLocked(slot_b);
        try std.testing.expect(b != null);
        unrefObject(b.?.cap_type, b.?.ptr);
    }

    // Revoke via slot_a (has .revoke right).
    try table.revokeLocked(slot_a);

    // Both slots now return null, so object generation has advanced.
    try std.testing.expect(table.getAndRefLocked(slot_a) == null);
    try std.testing.expect(table.getAndRefLocked(slot_b) == null);
}

test "capability: revoke requires revoke right" {
    const notify = try Notify.create();
    defer notify.unref();

    var table: CapabilityTable = undefined;
    table.init();
    table.lock.lock();
    defer table.lock.unlock();

    notify.ref();
    const slot = try table.insertLocked(.notify, notify, .{ .read = true, .write = true });

    try std.testing.expectError(error.NoRevokeRight, table.revokeLocked(slot));
    // Slot still valid after a failed revoke attempt.
    const info = table.getAndRefLocked(slot);
    try std.testing.expect(info != null);
    unrefObject(info.?.cap_type, info.?.ptr);
}

test "capability: double revoke uses the new generation (second revoke works)" {
    const notify = try Notify.create();
    defer notify.unref();

    var table: CapabilityTable = undefined;
    table.init();
    table.lock.lock();
    defer table.lock.unlock();

    notify.ref();
    const slot_a = try table.insertLocked(.notify, notify, .all);
    try table.revokeLocked(slot_a);

    // Re-insert the same object into a new slot.
    // It picks up the current generation.
    notify.ref();
    const slot_b = try table.insertLocked(.notify, notify, .all);
    const info_b = table.getAndRefLocked(slot_b);
    try std.testing.expect(info_b != null);
    unrefObject(info_b.?.cap_type, info_b.?.ptr);

    // Revoke again through slot_b.
    try table.revokeLocked(slot_b);
    try std.testing.expect(table.getAndRefLocked(slot_b) == null);
}
