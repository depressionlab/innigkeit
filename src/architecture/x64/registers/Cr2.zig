//! Stores the linear address that was accessed to result in the last page fault.
const innigkeit = @import("innigkeit");

/// Read the page fault linear address from the CR2 register.
pub inline fn readAddress() innigkeit.VirtualAddress {
    return .from(asm ("mov %%cr2, %[value]"
        : [value] "=r" (-> u64),
    ));
}
