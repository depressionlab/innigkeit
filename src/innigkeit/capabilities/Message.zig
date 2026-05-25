/// IPC message passed through register-width words.
///
/// Small messages (<= 4 words + 4 capability handles) are transferred without
/// any memory copies. Bulk data is transferred separately by sharing Frame
/// capabilities. extern guarantees ABI-stable layout for the kernel/userspace
/// pointer handoff.
///
/// Total size: 8 (tag) + 32 (words) + 16 (caps) = 56 bytes.
pub const Message = extern struct {
    /// Caller-defined operation tag (type of request).
    tag: u64 = 0,
    /// Inline message payload: 4x8 bytes = 32 bytes.
    words: [4]u64 = [_]u64{0} ** 4,
    /// Capability handles to transfer: 4x4 bytes = 16 bytes.
    /// A value of 0 means "no capability". During IPC handoff, each non-zero
    /// handle is copied from the sender's capability table into the receiver's
    /// capability table (with the same rights). The field is updated to the new
    /// handle in the receiver's table, or 0 if the copy fails.
    caps: [4]u32 = [_]u32{0} ** 4,
};
