const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

/// The buddy allocator for physical pages.
///
/// Initialized during `init.initializePhysicalMemory`.
pub var buddy: innigkeit.memory.PhysicalPage.BuddyAllocator = .{};

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
pub var pages: []innigkeit.memory.PhysicalPage = undefined;

/// Called whenever free memory drops below `pressure_threshold_pages`.
/// Invoked with interrupts enabled, no locks held. May be null.
pub var pressure_hook: ?*const fn (free_pages: u64, total_pages: u64) void = null;

/// Free-page threshold that triggers `pressure_hook`. 0 = disabled.
/// Set this to e.g. `total_pages / 8` for a 12.5% watermark.
pub var pressure_threshold_pages: u64 = 0;
