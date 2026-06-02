//! User-buffer validation shared across all syscall handlers.

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");

/// Returns true iff the range [ptr, ptr+len) lies entirely within the user
/// virtual address space and does not wrap around zero.
pub fn validateUserBuffer(ptr: usize, len: usize) bool {
    if (len == 0) return true;
    if (ptr +% len < ptr) return false;
    const range: innigkeit.VirtualRange = .from(
        .from(ptr),
        .from(len, .byte),
    );
    return architecture.user.user_memory_range.fullyContains(range);
}
