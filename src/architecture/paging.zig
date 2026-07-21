const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

/// The standard page size for the architecture.
pub const standard_page_size: core.Size = architecture.current_decls.paging.standard_page_size;
pub const standard_page_size_alignment: std.mem.Alignment = standard_page_size.toAlignment();

/// The largest page size supported by the architecture.
pub const largest_page_size: core.Size = architecture.current_decls.paging.largest_page_size;
pub const largest_page_size_alignment: std.mem.Alignment = largest_page_size.toAlignment();

/// The range of the address space that is considered kernel memory.
///
/// Usually the higher half of the address space.
///
/// This must not include either the zero, undefined nor max addresses.
pub const kernel_memory_range: innigkeit.VirtualRange = architecture.current_decls.paging.kernel_memory_range;

comptime {
    std.debug.assert(!kernel_memory_range.containsAddress(.zero));
    std.debug.assert(!kernel_memory_range.containsAddress(.undefined_address));
    std.debug.assert(!kernel_memory_range.containsAddress(.max));
}

pub const PageTable = struct {
    physical_page: innigkeit.memory.PhysicalPage.Index,
    arch_specific: *architecture.current_decls.paging.PageTable,

    /// Create a page table in the given physical page.
    ///
    /// **REQUIREMENTS**:
    /// - The provided physical page must be accessible in the direct map.
    pub fn create(physical_page: innigkeit.memory.PhysicalPage.Index) callconv(core.inline_in_non_debug) PageTable {
        return .{
            .physical_page = physical_page,
            .arch_specific = architecture.getFunction(
                architecture.current_functions.paging,
                "createPageTable",
            )(physical_page),
        };
    }

    /// Install [`page_table`] as the kernel root.
    ///
    /// Only the kernel's own table may be passed here. See [`loadUser`] for
    /// switching to a process's address space.
    pub fn load(page_table: PageTable) callconv(core.inline_in_non_debug) void {
        architecture.getFunction(
            architecture.current_functions.paging,
            "loadPageTable",
        )(page_table.physical_page);
    }

    /// Install [`page_table`] as the current task's user address-space root.
    ///
    /// This function is used by a task that wants to switch to or within userspace.
    /// See `Functions.zig`: `loadUserPageTable` for more information.
    /// Copies the top level of `page_table` into `target_page_table`.
    pub fn loadUser(page_table: PageTable) callconv(core.inline_in_non_debug) void {
        architecture.getFunction(
            architecture.current_functions.paging,
            "loadUserPageTable",
        )(page_table.physical_page);
    }

    pub fn copyTopLevelInto(
        page_table: PageTable,
        target_page_table: PageTable,
    ) callconv(core.inline_in_non_debug) void {
        architecture.getFunction(
            architecture.current_functions.paging,
            "copyTopLevelIntoPageTable",
        )(page_table.arch_specific, target_page_table.arch_specific);
    }

    /// Maps `virtual_address` to `physical_page` with mapping type `map_type`.
    ///
    /// Caller must ensure:
    ///  - the virtual address is aligned to the standard page size
    ///  - the virtual address is not already mapped
    ///  - `map_type.protection` is not `.none`
    ///
    /// This function:
    ///  - only supports the standard page size for the architecture
    ///  - does not flush the TLB
    pub fn mapSinglePage(
        page_table: PageTable,
        virtual_address: innigkeit.VirtualAddress,
        physical_page: innigkeit.memory.PhysicalPage.Index,
        map_type: innigkeit.memory.MapType,
        physical_page_allocator: innigkeit.memory.PhysicalPage.Allocator,
    ) callconv(core.inline_in_non_debug) innigkeit.memory.MapError!void {
        return architecture.getFunction(
            architecture.current_functions.paging,
            "mapSinglePage",
        )(
            page_table.arch_specific,
            virtual_address,
            physical_page,
            map_type,
            physical_page_allocator,
        );
    }

    /// Unmaps the given virtual range.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///
    /// This function:
    ///  - does not flush the TLB
    pub fn unmap(
        page_table: PageTable,
        virtual_range: innigkeit.VirtualRange,
        backing_page_decision: core.CleanupDecision,
        top_level_decision: core.CleanupDecision,
        flush_batch: *innigkeit.memory.VirtualRangeBatch,
        deallocate_page_list: *innigkeit.memory.PhysicalPage.List,
    ) callconv(core.inline_in_non_debug) void {
        architecture.getFunction(
            architecture.current_functions.paging,
            "unmap",
        )(
            page_table.arch_specific,
            virtual_range,
            backing_page_decision,
            top_level_decision,
            flush_batch,
            deallocate_page_list,
        );
    }

    /// Changes the protection of the given virtual range.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///  - `new_map_type` protection is not `.none`
    ///
    /// This function:
    ///  - does not flush the TLB
    pub fn changeProtection(
        page_table: PageTable,
        virtual_range: innigkeit.VirtualRange,
        previous_map_type: innigkeit.memory.MapType,
        new_map_type: innigkeit.memory.MapType,
        flush_batch: *innigkeit.memory.VirtualRangeBatch,
    ) callconv(core.inline_in_non_debug) void {
        architecture.getFunction(
            architecture.current_functions.paging,
            "changeProtection",
        )(page_table.arch_specific, virtual_range, previous_map_type, new_map_type, flush_batch);
    }
};

/// Flushes the cache for the given virtual range on the current executor.
///
/// Caller must ensure:
///   - the `virtual_range` address and size must be aligned to the standard page size
pub fn flushCache(virtual_range: innigkeit.VirtualRange) callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.paging,
        "flushCache",
    )(virtual_range);
}

/// Enable the kernel to access user memory.
///
/// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
/// memory.
pub fn enableAccessToUserMemory() callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.paging,
        "enableAccessToUserMemory",
    )();
}

/// Disable the kernel from accessing user memory.
///
/// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
/// memory.
pub fn disableAccessToUserMemory() callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.paging,
        "disableAccessToUserMemory",
    )();
}

/// Copy `source.size` bytes from `source` to `destination`, recording in
/// `target.*` the address the page-fault handler resumes at on an unhandleable
/// fault.
pub fn safeMemcpy(
    destination: innigkeit.VirtualRange,
    source: innigkeit.VirtualRange,
    target: *innigkeit.KernelVirtualAddress,
) callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.paging,
        "safeMemcpy",
    )(destination, source, target);
}

/// Atomically load a `u32` from `address` (acquire) into `out`, recording the
/// fault-recovery address in `target.*`.
pub fn safeAtomicLoad32(
    address: innigkeit.VirtualAddress,
    out: *u32,
    target: *innigkeit.KernelVirtualAddress,
) callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.paging,
        "safeAtomicLoad32",
    )(address, out, target);
}

pub const init = struct {
    /// The total size of the virtual address space that one entry in the top level of the page table covers.
    pub fn sizeOfTopLevelEntry() callconv(core.inline_in_non_debug) core.Size {
        return architecture.getFunction(
            architecture.current_functions.paging.init,
            "sizeOfTopLevelEntry",
        )();
    }

    /// This function fills in the top level of the page table for the given range.
    ///
    /// The range is expected to have both size and alignment of `sizeOfTopLevelEntry()`.
    ///
    /// This function:
    ///  - does not flush the TLB
    ///  - does not rollback on error
    pub fn fillTopLevel(
        page_table: PageTable,
        range: innigkeit.VirtualRange,
        physical_page_allocator: innigkeit.memory.PhysicalPage.Allocator,
    ) callconv(core.inline_in_non_debug) anyerror!void {
        return architecture.getFunction(
            architecture.current_functions.paging.init,
            "fillTopLevel",
        )(page_table.arch_specific, range, physical_page_allocator);
    }

    /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///  - the physical range address and size are aligned to the standard page size
    ///  - the virtual range size is equal to the physical range size
    ///  - the virtual range is not already mapped
    ///  - `map_type.protection` is not `.none`
    ///
    /// This function:
    ///  - uses all page sizes available to the architecture
    ///  - does not flush the TLB
    ///  - does not rollback on error
    pub fn mapToPhysicalRangeAllPageSizes(
        page_table: PageTable,
        virtual_range: innigkeit.VirtualRange,
        physical_range: innigkeit.PhysicalRange,
        map_type: innigkeit.memory.MapType,
        physical_page_allocator: innigkeit.memory.PhysicalPage.Allocator,
    ) callconv(core.inline_in_non_debug) anyerror!void {
        if (core.is_debug) std.debug.assert(!map_type.protection.equal(.none));
        return architecture.getFunction(
            architecture.current_functions.paging.init,
            "mapToPhysicalRangeAllPageSizes",
        )(page_table.arch_specific, virtual_range, physical_range, map_type, physical_page_allocator);
    }
};
