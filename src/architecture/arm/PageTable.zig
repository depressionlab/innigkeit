const innigkeit = @import("innigkeit");
const core = @import("core");

/// AArch64 page table stub (4KiB granule, 4 levels, 512 entries per table).
pub const PageTable = extern struct {
    _entries: [number_of_entries]u64 align(small_page_size.value),

    pub const number_of_entries = 512;

    pub const small_page_size: core.Size = .from(4, .kib);
    pub const small_page_size_alignment = small_page_size.toAlignment();

    pub const medium_page_size: core.Size = .from(2, .mib);
    pub const large_page_size: core.Size = .from(1, .gib);

    pub const level_4_address_space_size = core.Size.from(512, .gib);
    pub const half_address_space_size: core.Size = .from(256, .tib);

    pub fn sizeOfTopLevelEntry() core.Size {
        return level_4_address_space_size;
    }

    fn zero(page_table: *PageTable) void {
        @memset(&page_table._entries, 0);
    }

    /// Create a page table in the given physical page.
    ///
    /// **REQUIREMENTS**:
    /// - The provided physical page must be accessible in the direct map.
    pub fn create(physical_page: innigkeit.mem.PhysicalPage.Index) *PageTable {
        const page_table = physical_page.baseAddress().toDirectMap().toPtr(*PageTable);
        page_table.zero();
        return page_table;
    }

    /// Copies the top level of `page_table` into `target_page_table`.
    pub fn copyTopLevelIntoPageTable(
        page_table: *PageTable,
        target_page_table: *PageTable,
    ) void {
        @memcpy(&target_page_table._entries, &page_table._entries);
    }
};
