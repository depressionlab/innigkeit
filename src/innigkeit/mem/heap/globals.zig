const innigkeit = @import("innigkeit");
const arena = innigkeit.mem.arena;
const core = @import("core");

pub const Arena = arena.Arena(.none);
const HeapArena = arena.Arena(.{
    .heap = heap_arena_quantum_caches,
});

/// An arena managing the heap's virtual address space.
///
/// Has no source arena, provided with a single span representing the entire heap.
///
/// Initialized during `init.initializeHeaps`.
pub var heap_address_space_arena: Arena = undefined;

/// The heap page arena, has a quantum of the standard page size.
///
/// Has a source arena of `heap_address_space_arena`. Backs imported spans with physical memory.
///
/// Initialized during `init.initializeHeaps`.
pub var heap_page_arena: Arena = undefined;

/// The heap arena.
///
/// Has a source arena of `heap_page_arena`.
///
/// Initialized during `init.initializeHeaps`.
pub var heap_arena: HeapArena = undefined;

pub var heap_page_table_mutex: innigkeit.sync.Mutex = .{};

/// An arena managing the special heap region's virtual address space.
///
/// Has no source arena, provided with a single span representing the entire range.
///
/// Initialized during `init.initializeHeaps`.
pub var special_heap_address_space_arena: innigkeit.mem.arena.Arena(.none) = undefined;

pub var special_heap_page_table_mutex: innigkeit.sync.Mutex = .{};

pub const heap_arena_quantum: usize = 16;
pub const heap_arena_quantum_caches: usize = 512 / heap_arena_quantum; // cache up to 512 bytes

pub const heap_arena_quantum_size: core.Size = .from(heap_arena_quantum, .byte);
pub const heap_arena_quantum_size_alignment = heap_arena_quantum_size.toAlignment();
