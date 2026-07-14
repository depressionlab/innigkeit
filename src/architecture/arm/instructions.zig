const innigkeit = @import("innigkeit");

pub inline fn readPhysicalCount() u64 {
    return asm ("mrs %[ret], cntpct_el0"
        : [ret] "=r" (-> u64),
    );
}

// PCI enhanced configuration space (ECAM) access.
//
// `address` is a kernel virtual address into the ECAM window, which is mapped
// Device-nGnRE by `pci/init.zig initializeECAM` (`allocateSpecial(.cache =
// .uncached)`). On AArch64 a plain (size-correct) load/store at that address
// performs the MMIO config-space access. The x86 equivalent of the `mov`s in
// `x64/instructions.zig`. Volatile pointer dereferences emit the right
// `ldr`/`str` and (because the mapping is Device-nGnRE) are not reordered or
// elided; the same helpers also back the virtio legacy memory-BAR `PortIo`.

pub inline fn readPciU8(address: innigkeit.KernelVirtualAddress) u8 {
    // ECAM window, see comment above
    return @as(*const volatile u8, @ptrFromInt(address.value)).*;
}

pub inline fn readPciU16(address: innigkeit.KernelVirtualAddress) u16 {
    // ECAM window, see comment above
    return @as(*const volatile u16, @ptrFromInt(address.value)).*;
}

pub inline fn readPciU32(address: innigkeit.KernelVirtualAddress) u32 {
    // ECAM window, see comment above
    return @as(*const volatile u32, @ptrFromInt(address.value)).*;
}

pub inline fn writePciU8(address: innigkeit.KernelVirtualAddress, value: u8) void {
    // ECAM window, see comment above
    @as(*volatile u8, @ptrFromInt(address.value)).* = value;
}

pub inline fn writePciU16(address: innigkeit.KernelVirtualAddress, value: u16) void {
    // ECAM window, see comment above
    @as(*volatile u16, @ptrFromInt(address.value)).* = value;
}

pub inline fn writePciU32(address: innigkeit.KernelVirtualAddress, value: u32) void {
    // ECAM window, see comment above
    @as(*volatile u32, @ptrFromInt(address.value)).* = value;
}

pub inline fn halt() void {
    asm volatile ("wfe");
}

/// Instruction synchronization barrier.
///
/// Instruction Synchronization Barrier flushes the pipeline in the PE and is a context synchronization event.
pub inline fn isb() void {
    asm volatile ("isb" ::: .{ .memory = true });
}

/// Disable interrupts and put the CPU to sleep.
pub inline fn disableInterruptsAndHalt() noreturn {
    while (true) {
        asm volatile (
            \\ msr DAIFSet, #0b1111
            \\ wfe
        );
    }
}

/// Disable interrupts.
pub inline fn disableInterrupts() void {
    asm volatile ("msr DAIFSet, #0b1111");
}

/// Enable interrupts.
pub inline fn enableInterrupts() void {
    asm volatile ("msr DAIFClr, #0b1111;");
}

/// Are interrupts enabled?
pub inline fn interruptsEnabled() bool {
    const daif = asm ("mrs %[daif], DAIF"
        : [daif] "=r" (-> u64),
    );
    const mask: u64 = 0b1111000000;
    return (daif & mask) == 0;
}
