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
};
