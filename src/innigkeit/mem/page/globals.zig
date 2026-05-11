const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

/// The list of free pages.
///
/// Initialized during `init.initializePhysicalMemory`.
pub var free_page_list: innigkeit.mem.PhysicalPage.List.Atomic = .{};

/// The free physical memory.
///
/// Updates to this value are eventually consistent.
///
/// Initialized during `init.initializePhysicalMemory`.
pub var free_memory: std.atomic.Value(u64) = undefined;

/// The total physical memory.
///
/// Does not change during the lifetime of the system.
///
/// Initialized during `init.initializePhysicalMemory`.
pub var total_memory: core.Size = undefined;

/// The reserved physical memory.
///
/// Does not change during the lifetime of the system.
///
/// Initialized during `init.initializePhysicalMemory`.
pub var reserved_memory: core.Size = undefined;

/// The reclaimable physical memory.
///
/// Will be reduced when the memory is reclaimed. // TODO: reclaim memory
///
/// Initialized during `init.initializePhysicalMemory`.
pub var reclaimable_memory: core.Size = undefined;

/// Framebuffer physical memory.
///
/// Does not change during the lifetime of the system.
///
/// Initialized during `init.initializePhysicalMemory`.
pub var framebuffer_memory: core.Size = undefined;

/// The unavailable physical memory.
///
/// Does not change during the lifetime of the system.
///
/// Initialized during `init.initializePhysicalMemory`.
pub var unavailable_memory: core.Size = undefined;

/// A `PhysicalPage` for each physical page.
///
/// Initialized during `init.initializePhysicalMemory`.
pub var pages: []innigkeit.mem.PhysicalPage = undefined;
