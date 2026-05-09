const innigkeit = @import("innigkeit");

/// Reads the CR3 register and returns the page table address.
pub inline fn readAddress() innigkeit.PhysicalAddress {
    return .from(asm ("mov %%cr3, %[value]"
        : [value] "=r" (-> u64),
    ) & 0xFFFF_FFFF_FFFF_F000);
}

/// Writes the CR3 register with the given page table address.
pub inline fn writeAddress(address: innigkeit.PhysicalAddress) void {
    asm volatile ("mov %[address], %%cr3"
        :
        : [address] "r" (address.value & 0xFFFF_FFFF_FFFF_F000),
        : .{ .memory = true });
}
