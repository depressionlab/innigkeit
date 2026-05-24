const ObjectType = @import("ObjectType.zig").ObjectType;
const Rights = @import("Rights.zig").Rights;

/// A single entry in a process capability table.
///
/// When `type == .null`, `ptr_or_next` stores the next free slot index.
/// When `type != .null`, `ptr_or_next` stores a raw kernel object pointer.
pub const Slot = struct {
    ptr_or_next: usize = 0,
    type: ObjectType = .null,
    rights: Rights = .{},
    /// The object's generation counter at the time this slot was created.
    /// If the current object generation differs, the capability has been revoked.
    generation: u32 = 0,
};
