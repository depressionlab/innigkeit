/// IPC message passed through register-width words.
///
/// Small messages (≤ 6 words) are transferred without any memory copies.
/// Bulk data is transferred separately by sharing Frame capabilities.
/// extern guarantees ABI-stable layout for the kernel/userspace pointer handoff.
pub const Message = extern struct {
    /// Caller-defined operation tag (type of request).
    tag: u64 = 0,
    /// Inline message payload — 6 × 8 bytes = 48 bytes.
    words: [6]u64 = [_]u64{0} ** 6,
};
