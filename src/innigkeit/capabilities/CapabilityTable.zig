const CapabilityTable = @This();

const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

const Message = @import("Message.zig").Message;
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
///
/// Rejects a revoked source slot (`NotFound`).
pub fn copyLocked(
    self: *CapabilityTable,
    src_idx: u32,
    new_rights: Rights,
) error{ NotFound, Full, RightsEscalation }!u32 {
    if (core.is_debug) std.debug.assert(self.lock.isLockedByCurrent());
    const src = self.getAndRefLocked(src_idx) orelse return error.NotFound;
    if (!rightsSubset(new_rights, src.rights)) {
        unrefObject(src.cap_type, src.ptr);
        return error.RightsEscalation;
    }
    return self.insertLocked(src.cap_type, src.ptr, new_rights) catch |e| {
        unrefObject(src.cap_type, src.ptr);
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
    // ptr_or_next does hold a real pointer (see Slot.zig: type != .null).
    unrefObject(removed.type, @ptrFromInt(removed.ptr_or_next));
}

/// Destroy all capabilities in the table (called when a process exits).
pub fn deinitAll(self: *CapabilityTable) void {
    self.lock.lock();
    defer self.lock.unlock();
    for (&self.slots, 0..) |*slot, i| {
        if (slot.type == .null) continue;
        const t = slot.type;
        // ptr_or_next does hold a real pointer (see Slot.zig: type != .null).
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
    // ptr_or_next does hold a real pointer (see Slot.zig: type != .null).
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
    // ptr_or_next does hold a real pointer (see Slot.zig: type != .null).
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

/// Transfer capability handles embedded in `msg` from `sender_task` to `receiver_task`.
///
/// Holds both tables' locks simultaneously for the entire transfer to prevent
/// TOCTOU races with concurrent revocation. Locks are acquired in ascending
/// pointer order to prevent deadlock when src and dst are different tables.
pub fn transferCaps(msg: *Message, sender_task: *innigkeit.Task, receiver_task: *innigkeit.Task) void {
    if (sender_task.type != .user or receiver_task.type != .user) return;

    const src_table = innigkeit.user.Process.from(sender_task).cap_table;
    const dst_table = innigkeit.user.Process.from(receiver_task).cap_table;

    const same = @intFromPtr(src_table) == @intFromPtr(dst_table);
    if (!same) {
        if (@intFromPtr(src_table) < @intFromPtr(dst_table)) {
            src_table.lock.lock();
            dst_table.lock.lock();
        } else {
            dst_table.lock.lock();
            src_table.lock.lock();
        }
    } else {
        src_table.lock.lock();
    }

    for (&msg.caps) |*handle| {
        if (handle.* == 0) continue;
        const info = src_table.getAndRefLocked(handle.*) orelse {
            handle.* = 0;
            continue;
        };
        if (!info.rights.grant) {
            unrefObject(info.cap_type, info.ptr);
            handle.* = 0;
            continue;
        }
        const new_handle = dst_table.insertLocked(info.cap_type, info.ptr, info.rights) catch {
            unrefObject(info.cap_type, info.ptr);
            handle.* = 0;
            continue;
        };
        handle.* = new_handle;
    }

    src_table.lock.unlock();
    if (!same) dst_table.lock.unlock();
}

const Frame = @import("types/Frame.zig");
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
    const info = table.getAndRefLocked(slot_idx).?;
    unrefObject(info.cap_type, info.ptr);
}

test "capability: Frame sharing transfers backing zero-copy and can restrict rights" {
    const frame = try Frame.create(); // refcount = 1, owned by the client slot below

    var client: CapabilityTable = undefined;
    client.init();
    var server: CapabilityTable = undefined;
    server.init();

    // Client holds the buffer read+write.
    client.lock.lock();
    const ha = try client.insertLocked(.frame, frame, .{ .read = true, .write = true });
    client.lock.unlock();

    // Transfer (the move Endpoint.transferCaps does): ref out of the client, then
    // insert into the server with rights narrowed to read-only. The ref taken by
    // getAndRefLocked becomes the server slot's owned ref (no unref in between).
    client.lock.lock();
    const moved = client.getAndRefLocked(ha).?;
    client.lock.unlock();
    try std.testing.expectEqual(ObjectType.frame, moved.cap_type);

    server.lock.lock();
    const hb = try server.insertLocked(moved.cap_type, moved.ptr, .{ .read = true, .write = false });
    server.lock.unlock();

    // The server's view is the SAME physical frame (zero-copy)...
    server.lock.lock();
    const sinfo = server.getAndRefLocked(hb).?;
    server.lock.unlock();
    const server_frame: *Frame = @ptrCast(@alignCast(sinfo.ptr));
    try std.testing.expect(server_frame == frame);
    try std.testing.expectEqual(frame.page, server_frame.page);
    // ...but read-only (the compositor cannot scribble on a client's buffer).
    try std.testing.expect(sinfo.rights.read and !sinfo.rights.write);

    // The client still holds read+write to that same frame.
    client.lock.lock();
    const cinfo = client.getAndRefLocked(ha).?;
    client.lock.unlock();
    try std.testing.expect(@as(*Frame, @ptrCast(@alignCast(cinfo.ptr))) == frame);
    try std.testing.expect(cinfo.rights.read and cinfo.rights.write);

    unrefObject(sinfo.cap_type, sinfo.ptr);
    unrefObject(cinfo.cap_type, cinfo.ptr);
    client.lock.lock();
    client.removeLocked(ha) catch unreachable;
    client.lock.unlock();
    server.lock.lock();
    server.removeLocked(hb) catch unreachable;
    server.lock.unlock();
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
        const a = table.getAndRefLocked(slot_a).?;
        unrefObject(a.cap_type, a.ptr);
        const b = table.getAndRefLocked(slot_b).?;
        unrefObject(b.cap_type, b.ptr);
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
    const info = table.getAndRefLocked(slot).?;
    unrefObject(info.cap_type, info.ptr);
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
    const info_b = table.getAndRefLocked(slot_b).?;
    unrefObject(info_b.cap_type, info_b.ptr);

    // Revoke again through slot_b.
    try table.revokeLocked(slot_b);
    try std.testing.expect(table.getAndRefLocked(slot_b) == null);
}

test "capability: copyLocked rejects a revoked source slot" {
    const notify = try Notify.create();
    defer notify.unref();

    var table: CapabilityTable = undefined;
    table.init();
    table.lock.lock();
    defer table.lock.unlock();

    notify.ref();
    const slot_a = try table.insertLocked(.notify, notify, .all);
    try table.revokeLocked(slot_a);

    // The slot is stale (fails getAndRefLocked); copying from it must not
    // mint a fresh, live capability to the same object.
    try std.testing.expectError(error.NotFound, table.copyLocked(slot_a, .all));
}

test "capability: copyLocked rejects rights escalation, allows equal/subset" {
    const notify = try Notify.create();
    defer notify.unref();

    var table: CapabilityTable = undefined;
    table.init();
    table.lock.lock();
    defer table.lock.unlock();

    notify.ref();
    const src = try table.insertLocked(.notify, notify, .{ .read = true, .write = true });

    // Adding any right the source lacks is an escalation.
    try std.testing.expectError(error.RightsEscalation, table.copyLocked(src, .all));
    try std.testing.expectError(
        error.RightsEscalation,
        table.copyLocked(src, .{ .read = true, .grant = true }),
    );

    // Equal rights and strict subsets are fine.
    const equal_copy = try table.copyLocked(src, .{ .read = true, .write = true });
    const subset_copy = try table.copyLocked(src, .{ .read = true });

    const subset_slot = table.getLocked(subset_copy).?;
    try std.testing.expect(subset_slot.rights.read);
    try std.testing.expect(!subset_slot.rights.write);

    try table.removeLocked(equal_copy);
    try table.removeLocked(subset_copy);
    try table.removeLocked(src);
}

test "capability: removeLocked frees the slot for reuse" {
    const notify = try Notify.create();
    defer notify.unref();

    var table: CapabilityTable = undefined;
    table.init();
    table.lock.lock();
    defer table.lock.unlock();

    notify.ref();
    const slot_a = try table.insertLocked(.notify, notify, .all);
    notify.ref();
    const slot_b = try table.insertLocked(.notify, notify, .all);
    try std.testing.expect(slot_a != slot_b);

    try table.removeLocked(slot_a);
    try std.testing.expect(table.getLocked(slot_a) == null);
    try std.testing.expectError(error.NotFound, table.removeLocked(slot_a));

    // The freed index is at the head of the free list and is handed back.
    notify.ref();
    const slot_c = try table.insertLocked(.notify, notify, .all);
    try std.testing.expectEqual(slot_a, slot_c);
    try std.testing.expect(table.getLocked(slot_c) != null);

    try table.removeLocked(slot_b);
    try table.removeLocked(slot_c);
}

test "capability: table is full after all slots are used" {
    const notify = try Notify.create();
    defer notify.unref();
    const baseline = notify.refcount.load(.acquire);

    var table: CapabilityTable = undefined;
    table.init();

    table.lock.lock();
    var inserted: u32 = 0;
    while (inserted < cap_count) : (inserted += 1) {
        notify.ref();
        _ = table.insertLocked(.notify, notify, .all) catch unreachable;
    }

    notify.ref();
    try std.testing.expectError(error.Full, table.insertLocked(.notify, notify, .all));
    notify.unref(); // undo the ref taken for the failed insert
    table.lock.unlock();

    // deinitAll drops every table reference; no refs may leak.
    table.deinitAll();
    try std.testing.expectEqual(baseline, notify.refcount.load(.acquire));

    // The free list has been rebuilt: the table is usable again.
    table.lock.lock();
    notify.ref();
    const idx = table.insertLocked(.notify, notify, .all) catch unreachable;
    try table.removeLocked(idx);
    table.lock.unlock();
    try std.testing.expectEqual(baseline, notify.refcount.load(.acquire));
}

test "capability: refcount returns to baseline after remove (no leak)" {
    const notify = try Notify.create();
    defer notify.unref();
    const baseline = notify.refcount.load(.acquire);

    var table: CapabilityTable = undefined;
    table.init();
    table.lock.lock();
    defer table.lock.unlock();

    // The caller takes the reference owned by the table slot.
    notify.ref();
    const idx = try table.insertLocked(.notify, notify, .all);
    try std.testing.expectEqual(baseline + 1, notify.refcount.load(.acquire));

    // getAndRefLocked hands out an extra reference...
    const info = table.getAndRefLocked(idx).?;
    try std.testing.expectEqual(baseline + 2, notify.refcount.load(.acquire));

    // ...returned via unrefObject.
    unrefObject(info.cap_type, info.ptr);
    try std.testing.expectEqual(baseline + 1, notify.refcount.load(.acquire));

    // removeLocked drops the slot's reference: back to baseline.
    try table.removeLocked(idx);
    try std.testing.expectEqual(baseline, notify.refcount.load(.acquire));
}

fn randomRights(random: std.Random) Rights {
    return .{
        .read = random.boolean(),
        .write = random.boolean(),
        .grant = random.boolean(),
        .revoke = random.boolean(),
    };
}

fn randomSubsetOf(random: std.Random, of: Rights) Rights {
    return .{
        .read = of.read and random.boolean(),
        .write = of.write and random.boolean(),
        .grant = of.grant and random.boolean(),
        .revoke = of.revoke and random.boolean(),
    };
}

fn rightsRaw(r: Rights) u16 {
    return @bitCast(r);
}

// Zig-side counterpart to docs/formal/capability_revocation.tla's
// RightsMonotonicity invariant.
test "capability: property rights-monotonicity holds under randomized copy/revoke/remove sequences" {
    const object_count = 3;
    var objects: [object_count]*Notify = undefined;
    for (&objects) |*o| o.* = try Notify.create();
    defer for (objects) |o| o.unref();

    var root_rights: [object_count]Rights = .{Rights{}} ** object_count;
    var created: [object_count]bool = .{false} ** object_count;
    // slot_owner[idx] tracks which modeled object (if any) currently
    // occupies physical slot idx, mirroring the TLA+ model's table[p][s].obj
    // for the single process this test exercises.
    var slot_owner: [cap_count]?usize = .{null} ** cap_count;

    var table: CapabilityTable = undefined;
    table.init();
    table.lock.lock();
    defer table.lock.unlock();

    var prng: std.Random.DefaultPrng = .init(0xCAB_00);
    const random = prng.random();

    const iterations = 2000;
    for (0..iterations) |_| {
        switch (random.uintLessThan(u8, 4)) {
            0 => { // Grant: the one-shot root insert of a not-yet-created object.
                const obj_idx = random.uintLessThan(usize, object_count);
                if (created[obj_idx]) continue;
                const rights = randomRights(random);
                objects[obj_idx].ref();
                const idx = table.insertLocked(.notify, objects[obj_idx], rights) catch {
                    objects[obj_idx].unref();
                    continue;
                };
                created[obj_idx] = true;
                root_rights[obj_idx] = rights;
                slot_owner[idx] = obj_idx;
            },
            1 => { // CopyCap
                const src: u32 = random.uintLessThan(u32, cap_count);
                const src_obj = slot_owner[src] orelse continue;
                const src_rights = table.getLocked(src).?.rights;
                const new_rights = randomSubsetOf(random, src_rights);
                const idx = table.copyLocked(src, new_rights) catch continue;
                slot_owner[idx] = src_obj;
            },
            2 => { // Revoke
                const s: u32 = random.uintLessThan(u32, cap_count);
                if (slot_owner[s] == null) continue;
                table.revokeLocked(s) catch continue;
            },
            3 => { // RemoveCap
                const s: u32 = random.uintLessThan(u32, cap_count);
                if (slot_owner[s] == null) continue;
                table.removeLocked(s) catch continue;
                slot_owner[s] = null;
            },
            else => unreachable,
        }

        // RightsMonotonicity: every LIVE slot's rights must be bounded by
        // its object's one-time root grant. A stale (revoked) slot is
        // skipped, exactly like the model's IsLive guard: getAndRefLocked
        // returning null is the real-code equivalent of ~IsLive.
        for (0..cap_count) |s| {
            const obj_idx = slot_owner[s] orelse continue;
            const info = table.getAndRefLocked(@intCast(s)) orelse continue;
            defer unrefObject(info.cap_type, info.ptr);
            const escalation = rightsRaw(info.rights) & ~rightsRaw(root_rights[obj_idx]);
            try std.testing.expectEqual(@as(u16, 0), escalation);
        }
    }

    for (0..cap_count) |s| {
        if (slot_owner[s] != null) table.removeLocked(@intCast(s)) catch unreachable;
    }
}
