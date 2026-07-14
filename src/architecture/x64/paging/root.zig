const std = @import("std");

const core = @import("core");
const innigkeit = @import("innigkeit");

const x64 = @import("../x64.zig");
pub const PageFaultErrorCode = @import("PageFaultErrorCode.zig").PageFaultErrorCode;
pub const PageTable = @import("PageTable.zig").PageTable;

/// Copy `source.size` bytes from `source` to `destination`.
///
/// Records the recovery label `1:` into `target.*` before the copy: if a page
/// fault during the `rep movsb` is unhandleable, the page-fault handler sets
/// `rip` to that label (and flips the active `memory.safe.ResultSlot`), so the copy
/// aborts and returns instead of panicking. The explicit rsi/rdi/rcx clobbers
/// are required for correctness (a "+{reg}" tie alone miscompiles).
pub fn safeMemcpy(
    destination: innigkeit.VirtualRange,
    source: innigkeit.VirtualRange,
    target: *innigkeit.KernelVirtualAddress,
) void {
    asm volatile (
        \\lea 1f(%rip), %rax
        \\mov %rax, (%[target])
        \\
        \\rep movsb
        \\
        \\1:
        :
        : [target] "r" (target),
          [source_ptr] "+{rsi}" (source.address.value),
          [destination_ptr] "+{rdi}" (destination.address.value),
          [count] "+{rcx}" (source.size.value),
        : .{ .rax = true, .rsi = true, .rdi = true, .rcx = true, .memory = true });
}

/// Atomically load a `u32` from `address` (acquire) into `out`.
///
/// Records the recovery label `1:` into `target.*` before the load: on a fault
/// the page-fault handler sets `rip` there (and flips the active
/// `memory.safe.ResultSlot`) so the access aborts and returns instead of panicking.
/// An aligned 32-bit `mov` is a single atomic load with acquire ordering on
/// x86-64 (TSO), as the futex word check requires.
pub fn safeAtomicLoad32(
    address: innigkeit.VirtualAddress,
    out: *u32,
    target: *innigkeit.KernelVirtualAddress,
) void {
    asm volatile (
        \\lea 1f(%rip), %rax
        \\mov %rax, (%[target])
        \\
        \\mov (%[addr]), %eax
        \\mov %eax, (%[out])
        \\
        \\1:
        :
        : [target] "r" (target),
          [addr] "r" (address.value),
          [out] "r" (out),
        : .{ .rax = true, .memory = true });
}

/// Flushes the cache for the given virtual range on the current executor.
///
/// The `virtual_range` address and size must be aligned to the standard page size.
pub fn flushCache(virtual_range: innigkeit.VirtualRange) void {
    if (core.is_debug) std.debug.assert(virtual_range.pageAligned());

    var current_virtual_address = virtual_range.address;
    const terminating_virtual_address = virtual_range.after();

    while (current_virtual_address.lessThan(terminating_virtual_address)) {
        x64.instructions.invlpg(current_virtual_address);

        current_virtual_address.moveForwardPageInPlace();
    }
}
