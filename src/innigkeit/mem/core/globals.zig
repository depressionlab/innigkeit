const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

/// Whether the memory system has been initialized.
///
/// Before this is set to true other systems should not assume that heaps or address spaces are available.
///
/// Mainly used to prevent early ACPI table mappings from using the special heap.
///
/// Set to true during `init.initializeMemorySystem`.
pub var memory_system_initialized: bool = false;

/// The kernel page table.
///
/// All other page tables start as a copy of this one.
///
/// Initialized during `init.initializeMemorySystem`.
pub var kernel_page_table: architecture.paging.PageTable = undefined;

/// The kernel address space.
///
/// Used for file caches, loaning memory from userspace, etc.
///
/// Initialized during `init.initializeMemorySystem`.
pub var kernel_address_space: innigkeit.mem.AddressSpace = undefined;

/// The virtual base address that the kernel was loaded at.
///
/// Initialized during `init.determineEarlyMemoryLayout`.
pub var virtual_base_address: innigkeit.KernelVirtualAddress = undefined;

/// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
///
/// Initialized during `init.determineEarlyMemoryLayout`.
pub var kernel_virtual_offset: core.Size = undefined;

/// Provides an identity mapping between virtual and physical addresses.
///
/// Initialized during `init.determineEarlyMemoryLayout`.
pub var direct_map: innigkeit.KernelVirtualRange = undefined;

/// The layout of the memory regions of the cascade.
///
/// Initialized during `init.initializeMemorySystem`.
pub var regions: innigkeit.mem.KernelMemoryRegion.List = .{};
