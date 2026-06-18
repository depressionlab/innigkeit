//! AArch64 VMSAv8-64 page tables: 4 KiB granule, 4 levels (L0-L3), 48-bit
//! virtual addresses in both halves.
//!
//! Translation layout (4 KiB granule, 48-bit VA):
//! ```
//!   L0 index = VA[47:39]   each entry covers 512 GiB
//!   L1 index = VA[38:30]   each entry covers   1 GiB  (block-capable)
//!   L2 index = VA[29:21]   each entry covers   2 MiB  (block-capable)
//!   L3 index = VA[20:12]   each entry covers   4 KiB  (page)
//! ```
//!
//! Descriptor encoding (low two bits):
//! ```
//!   0b00 -> invalid
//!   0b01 -> block descriptor (valid at L1/L2 only)
//!   0b11 -> table descriptor (L0/L1/L2) or page descriptor (L3)
//! ```
//!
//! The kernel programs MAIR_EL1 / TCR_EL1 itself in `loadPageTable` so the
//! attribute indices used here are well defined regardless of what the
//! bootloader left behind. See `attr` below for the MAIR layout.

const std = @import("std");

const innigkeit = @import("innigkeit");
const MapType = innigkeit.mem.MapType;
const core = @import("core");
const arm = @import("arm.zig");

/// A single level of an AArch64 4 KiB-granule page table (512 * 8 bytes).
pub const PageTable = extern struct {
    _entries: [number_of_entries]Entry.Raw align(small_page_size.value),

    pub const number_of_entries = 512;

    pub const small_page_size: core.Size = .from(4, .kib);
    pub const small_page_size_alignment = small_page_size.toAlignment();

    pub const medium_page_size: core.Size = .from(2, .mib);
    const medium_page_size_alignment = medium_page_size.toAlignment();

    pub const large_page_size: core.Size = .from(1, .gib);
    const large_page_size_alignment = large_page_size.toAlignment();

    pub const level_1_address_space_size = small_page_size;
    pub const level_2_address_space_size = medium_page_size;
    pub const level_3_address_space_size = large_page_size;

    /// One L0 entry covers 512 GiB.
    pub const level_4_address_space_size = core.Size.from(512, .gib);
    const level_4_address_space_size_alignment = level_4_address_space_size.toAlignment();

    pub const half_address_space_size: core.Size = .from(256, .tib);

    pub inline fn entries(page_table: *PageTable) []volatile Entry.Raw {
        return &page_table._entries;
    }

    pub inline fn entriesConst(page_table: *const PageTable) []const volatile Entry.Raw {
        return &page_table._entries;
    }

    pub fn sizeOfTopLevelEntry() core.Size {
        return level_4_address_space_size;
    }

    fn zero(page_table: *PageTable) void {
        @memset(page_table.entries(), .{ .value = 0 });
    }

    fn isEmpty(page_table: *const PageTable) bool {
        for (page_table.entriesConst()) |entry| {
            if (!entry.isZero()) return false;
        }
        return true;
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
        if (core.is_debug) std.debug.assert(page_table != target_page_table);
        @memcpy(target_page_table.entries(), page_table.entriesConst());
    }

    /// Maps a single 4 KiB page. Caller must ensure:
    ///  - `virtual_address` is aligned to 4 KiB
    ///  - `virtual_address` is not already mapped
    ///  - `map_type.protection` is not `.none`
    pub fn mapSinglePage(
        level0_table: *PageTable,
        virtual_address: innigkeit.VirtualAddress,
        phys_page: innigkeit.mem.PhysicalPage.Index,
        map_type: MapType,
        physical_page_allocator: innigkeit.mem.PhysicalPage.Allocator,
    ) innigkeit.mem.MapError!void {
        if (core.is_debug) std.debug.assert(virtual_address.pageAligned());

        var deallocate_page_list: innigkeit.mem.PhysicalPage.List = .{};
        errdefer physical_page_allocator.deallocate(deallocate_page_list);

        const level0_entries = level0_table.entries();
        const level0_index = l0Index(virtual_address);

        const level1_table, const created_level1_table = try ensureNextTable(
            &level0_entries[level0_index],
            physical_page_allocator,
        );
        errdefer {
            if (created_level1_table) {
                const address = level0_entries[level0_index].load().getTableAddress();
                level0_entries[level0_index].zero();
                deallocate_page_list.prepend(.fromAddress(address));
            }
        }

        const level1_entries = level1_table.entries();
        const level1_index = l1Index(virtual_address);

        const level2_table, const created_level2_table = try ensureNextTable(
            &level1_entries[level1_index],
            physical_page_allocator,
        );
        errdefer {
            if (created_level2_table) {
                const address = level1_entries[level1_index].load().getTableAddress();
                level1_entries[level1_index].zero();
                deallocate_page_list.prepend(.fromAddress(address));
            }
        }

        const level2_entries = level2_table.entries();
        const level2_index = l2Index(virtual_address);

        const level3_table, const created_level3_table = try ensureNextTable(
            &level2_entries[level2_index],
            physical_page_allocator,
        );
        errdefer {
            if (created_level3_table) {
                const address = level2_entries[level2_index].load().getTableAddress();
                level2_entries[level2_index].zero();
                deallocate_page_list.prepend(.fromAddress(address));
            }
        }

        const level3_entries = level3_table.entries();

        try setEntry(
            &level3_entries[l3Index(virtual_address)],
            phys_page.baseAddress(),
            map_type,
            .small,
        );
    }

    /// Unmaps the given virtual range.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///
    /// This function:
    ///  - only supports the standard page size for the architecture
    ///  - does not flush the TLB
    pub fn unmap(
        level0_table: *PageTable,
        virtual_range: innigkeit.VirtualRange,
        backing_page_decision: core.CleanupDecision,
        top_level_decision: core.CleanupDecision,
        flush_batch: *innigkeit.mem.VirtualRangeBatch,
        deallocate_page_list: *innigkeit.mem.PhysicalPage.List,
    ) void {
        if (core.is_debug) std.debug.assert(virtual_range.pageAligned());

        const level0_entries = level0_table.entries();

        var current_virtual_address = virtual_range.address;
        const last_virtual_address = virtual_range.last();

        const last_l0 = l0Index(last_virtual_address);
        const last_l1 = l1Index(last_virtual_address);
        const last_l2 = l2Index(last_virtual_address);
        const last_l3 = l3Index(last_virtual_address);

        var level0_index = l0Index(current_virtual_address);

        var opt_in_progress_range: ?innigkeit.VirtualRange = null;

        while (level0_index <= last_l0) : (level0_index += 1) {
            const level0_entry = level0_entries[level0_index].load();

            const level1_table = level0_entry.getNextLevel() catch |err| switch (err) {
                error.NotPresent => {
                    if (opt_in_progress_range) |in_progress_range| {
                        flush_batch.appendMergeIfFull(in_progress_range);
                        opt_in_progress_range = null;
                    }
                    current_virtual_address.moveForwardInPlace(level_4_address_space_size);
                    current_virtual_address.alignBackwardInPlace(level_4_address_space_size_alignment);
                    continue;
                },
                error.HugePage => @panic("page table entry is a block!"),
            };

            defer if (top_level_decision == .free and level1_table.isEmpty()) {
                level0_entries[level0_index].zero();
                deallocate_page_list.prepend(.fromAddress(level0_entry.getTableAddress()));
            };

            const level1_entries = level1_table.entries();

            var level1_index = l1Index(current_virtual_address);
            const last_level1_index = if (last_l0 == level0_index) last_l1 else number_of_entries - 1;

            while (level1_index <= last_level1_index) : (level1_index += 1) {
                const level1_entry = level1_entries[level1_index].load();

                const level2_table = level1_entry.getNextLevel() catch |err| switch (err) {
                    error.NotPresent => {
                        if (opt_in_progress_range) |in_progress_range| {
                            flush_batch.appendMergeIfFull(in_progress_range);
                            opt_in_progress_range = null;
                        }
                        current_virtual_address.moveForwardInPlace(large_page_size);
                        current_virtual_address.alignBackwardInPlace(large_page_size_alignment);
                        continue;
                    },
                    error.HugePage => @panic("page table entry is a block!"),
                };

                defer if (level2_table.isEmpty()) {
                    level1_entries[level1_index].zero();
                    deallocate_page_list.prepend(.fromAddress(level1_entry.getTableAddress()));
                };

                const level2_entries = level2_table.entries();

                var level2_index = l2Index(current_virtual_address);
                const last_level2_index = if (last_l1 == level1_index and last_l0 == level0_index)
                    last_l2
                else
                    number_of_entries - 1;

                while (level2_index <= last_level2_index) : (level2_index += 1) {
                    const level2_entry = level2_entries[level2_index].load();

                    const level3_table = level2_entry.getNextLevel() catch |err| switch (err) {
                        error.NotPresent => {
                            if (opt_in_progress_range) |in_progress_range| {
                                flush_batch.appendMergeIfFull(in_progress_range);
                                opt_in_progress_range = null;
                            }
                            current_virtual_address.moveForwardInPlace(medium_page_size);
                            current_virtual_address.alignBackwardInPlace(medium_page_size_alignment);
                            continue;
                        },
                        error.HugePage => @panic("page table entry is a block!"),
                    };

                    defer if (level3_table.isEmpty()) {
                        level2_entries[level2_index].zero();
                        deallocate_page_list.prepend(.fromAddress(level2_entry.getTableAddress()));
                    };

                    const level3_entries = level3_table.entries();

                    var level3_index = l3Index(current_virtual_address);
                    const last_level3_index = if (last_l2 == level2_index and
                        last_l1 == level1_index and last_l0 == level0_index)
                        last_l3
                    else
                        number_of_entries - 1;

                    while (level3_index <= last_level3_index) : (level3_index += 1) {
                        defer current_virtual_address.moveForwardPageInPlace();

                        const level3_entry = level3_entries[level3_index].load();

                        if (!level3_entry.valid()) {
                            if (opt_in_progress_range) |in_progress_range| {
                                flush_batch.appendMergeIfFull(in_progress_range);
                                opt_in_progress_range = null;
                            }
                            continue;
                        }

                        level3_entries[level3_index].zero();

                        if (backing_page_decision == .free) {
                            deallocate_page_list.prepend(.fromAddress(level3_entry.getPageAddress()));
                        }

                        if (opt_in_progress_range) |*in_progress_range| {
                            in_progress_range.size.addInPlace(small_page_size);
                        } else {
                            opt_in_progress_range = .from(current_virtual_address, small_page_size);
                        }
                    }
                }
            }
        }

        if (opt_in_progress_range) |in_progress_range| {
            flush_batch.appendMergeIfFull(in_progress_range);
        }
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
        level0_table: *PageTable,
        virtual_range: innigkeit.VirtualRange,
        previous_map_type: MapType,
        new_map_type: MapType,
        flush_batch: *innigkeit.mem.VirtualRangeBatch,
    ) void {
        if (core.is_debug) std.debug.assert(virtual_range.pageAligned());

        const level0_entries = level0_table.entries();

        const need_to_flush = needToFlush(previous_map_type, new_map_type);

        var current_virtual_address = virtual_range.address;
        const last_virtual_address = virtual_range.last();

        const last_l0 = l0Index(last_virtual_address);
        const last_l1 = l1Index(last_virtual_address);
        const last_l2 = l2Index(last_virtual_address);
        const last_l3 = l3Index(last_virtual_address);

        var level0_index = l0Index(current_virtual_address);

        // if `need_to_flush` is false then this will never be non-null
        var opt_in_progress_range: ?innigkeit.VirtualRange = null;

        while (level0_index <= last_l0) : (level0_index += 1) {
            const level0_entry = level0_entries[level0_index].load();

            const level1_table = level0_entry.getNextLevel() catch |err| switch (err) {
                error.NotPresent => {
                    if (opt_in_progress_range) |in_progress_range| {
                        flush_batch.appendMergeIfFull(in_progress_range);
                        opt_in_progress_range = null;
                    }
                    current_virtual_address.moveForwardInPlace(level_4_address_space_size);
                    current_virtual_address.alignBackwardInPlace(level_4_address_space_size_alignment);
                    continue;
                },
                error.HugePage => @panic("page table entry is a block!"),
            };

            const level1_entries = level1_table.entries();

            var level1_index = l1Index(current_virtual_address);
            const last_level1_index = if (last_l0 == level0_index) last_l1 else number_of_entries - 1;

            while (level1_index <= last_level1_index) : (level1_index += 1) {
                const level1_entry = level1_entries[level1_index].load();

                const level2_table = level1_entry.getNextLevel() catch |err| switch (err) {
                    error.NotPresent => {
                        if (opt_in_progress_range) |in_progress_range| {
                            flush_batch.appendMergeIfFull(in_progress_range);
                            opt_in_progress_range = null;
                        }
                        current_virtual_address.moveForwardInPlace(large_page_size);
                        current_virtual_address.alignBackwardInPlace(large_page_size_alignment);
                        continue;
                    },
                    error.HugePage => @panic("page table entry is a block!"),
                };

                const level2_entries = level2_table.entries();

                var level2_index = l2Index(current_virtual_address);
                const last_level2_index = if (last_l1 == level1_index and last_l0 == level0_index)
                    last_l2
                else
                    number_of_entries - 1;

                while (level2_index <= last_level2_index) : (level2_index += 1) {
                    const level2_entry = level2_entries[level2_index].load();

                    const level3_table = level2_entry.getNextLevel() catch |err| switch (err) {
                        error.NotPresent => {
                            if (opt_in_progress_range) |in_progress_range| {
                                flush_batch.appendMergeIfFull(in_progress_range);
                                opt_in_progress_range = null;
                            }
                            current_virtual_address.moveForwardInPlace(medium_page_size);
                            current_virtual_address.alignBackwardInPlace(medium_page_size_alignment);
                            continue;
                        },
                        error.HugePage => @panic("page table entry is a block!"),
                    };

                    const level3_entries = level3_table.entries();

                    var level3_index = l3Index(current_virtual_address);
                    const last_level3_index = if (last_l2 == level2_index and
                        last_l1 == level1_index and last_l0 == level0_index)
                        last_l3
                    else
                        number_of_entries - 1;

                    while (level3_index <= last_level3_index) : (level3_index += 1) {
                        defer current_virtual_address.moveForwardPageInPlace();

                        var level3_entry = level3_entries[level3_index].load();

                        if (!level3_entry.valid()) {
                            if (opt_in_progress_range) |in_progress_range| {
                                flush_batch.appendMergeIfFull(in_progress_range);
                                opt_in_progress_range = null;
                            }
                            continue;
                        }

                        level3_entry.applyMapType(new_map_type, .small);
                        level3_entries[level3_index].store(level3_entry);

                        if (opt_in_progress_range) |*in_progress_range| {
                            in_progress_range.size.addInPlace(small_page_size);
                        } else if (need_to_flush) {
                            opt_in_progress_range = .from(current_virtual_address, small_page_size);
                        }
                    }
                }
            }
        }

        if (opt_in_progress_range) |in_progress_range| {
            flush_batch.appendMergeIfFull(in_progress_range);
        }
    }

    /// Returns true if the TLB needs to be flushed when changing from `previous_map_type` to `new_map_type`.
    fn needToFlush(previous_map_type: MapType, new_map_type: MapType) bool {
        if (previous_map_type.type != new_map_type.type) return true;
        if (previous_map_type.cache != new_map_type.cache) return true;
        if (previous_map_type.protection.execute != new_map_type.protection.execute) return true;
        if (previous_map_type.protection.write != new_map_type.protection.write) return true;
        return false;
    }

    /// Sets the given entry's address and map type.
    ///
    /// Caller must ensure:
    ///  - the entry is not present
    ///  - the `map_type.protection` is not `.none`
    fn setEntry(
        raw_entry: *volatile Entry.Raw,
        physical_address: innigkeit.PhysicalAddress,
        map_type: MapType,
        page_type: PageType,
    ) error{AlreadyMapped}!void {
        var entry = raw_entry.load();

        if (entry.valid()) return error.AlreadyMapped;

        entry.zero();

        // L3 pages use descriptor type 0b11; L1/L2 blocks use 0b01.
        switch (page_type) {
            .small => entry.setPageDescriptor(physical_address),
            .medium, .large => entry.setBlockDescriptor(physical_address),
        }

        entry.applyMapType(map_type, page_type);

        raw_entry.store(entry);
    }

    /// A single page-table descriptor. Helpers operate on the raw u64.
    const Entry = struct {
        value: u64,

        /// Descriptor low bits.
        const TYPE_MASK: u64 = 0b11;
        const TYPE_INVALID: u64 = 0b00;
        const TYPE_BLOCK: u64 = 0b01;
        const TYPE_TABLE_OR_PAGE: u64 = 0b11;

        /// Output address occupies bits [47:12]; lower 12 are flags, upper are
        /// attributes. All our tables/pages are 4 KiB aligned.
        const ADDRESS_MASK: u64 = 0x0000_ffff_ffff_f000;

        // Lower attributes (block/page descriptors).
        const ATTR_INDX_SHIFT: u6 = 2; // bits [4:2] MAIR index
        const NS: u64 = 1 << 5; // non-secure
        const AP_SHIFT: u6 = 6; // bits [7:6]
        const SH_SHIFT: u6 = 8; // bits [9:8]
        const AF: u64 = 1 << 10; // access flag
        const NG: u64 = 1 << 11; // not-global

        // Upper attributes.
        const PXN: u64 = 1 << 53; // privileged execute never
        const UXN: u64 = 1 << 54; // unprivileged execute never (also XN at EL1)

        // AP[2:1] field values (AP[0] is res; the architecture names AP as a
        // 2-bit field at [7:6]).
        const AP_RW_EL1: u64 = 0b00; // EL1 RW, EL0 none
        const AP_RW_ALL: u64 = 0b01; // EL1 RW, EL0 RW
        const AP_RO_EL1: u64 = 0b10; // EL1 RO, EL0 none
        const AP_RO_ALL: u64 = 0b11; // EL1 RO, EL0 RO

        // SH[1:0]: shareability.
        const SH_NON: u64 = 0b00;
        const SH_OUTER: u64 = 0b10;
        const SH_INNER: u64 = 0b11;

        const Raw = extern struct {
            value: u64,

            fn zero(raw: *volatile Raw) void {
                raw.value = 0;
            }

            fn isZero(raw: *const volatile Raw) bool {
                return raw.value == 0;
            }

            fn load(raw: *const volatile Raw) Entry {
                return .{ .value = raw.value };
            }

            fn store(raw: *volatile Raw, entry: Entry) void {
                raw.value = entry.value;
            }

            comptime {
                core.testing.expectSize(Raw, .of(u64));
            }
        };

        fn zero(entry: *Entry) void {
            entry.value = 0;
        }

        fn valid(entry: Entry) bool {
            return (entry.value & 1) != 0;
        }

        fn isTable(entry: Entry) bool {
            // At L0-L2 a 0b11 descriptor is a table; at L3 it is a page. The
            // page-table walker distinguishes by level, but our generic helpers
            // only need: valid + 0b11 => table for intermediate levels, and we
            // never call getNextLevel on an L3 entry.
            return (entry.value & TYPE_MASK) == TYPE_TABLE_OR_PAGE;
        }

        fn isBlock(entry: Entry) bool {
            return (entry.value & TYPE_MASK) == TYPE_BLOCK;
        }

        /// Physical address of the next-level table (table descriptor).
        fn getTableAddress(entry: Entry) innigkeit.PhysicalAddress {
            return .{ .value = entry.value & ADDRESS_MASK };
        }

        /// Physical address mapped by an L3 page descriptor.
        fn getPageAddress(entry: Entry) innigkeit.PhysicalAddress {
            return .{ .value = entry.value & ADDRESS_MASK };
        }

        fn setTableDescriptor(entry: *Entry, address: innigkeit.PhysicalAddress) void {
            if (core.is_debug) std.debug.assert(address.pageAligned());
            entry.value = (address.value & ADDRESS_MASK) | TYPE_TABLE_OR_PAGE;
        }

        fn setPageDescriptor(entry: *Entry, address: innigkeit.PhysicalAddress) void {
            if (core.is_debug) std.debug.assert(address.pageAligned());
            entry.value = (entry.value & ~(ADDRESS_MASK | TYPE_MASK)) |
                (address.value & ADDRESS_MASK) | TYPE_TABLE_OR_PAGE;
        }

        fn setBlockDescriptor(entry: *Entry, address: innigkeit.PhysicalAddress) void {
            entry.value = (entry.value & ~(ADDRESS_MASK | TYPE_MASK)) |
                (address.value & ADDRESS_MASK) | TYPE_BLOCK;
        }

        /// Gets the next page table level.
        ///
        /// Returns an error if the entry is not present, or is a block.
        fn getNextLevel(entry: Entry) error{ NotPresent, HugePage }!*PageTable {
            if (!entry.valid()) return error.NotPresent;
            if (entry.isBlock()) return error.HugePage;
            return entry.getTableAddress().toDirectMap().toPtr(*PageTable);
        }

        /// Applies the given map type's attributes to a leaf (block/page) entry.
        ///
        /// Caller must ensure `map_type.protection` is not `.none`.
        fn applyMapType(
            entry: *Entry,
            map_type: MapType,
            page_type: PageType,
        ) void {
            _ = page_type;

            // Clear all attribute bits, preserve the output address + type.
            entry.value &= (ADDRESS_MASK | TYPE_MASK);

            // Access flag: set so the CPU does not take an access-flag fault.
            entry.value |= AF;

            // Memory attributes via MAIR index + shareability.
            const attr_index: u64, const sh: u64 = switch (map_type.cache) {
                .write_back => .{ attr.normal_wb_index, SH_INNER },
                // write_combining maps to Normal Non-cacheable (closest WMA).
                .write_combining => .{ attr.normal_nc_index, SH_INNER },
                .uncached => .{ attr.device_ngnre_index, SH_NON },
            };
            entry.value |= attr_index << ATTR_INDX_SHIFT;
            entry.value |= sh << SH_SHIFT;

            // Access permissions + global vs non-global.
            const ap: u64, const non_global: bool = switch (map_type.type) {
                .kernel => .{
                    if (map_type.protection.write) AP_RW_EL1 else AP_RO_EL1,
                    false,
                },
                .user => .{
                    if (map_type.protection.write) AP_RW_ALL else AP_RO_ALL,
                    true,
                },
            };
            entry.value |= ap << AP_SHIFT;
            if (non_global) entry.value |= NG;

            // Execute permissions.
            //   Kernel mapping: UXN always set (EL0 must never execute kernel
            //   memory); PXN reflects the executable flag.
            //   User mapping: PXN always set (EL1 must never execute user
            //   memory, mirroring SMEP); UXN reflects the executable flag.
            switch (map_type.type) {
                .kernel => {
                    entry.value |= UXN;
                    if (!map_type.protection.execute) entry.value |= PXN;
                },
                .user => {
                    entry.value |= PXN;
                    if (!map_type.protection.execute) entry.value |= UXN;
                },
            }
        }
    };

    pub const init = struct {
        /// This function fills in the top level of the page table for the given range.
        ///
        /// The range is expected to have both size and alignment of `sizeOfTopLevelEntry()`.
        ///
        /// This function:
        ///  - does not flush the TLB
        ///  - does not rollback on error
        pub fn fillTopLevel(
            page_table: *PageTable,
            range: innigkeit.VirtualRange,
            physical_page_allocator: innigkeit.mem.PhysicalPage.Allocator,
        ) !void {
            const size_of_top_level_entry = sizeOfTopLevelEntry();
            arm.semihost.write("[arm] fillTopLevel addr=");
            arm.semihost.writeHex(range.address.value);
            arm.semihost.write(" size=");
            arm.semihost.writeHex(range.size.value);
            arm.semihost.write(" toplvl=");
            arm.semihost.writeHex(size_of_top_level_entry.value);
            arm.semihost.write("\n");
            if (core.is_debug) {
                std.debug.assert(range.size.equal(size_of_top_level_entry));
                std.debug.assert(range.address.aligned(size_of_top_level_entry.toAlignment()));
            }

            const level0_entries = page_table.entries();
            const raw_entry = &level0_entries[l0Index(range.address)];

            const entry = raw_entry.load();
            if (entry.valid()) return error.AlreadyMapped;

            _ = try ensureNextTable(raw_entry, physical_page_allocator);
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
            level0_table: *PageTable,
            virtual_range: innigkeit.VirtualRange,
            physical_range: innigkeit.PhysicalRange,
            map_type: MapType,
            physical_page_allocator: innigkeit.mem.PhysicalPage.Allocator,
        ) !void {
            if (core.is_debug) {
                std.debug.assert(virtual_range.pageAligned());
                std.debug.assert(physical_range.pageAligned());
                std.debug.assert(virtual_range.size.equal(physical_range.size));
            }

            arm.semihost.write("[arm] mapRange v=");
            arm.semihost.writeHex(virtual_range.address.value);
            arm.semihost.write(" p=");
            arm.semihost.writeHex(physical_range.address.value);
            arm.semihost.write(" sz=");
            arm.semihost.writeHex(virtual_range.size.value);
            arm.semihost.write("\n");

            init_log.verbose(
                "mapToPhysicalRangeAllPageSizes - virtual_range: {f} - physical_range: {f} - map_type: {f}",
                .{ virtual_range, physical_range, map_type },
            );

            const level0_entries = level0_table.entries();

            var current_virtual_address = virtual_range.address;
            const last_virtual_address = virtual_range.last();
            var current_physical_address = physical_range.address;
            var size_remaining = virtual_range.size;

            const last_l0 = l0Index(last_virtual_address);
            const last_l1 = l1Index(last_virtual_address);
            const last_l2 = l2Index(last_virtual_address);

            var level0_index = l0Index(current_virtual_address);

            while (level0_index <= last_l0) : (level0_index += 1) {
                const level1_table, _ = try ensureNextTable(
                    &level0_entries[level0_index],
                    physical_page_allocator,
                );

                const level1_entries = level1_table.entries();

                var level1_index = l1Index(current_virtual_address);
                const last_level1_index = if (last_l0 == level0_index) last_l1 else number_of_entries - 1;

                while (level1_index <= last_level1_index) : (level1_index += 1) {
                    if (size_remaining.greaterThanOrEqual(large_page_size) and
                        current_virtual_address.aligned(large_page_size_alignment) and
                        current_physical_address.aligned(large_page_size_alignment))
                    {
                        // 1 GiB block at L1.
                        try setEntry(
                            &level1_entries[level1_index],
                            current_physical_address,
                            map_type,
                            .large,
                        );

                        current_virtual_address.moveForwardInPlace(large_page_size);
                        current_physical_address.moveForwardInPlace(large_page_size);
                        size_remaining.subtractInPlace(large_page_size);
                        continue;
                    }

                    const level2_table, _ = try ensureNextTable(
                        &level1_entries[level1_index],
                        physical_page_allocator,
                    );

                    const level2_entries = level2_table.entries();

                    var level2_index = l2Index(current_virtual_address);
                    const last_level2_index = if (last_l1 == level1_index and last_l0 == level0_index)
                        last_l2
                    else
                        number_of_entries - 1;

                    while (level2_index <= last_level2_index) : (level2_index += 1) {
                        if (size_remaining.greaterThanOrEqual(medium_page_size) and
                            current_virtual_address.aligned(medium_page_size_alignment) and
                            current_physical_address.aligned(medium_page_size_alignment))
                        {
                            // 2 MiB block at L2.
                            try setEntry(
                                &level2_entries[level2_index],
                                current_physical_address,
                                map_type,
                                .medium,
                            );

                            current_virtual_address.moveForwardInPlace(medium_page_size);
                            current_physical_address.moveForwardInPlace(medium_page_size);
                            size_remaining.subtractInPlace(medium_page_size);
                            continue;
                        }

                        const level3_table, _ = try ensureNextTable(
                            &level2_entries[level2_index],
                            physical_page_allocator,
                        );

                        const level3_entries = level3_table.entries();

                        var level3_index = l3Index(current_virtual_address);
                        const last_level3_index = if (last_l2 == level2_index and
                            last_l1 == level1_index and last_l0 == level0_index)
                            l3Index(last_virtual_address)
                        else
                            number_of_entries - 1;

                        while (level3_index <= last_level3_index) : (level3_index += 1) {
                            try setEntry(
                                &level3_entries[level3_index],
                                current_physical_address,
                                map_type,
                                .small,
                            );

                            current_virtual_address.moveForwardPageInPlace();
                            current_physical_address.moveForwardPageInPlace();
                            size_remaining.subtractInPlace(small_page_size);
                        }
                    }
                }
            }
        }

        const init_log = innigkeit.debug.log.scoped(.paging_init);
    };

    /// See `loadPageTableImpl`.
    pub const loadPageTable = loadPageTableImpl;
    /// See `flushCacheImpl`.
    pub const flushCache = flushCacheImpl;
    /// See `loadUserPageTableImpl`.
    pub const loadUserPageTable = loadUserPageTableImpl;
    /// See `flushAllTlbImpl`.
    pub const flushAllTlb = flushAllTlbImpl;

    comptime {
        core.testing.expectSize(PageTable, small_page_size);
    }
};

/// Ensures that the next table is present in the page table.
///
/// Returns the next table and whether it had to be created by this function or not.
fn ensureNextTable(
    raw_entry: *volatile PageTable.Entry.Raw,
    physical_page_allocator: innigkeit.mem.PhysicalPage.Allocator,
) !struct { *PageTable, bool } {
    var created_table = false;

    const next_level_physical_address = blk: {
        var entry = raw_entry.load();

        if (entry.valid()) {
            if (entry.isBlock()) return error.MappingNotValid;
            break :blk entry.getTableAddress();
        }
        if (core.is_debug) std.debug.assert(entry.value == 0);
        created_table = true;

        const physical_page = try physical_page_allocator.allocate();
        errdefer comptime unreachable;

        const physical_address = physical_page.baseAddress();
        physical_address.toDirectMap().toPtr(*PageTable).zero();

        entry.setTableDescriptor(physical_address);
        raw_entry.store(entry);

        break :blk physical_address;
    };

    return .{
        next_level_physical_address.toDirectMap().toPtr(*PageTable),
        created_table,
    };
}

const PageType = enum { small, medium, large };

inline fn l3Index(address: innigkeit.VirtualAddress) usize {
    return @as(u9, @truncate(address.value >> level_3_shift));
}

inline fn l2Index(address: innigkeit.VirtualAddress) usize {
    return @as(u9, @truncate(address.value >> level_2_shift));
}

inline fn l1Index(address: innigkeit.VirtualAddress) usize {
    return @as(u9, @truncate(address.value >> level_1_shift));
}

inline fn l0Index(address: innigkeit.VirtualAddress) usize {
    return @as(u9, @truncate(address.value >> level_0_shift));
}

const level_3_shift = 12; // 4 KiB
const level_2_shift = 21; // 2 MiB
const level_1_shift = 30; // 1 GiB
const level_0_shift = 39; // 512 GiB

/// MAIR_EL1 attribute layout used by this kernel.
///
/// MAIR_EL1 holds eight 8-bit Attr fields; a leaf descriptor's AttrIndx[2:0]
/// selects one. We program the indices below in `loadPageTable`.
pub const attr = struct {
    /// Index 0: Normal memory, Inner+Outer Write-Back Non-transient,
    /// Read+Write-Allocate. Encoding 0xFF.
    pub const normal_wb_index: u64 = 0;
    pub const normal_wb_value: u64 = 0xFF;

    /// Index 1: Device-nGnRE (the MMIO memory type). Encoding 0x04.
    pub const device_ngnre_index: u64 = 1;
    pub const device_ngnre_value: u64 = 0x04;

    /// Index 2: Normal Non-cacheable. Encoding 0x44.
    pub const normal_nc_index: u64 = 2;
    pub const normal_nc_value: u64 = 0x44;

    /// Assembled MAIR_EL1 value.
    pub const mair: u64 =
        (normal_wb_value << @intCast(normal_wb_index * 8)) |
        (device_ngnre_value << @intCast(device_ngnre_index * 8)) |
        (normal_nc_value << @intCast(normal_nc_index * 8));
};

/// TCR_EL1 fields for a 48-bit VA, 4 KiB granule configuration shared by both
/// translation regimes.
const tcr = struct {
    /// T0SZ/T1SZ = 64 - 48 = 16 (48-bit virtual addresses).
    const region_size_offset: u64 = 16;

    const T0SZ_SHIFT: u6 = 0;
    const T1SZ_SHIFT: u6 = 16;

    // Inner/Outer Write-Back Write-Allocate cacheable walks, Inner Shareable.
    const IRGN_WBWA: u64 = 0b01;
    const ORGN_WBWA: u64 = 0b01;
    const SH_INNER: u64 = 0b11;

    const IRGN0_SHIFT: u6 = 8;
    const ORGN0_SHIFT: u6 = 10;
    const SH0_SHIFT: u6 = 12;
    const TG0_SHIFT: u6 = 14; // 0b00 = 4 KiB

    const IRGN1_SHIFT: u6 = 24;
    const ORGN1_SHIFT: u6 = 26;
    const SH1_SHIFT: u6 = 28;
    const TG1_SHIFT: u6 = 30; // 0b10 = 4 KiB for TTBR1 (different encoding!)

    /// IPS (intermediate physical address size) at bits [34:32]; 0b101 = 48-bit.
    const IPS_SHIFT: u6 = 32;
    const IPS_48BIT: u64 = 0b101;

    /// Assembled TCR_EL1 value.
    const value: u64 =
        (region_size_offset << T0SZ_SHIFT) |
        (IRGN_WBWA << IRGN0_SHIFT) |
        (ORGN_WBWA << ORGN0_SHIFT) |
        (SH_INNER << SH0_SHIFT) |
        (0b00 << TG0_SHIFT) | // TTBR0 4 KiB granule
        (region_size_offset << T1SZ_SHIFT) |
        (IRGN_WBWA << IRGN1_SHIFT) |
        (ORGN_WBWA << ORGN1_SHIFT) |
        (SH_INNER << SH1_SHIFT) |
        (0b10 << TG1_SHIFT) | // TTBR1 4 KiB granule
        (IPS_48BIT << IPS_SHIFT);
};

/// SCTLR_EL1.M (bit 0): MMU enable.
const SCTLR_EL1_M: u64 = 1 << 0;
/// SCTLR_EL1.C (bit 2): data cache enable.
const SCTLR_EL1_C: u64 = 1 << 2;
/// SCTLR_EL1.I (bit 12): instruction cache enable.
const SCTLR_EL1_I: u64 = 1 << 12;

/// Load the kernel page table: program MAIR/TCR, install the table as the
/// TTBR1 (high-half) root, invalidate the TLB and re-enable the MMU.
///
/// This runs once on the bootstrap executor during `initializeMemorySystem`,
/// replacing the bootloader's page tables with the kernel's own. The kernel
/// is executing from high-half addresses that the generic builder has already
/// mapped into this table, so the switch is safe.
pub fn loadPageTableImpl(physical_page: innigkeit.mem.PhysicalPage.Index) void {
    arm.semihost.write("[arm] loadPageTable enter\n");
    const root = physical_page.baseAddress().value;

    // Map the device-MMIO hole (PL011 UART + GIC) as Device-nGnRE into the
    // direct map BEFORE switching to this table. Limine's HHDM does not cover
    // the low device-MMIO region (it sits below RAM and is absent from the
    // memory map), so without this every MMIO access faults with a translation
    // fault. The bootstrap allocator is still live here (this runs as the last
    // step of `buildAndLoadKernelPageTable`).
    mapDeviceMmio(physical_page);
    arm.semihost.write("[arm] loadPageTable: device mmio mapped\n");

    // Program the memory attribute and translation control registers before
    // pointing TTBR1 at the new table.
    arm.registers.MAIR_EL1.write(attr.mair);
    arm.registers.TCR_EL1.write(tcr.value);
    arm.instructions.isb();

    // The kernel root governs the high half (TTBR1). The low half (TTBR0)
    // has no kernel mappings; leave whatever the bootloader set until the
    // first user address space is loaded. Installing our own table here and
    // flushing guarantees the high-half kernel mappings come from us.
    arm.registers.TTBR1_EL1.write(root);
    arm.instructions.isb();

    // Invalidate all stage-1 EL1 TLB entries (inner shareable) so stale
    // bootloader translations cannot be used.
    flushAllTlbImpl();

    // Ensure the MMU + caches are enabled (the bootloader hands off with the
    // MMU on, but make the kernel's expectation explicit).
    var sctlr = arm.registers.SCTLR_EL1.read();
    sctlr |= SCTLR_EL1_M | SCTLR_EL1_C | SCTLR_EL1_I;
    arm.registers.SCTLR_EL1.write(sctlr);
    arm.instructions.isb();
    arm.semihost.write("[arm] loadPageTable: TTBR1 switched, MMU on\n");
}

/// Physical MMIO regions on the QEMU `virt` machine that the kernel needs
/// before the device-tree/ACPI driven mappings exist. Mapped Device-nGnRE
/// into the direct map so `toDirectMap` access works.
const device_mmio_regions = [_]struct { base: u64, size: core.Size }{
    // GIC distributor + CPU interface (GICv2): 0x0800_0000..0x0802_0000.
    .{ .base = 0x0800_0000, .size = .from(128, .kib) },
    // PL011 UART: one 4 KiB page at 0x0900_0000.
    .{ .base = 0x0900_0000, .size = .from(4, .kib) },
};

/// Map the early device-MMIO regions Device-nGnRE into the direct map of the
/// kernel page table rooted at `physical_page`.
fn mapDeviceMmio(physical_page: innigkeit.mem.PhysicalPage.Index) void {
    const root_table = physical_page.baseAddress().toDirectMap().toPtr(*PageTable);
    const direct_map_base = innigkeit.mem.globals.direct_map.address;

    for (device_mmio_regions) |region| {
        const phys: innigkeit.PhysicalAddress = .from(region.base);
        const virtual_range: innigkeit.VirtualRange = .from(
            direct_map_base.moveForward(.from(region.base, .byte)).toVirtualAddress(),
            region.size,
        );
        const physical_range: innigkeit.PhysicalRange = .from(phys, region.size);

        PageTable.init.mapToPhysicalRangeAllPageSizes(
            root_table,
            virtual_range,
            physical_range,
            .{
                .type = .kernel,
                .protection = .{ .read = true, .write = true },
                .cache = .uncached, // -> Device-nGnRE
            },
            innigkeit.mem.PhysicalPage.init.bootstrap_allocator,
        ) catch |err| std.debug.panic("failed to map device MMIO {x}: {t}", .{ region.base, err });
    }
}

/// Install a user (low-half) address space root into TTBR0_EL1.
pub fn loadUserPageTableImpl(physical_page: innigkeit.mem.PhysicalPage.Index) void {
    arm.registers.TTBR0_EL1.write(physical_page.baseAddress().value);
    arm.instructions.isb();
    flushAllTlbImpl();
}

/// Invalidate the entire stage-1 EL1 TLB, inner shareable.
pub fn flushAllTlbImpl() void {
    asm volatile (
        \\ dsb ishst
        \\ tlbi vmalle1is
        \\ dsb ish
        \\ isb
        ::: .{ .memory = true });
}

/// Flushes (invalidates the TLB for) the given virtual range on the current
/// executor. The architecture interface names this `flushCache`; on AArch64
/// the relevant operation is per-page TLB invalidation.
///
/// The `virtual_range` address and size must be aligned to the standard page
/// size.
pub fn flushCacheImpl(virtual_range: innigkeit.VirtualRange) void {
    if (core.is_debug) std.debug.assert(virtual_range.pageAligned());

    var current_virtual_address = virtual_range.address;
    const terminating_virtual_address = virtual_range.after();

    asm volatile ("dsb ishst" ::: .{ .memory = true });

    while (current_virtual_address.lessThan(terminating_virtual_address)) {
        // TLBI VAE1IS takes the VA shifted right by 12 in bits [43:0].
        const operand = current_virtual_address.value >> 12;
        asm volatile ("tlbi vae1is, %[op]"
            :
            : [op] "r" (operand),
            : .{ .memory = true });
        current_virtual_address.moveForwardPageInPlace();
    }

    asm volatile (
        \\ dsb ish
        \\ isb
        ::: .{ .memory = true });
}
