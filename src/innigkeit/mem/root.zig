const std = @import("std");

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub const AddressSpace = @import("address_space/AddressSpace.zig");
pub const cache = @import("cache/root.zig");
pub const FlushRequest = @import("core/FlushRequest.zig");
pub const heap = @import("heap/root.zig");

pub const KernelMemoryRegion = @import("core/KernelMemoryRegion.zig");
pub const MapType = @import("core/MapType.zig");
pub const PhysicalPage = @import("page/PhysicalPage.zig");
pub const arena = @import("arena/root.zig");
pub const PageFaultDetails = @import("core/PageFaultDetails.zig");
pub const VirtualRangeBatch = @import("core/VirtualRangeBatch.zig");
pub const ChangeProtectionBatch = @import("core/ChangeProtectionBatch.zig");

pub const compress = @import("compress.zig");
pub const globals = @import("core/globals.zig");
pub const init = @import("core/init.zig");

pub const MapError = error{
    AlreadyMapped,

    /// This is used to surface errors from the underlying paging implementation that are architecture specific.
    MappingNotValid,
} || PhysicalPage.Allocator.AllocateError;

pub inline fn kernelRegions() *KernelMemoryRegion.List {
    return &globals.regions;
}

pub inline fn kernelPageTable() architecture.paging.PageTable {
    return globals.kernel_page_table;
}

pub inline fn kernelAddressSpace() *AddressSpace {
    return &globals.kernel_address_space;
}

/// Maps a single page to a physical page.
///
/// **REQUIREMENTS**:
/// - `virtual_address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_address` must not already be mapped
/// - `map_type.protection` must not be `.none`
pub fn mapSinglePage(
    page_table: architecture.paging.PageTable,
    virtual_address: innigkeit.VirtualAddress,
    physical_page: PhysicalPage.Index,
    map_type: MapType,
    physical_page_allocator: PhysicalPage.Allocator,
) MapError!void {
    if (core.is_debug) {
        std.debug.assert(!map_type.protection.equal(.none));
        std.debug.assert(virtual_address.pageAligned());
    }

    try page_table.mapSinglePage(
        virtual_address,
        physical_page,
        map_type,
        physical_page_allocator,
    );
}

/// Maps a virtual range using the standard page size.
///
/// Physical pages are allocated for each page in the virtual range.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range` must not already be mapped
/// - `map_type.protection` must not be `.none`
pub fn mapRangeAndBackWithPhysicalPages(
    page_table: architecture.paging.PageTable,
    virtual_range: innigkeit.VirtualRange,
    map_type: MapType,
    flush_target: innigkeit.Context,
    top_level_decision: core.CleanupDecision,
    physical_page_allocator: PhysicalPage.Allocator,
) MapError!void {
    if (core.is_debug) {
        std.debug.assert(!map_type.protection.equal(.none));
        std.debug.assert(virtual_range.pageAligned());
    }

    var current_virtual_address = virtual_range.address;
    const terminating_virtual_address = virtual_range.after();

    errdefer {
        // Unmap all pages that have been mapped.

        var unmap_batch: VirtualRangeBatch = .{};
        unmap_batch.appendMergeIfFull(.{
            .address = virtual_range.address,
            .size = virtual_range.address.difference(current_virtual_address),
        });

        unmap(
            page_table,
            &unmap_batch,
            flush_target,
            .free,
            top_level_decision,
            physical_page_allocator,
        );
    }

    // TODO: this can be optimized by implementing `arch.paging.mapRangeAndBackWithPhysicalPages`
    //       this one is not as obviously good as the other TODO optimizations in this file as every arch will have to do
    //       the same physical page allocation and errdefer deallocation

    while (current_virtual_address.lessThan(terminating_virtual_address)) {
        const physical_page = try physical_page_allocator.allocate();
        errdefer {
            var deallocate_page_list: PhysicalPage.List = .{};
            deallocate_page_list.prepend(physical_page);
            physical_page_allocator.deallocate(deallocate_page_list);
        }

        try page_table.mapSinglePage(
            current_virtual_address,
            physical_page,
            map_type,
            physical_page_allocator,
        );

        current_virtual_address.moveForwardPageInPlace();
    }
}

/// Maps a virtual address range to a physical range using the standard page size.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `arch.paging.standard_page_size`
/// - `physical_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `physical_range.size` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be equal to `physical_range.size`
/// - `virtual_range` must not already be mapped
/// - `map_type.protection` must not be `.none`
pub fn mapRangeToPhysicalRange(
    page_table: architecture.paging.PageTable,
    virtual_range: innigkeit.VirtualRange,
    physical_range: innigkeit.PhysicalRange,
    map_type: MapType,
    flush_target: innigkeit.Context,
    top_level_decision: core.CleanupDecision,
    physical_page_allocator: PhysicalPage.Allocator,
) MapError!void {
    if (core.is_debug) {
        std.debug.assert(!map_type.protection.equal(.none));
        std.debug.assert(virtual_range.pageAligned());
        std.debug.assert(physical_range.pageAligned());
        std.debug.assert(virtual_range.size.equal(physical_range.size));
    }

    var current_virtual_address = virtual_range.address;
    const terminating_virtual_address = virtual_range.after();

    errdefer { // unmap all pages that have been mapped
        var unmap_batch: VirtualRangeBatch = .{};
        unmap_batch.appendMergeIfFull(.{
            .address = virtual_range.address,
            .size = virtual_range.address.difference(current_virtual_address),
        });

        unmap(
            page_table,
            &unmap_batch,
            flush_target,
            .keep,
            top_level_decision,
            physical_page_allocator,
        );
    }

    // TODO: this can be optimized by implementing `arch.paging.PageTable.mapRange`

    var current_physical_address = physical_range.address;

    while (current_virtual_address.lessThan(terminating_virtual_address)) {
        try page_table.mapSinglePage(
            current_virtual_address,
            .fromAddress(current_physical_address),
            map_type,
            physical_page_allocator,
        );

        current_virtual_address.moveForwardPageInPlace();
        current_physical_address.moveForwardPageInPlace();
    }
}

/// Unmaps all ranges in the given batch.
///
/// Performs TLB shootdown.
pub fn unmap(
    page_table: architecture.paging.PageTable,
    unmap_batch: *const VirtualRangeBatch,
    flush_target: innigkeit.Context,
    backing_page_decision: core.CleanupDecision,
    top_level_decision: core.CleanupDecision,
    physical_page_allocator: PhysicalPage.Allocator,
) void {
    var deallocate_page_list: PhysicalPage.List = .{};
    var flush_batch: VirtualRangeBatch = .{};

    for (unmap_batch.ranges.constSlice()) |range| {
        page_table.unmap(
            range,
            backing_page_decision,
            top_level_decision,
            &flush_batch,
            &deallocate_page_list,
        );

        if (flush_batch.full()) {
            @branchHint(.unlikely);

            var request: FlushRequest = .{
                .batch = &flush_batch,
                .flush_target = flush_target,
            };

            request.submitAndWait();

            flush_batch.clear();
        }
    }

    if (flush_batch.ranges.len != 0) {
        var request: FlushRequest = .{
            .batch = &flush_batch,
            .flush_target = flush_target,
        };

        request.submitAndWait();
    }

    physical_page_allocator.deallocate(deallocate_page_list);
}

/// Changes the protection of all the ranges in the given batch.
///
/// Only modifies the pages that are actually mapped.
///
/// Performs TLB shootdown if required.
///
/// Asserts that `new_map_type.protection` is not `.none`.
pub fn changeProtection(
    page_table: architecture.paging.PageTable,
    change_proection_batch: *const ChangeProtectionBatch,
    flush_target: innigkeit.Context,
    new_map_type: innigkeit.mem.MapType,
) void {
    if (core.is_debug) std.debug.assert(!new_map_type.protection.equal(.none));

    var flush_batch: VirtualRangeBatch = .{};

    for (change_proection_batch.ranges.constSlice()) |range| {
        page_table.changeProtection(
            range.virtual_range,
            range.previous_map_type,
            new_map_type,
            &flush_batch,
        );

        if (flush_batch.full()) {
            @branchHint(.unlikely);

            var request: FlushRequest = .{
                .batch = &flush_batch,
                .flush_target = flush_target,
            };

            request.submitAndWait();

            flush_batch.clear();
        }
    }

    if (flush_batch.ranges.len != 0) {
        var request: FlushRequest = .{
            .batch = &flush_batch,
            .flush_target = flush_target,
        };

        request.submitAndWait();
    }
}

/// Fault-tolerant memory access.
///
/// `safe.memcpy` performs a copy that, if it hits an unhandleable page fault
/// (e.g. a bad user pointer passed to a syscall), returns `error.BadAddress`
/// instead of panicking the kernel.
///
/// Fault recovery currently takes effect on x64 (whose page-fault path routes
/// here); on arm the copy works but an unhandleable fault still panics until the
/// arm data-abort path is routed to `onPageFault`.
pub const safe = struct {
    pub const MemcpyError = error{BadAddress};

    pub const ResultSlot = struct {
        /// Set to `false` by the page-fault handler if the access faulted.
        successful: bool,
        /// Address the page-fault handler resumes at on a fault.
        target: innigkeit.KernelVirtualAddress,
        /// When `true`, the page-fault handler fixes up **immediately** on any
        /// fault (before demand-paging or re-enabling interrupts) so the
        /// access is safe even with a spinlock held (used by `atomicLoadU32`).
        /// When `false`, normal demand paging is attempted first and the fixup
        /// runs only for an otherwise-unhandleable fault (used by `memcpy`).
        immediate: bool,
    };

    pub const Args = struct {
        destination: innigkeit.VirtualRange,
        source: innigkeit.VirtualRange,
    };

    /// Copy `args.source` to `args.destination`, returning `error.BadAddress` if
    /// an unhandleable page fault occurs.
    ///
    /// Caller must ensure `args.destination.size >= args.source.size`. Copy
    /// direction is unspecified, so overlapping ranges are UB.
    pub fn memcpy(args: Args) MemcpyError!void {
        std.debug.assert(args.destination.size.greaterThanOrEqual(args.source.size));

        const current_task: innigkeit.Task.Current = .get();

        const user_involved = isUserRange(args.destination) or isUserRange(args.source);
        if (user_involved) current_task.incrementEnableAccessToUserMemory();
        defer if (user_involved) current_task.decrementEnableAccessToUserMemory();

        var slot: ResultSlot = .{ .successful = true, .target = undefined, .immediate = false };

        const previous = current_task.task.safe_result_slot.swap(&slot, .monotonic);
        std.debug.assert(previous == null); // safe copies do not nest
        defer std.debug.assert(current_task.task.safe_result_slot.swap(null, .monotonic) == &slot);

        architecture.paging.safeMemcpy(args.destination, args.source, &slot.target);

        if (!slot.successful) {
            @branchHint(.cold);
            return error.BadAddress;
        }
    }

    /// Atomically load a `u32` from `address` (acquire ordering), returning
    /// `error.BadAddress` if the access faults or `address` is misaligned.
    ///
    /// Unlike `memcpy` this is **safe to call with a spinlock held**: a fault is
    /// fixed up immediately, without demand-paging or re-enabling interrupts.
    /// Used by the futex word check, where the load must be atomic (for
    /// lost-wakeup correctness) and happens under the futex bucket lock.
    /// (Fault recovery is active on x64; see the arm note above.)
    pub fn atomicLoadU32(address: innigkeit.VirtualAddress) MemcpyError!u32 {
        if (address.value % @alignOf(u32) != 0) return error.BadAddress;

        const current_task: innigkeit.Task.Current = .get();

        const user_involved = switch (address.tagged()) {
            .user => true,
            .kernel, .invalid => false,
        };
        if (user_involved) current_task.incrementEnableAccessToUserMemory();
        defer if (user_involved) current_task.decrementEnableAccessToUserMemory();

        var value: u32 = undefined;
        var slot: ResultSlot = .{ .successful = true, .target = undefined, .immediate = true };

        const previous = current_task.task.safe_result_slot.swap(&slot, .monotonic);
        std.debug.assert(previous == null);
        defer std.debug.assert(current_task.task.safe_result_slot.swap(null, .monotonic) == &slot);

        architecture.paging.safeAtomicLoad32(address, &value, &slot.target);

        if (!slot.successful) {
            @branchHint(.cold);
            return error.BadAddress;
        }
        return value;
    }

    fn isUserRange(range: innigkeit.VirtualRange) bool {
        return switch (range.tagged()) {
            .user => true,
            .kernel, .invalid => false,
        };
    }
};

/// If a `safe.memcpy` is in progress, point the faulting instruction at its
/// recovery target and mark the copy failed; returns true if it did so.
fn tryFixupSafeCopy(interrupt_frame: architecture.interrupts.InterruptFrame) bool {
    const slot = innigkeit.Task.Current.get().task.safe_result_slot.load(.monotonic) orelse return false;
    slot.successful = false;
    interrupt_frame.setInstructionPointer(slot.target.toVirtualAddress());
    return true;
}

/// Executed upon page fault.
pub fn onPageFault(
    page_fault_details: PageFaultDetails,
    interrupt_frame: architecture.interrupts.InterruptFrame,
) void {
    const current_task: innigkeit.Task.Current = .get();

    // Immediate fixup for a fault-safe atomic load (which may run under a
    // spinlock): redirect to the recovery point WITHOUT decrementing the
    // interrupt-disable count (re-enabling interrupts) or attempting demand
    // paging, so it is safe in any context. `onInterruptExit` restores the
    // interrupt-disable count saved on entry.
    if (current_task.task.safe_result_slot.load(.monotonic)) |slot| {
        if (slot.immediate) {
            @branchHint(.cold);
            slot.successful = false;
            interrupt_frame.setInstructionPointer(slot.target.toVirtualAddress());
            return;
        }
    }

    current_task.decrementInterruptDisable();

    switch (page_fault_details.faulting_context) {
        .kernel => onKernelPageFault(page_fault_details, interrupt_frame),
        .user => {
            const process: *innigkeit.user.Process = .from(current_task.task);
            process.address_space.handlePageFault(page_fault_details) catch |err| std.debug.panic(
                "user page fault failed: {t}!\n{f}",
                .{ err, page_fault_details },
            );
        },
    }
}

fn onKernelPageFault(
    page_fault_details: PageFaultDetails,
    interrupt_frame: architecture.interrupts.InterruptFrame,
) void {
    switch (page_fault_details.faulting_address.tagged()) {
        .user => {
            const process: *innigkeit.user.Process = blk: {
                const current_task: innigkeit.Task.Current = .get();

                break :blk switch (current_task.task.type) {
                    .kernel => {
                        @branchHint(.cold);
                        innigkeit.debug.interruptSourcePanic(
                            interrupt_frame,
                            "kernel page fault in user memory range\n{f}",
                            .{page_fault_details},
                        );
                        unreachable;
                    },
                    .user => .from(current_task.task),
                };
            };

            if (!page_fault_details.faulting_context.kernel.access_to_user_memory_enabled) {
                @branchHint(.cold);

                if (tryFixupSafeCopy(interrupt_frame)) return;

                innigkeit.debug.interruptSourcePanic(
                    interrupt_frame,
                    "kernel accessed user memory\n{f}",
                    .{page_fault_details},
                );
            }

            process.address_space.handlePageFault(page_fault_details) catch |err| {
                if (tryFixupSafeCopy(interrupt_frame)) return;

                innigkeit.debug.interruptSourcePanic(
                    interrupt_frame,
                    "kernel page fault in user memory failed: {t}\n{f}",
                    .{ err, page_fault_details },
                );
            };
        },
        .kernel => |address| {
            const region_type = globals.regions.containingAddress(address) orelse {
                @branchHint(.cold);

                if (tryFixupSafeCopy(interrupt_frame)) return;

                innigkeit.debug.interruptSourcePanic(
                    interrupt_frame,
                    "kernel page fault outside of any kernel region\n{f}",
                    .{page_fault_details},
                );
            };

            switch (region_type) {
                .kernel_address_space => {
                    @branchHint(.likely);
                    globals.kernel_address_space.handlePageFault(page_fault_details) catch |err| switch (err) {
                        error.OutOfMemory => std.debug.panic(
                            "no memory available to handle page fault in kernel address space!\n{f}",
                            .{page_fault_details},
                        ),
                        error.Protection, error.NotMapped => |e| {
                            if (tryFixupSafeCopy(interrupt_frame)) return;

                            innigkeit.debug.interruptSourcePanic(
                                interrupt_frame,
                                "failed to handle page fault in kernel address space: {t}!\n{f}",
                                .{ e, page_fault_details },
                            );
                        },
                    };
                },
                else => |t| {
                    @branchHint(.cold);

                    if (tryFixupSafeCopy(interrupt_frame)) return;

                    innigkeit.debug.interruptSourcePanic(
                        interrupt_frame,
                        "kernel page fault in '{t}'\n{f}",
                        .{ t, page_fault_details },
                    );
                },
            }
        },
        .invalid => {
            @branchHint(.cold);

            if (tryFixupSafeCopy(interrupt_frame)) return;

            innigkeit.debug.interruptSourcePanic(
                interrupt_frame,
                "kernel page fault with invalid address\n{f}",
                .{page_fault_details},
            );
        },
    }
}

test "safe.memcpy: unmapped source returns BadAddress instead of panicking" {
    // The fault-recovery fixup is only wired on x64 today (arm data aborts are
    // not yet routed to onPageFault), so on arm this deliberate fault would hit
    // the diagnostic panic.
    if (comptime @import("builtin").cpu.arch != .x86_64) return error.SkipZigTest;

    const address_space = kernelAddressSpace();

    // Map a page then unmap it: the address stays inside the kernel region but is
    // no longer backed, so any access faults unhandleably.
    const range = try address_space.map(.{
        .size = architecture.paging.standard_page_size,
        .protection = .{ .read = true, .write = true },
        .type = .zero_fill,
    });
    try address_space.unmap(range);

    var destination: [8]u8 = undefined;
    try std.testing.expectError(error.BadAddress, safe.memcpy(.{
        .destination = .from(.from(@intFromPtr(&destination)), .from(destination.len, .byte)),
        .source = .{ .address = range.address, .size = .from(destination.len, .byte) },
    }));
}

test "safe.atomicLoadU32: unmapped address returns BadAddress instead of panicking" {
    // Immediate-fixup fault recovery is wired on x64 only (arm data aborts are
    // not routed to onPageFault yet); skip there.
    if (comptime @import("builtin").cpu.arch != .x86_64) return error.SkipZigTest;

    const address_space = kernelAddressSpace();
    const range = try address_space.map(.{
        .size = architecture.paging.standard_page_size,
        .protection = .{ .read = true, .write = true },
        .type = .zero_fill,
    });
    try address_space.unmap(range);

    // A fault-safe atomic load from the now-unmapped page must fail cleanly,
    // not panic (this is the futex word-check DoS guard).
    try std.testing.expectError(error.BadAddress, safe.atomicLoadU32(range.address));
}
