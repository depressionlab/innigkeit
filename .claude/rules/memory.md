---
paths:
  - "src/innigkeit/memory/**"
---

# Memory subsystem invariants

`memory/address_space/` is modeled on Cranor's UVM design (BSD/OpenBSD `uvm`):
`Entry` = `vm_map_entry`, `AddressSpace` = `vmspace`, `FaultInfo` = `uvm_faultinfo`
+ `uvm_faultctx`, `AnonMap`/`AnonPage` = amap/anon, `Object` = uvm_object.
Function names correspond directly to `uvm_fault.c` (`uvmfault_faultcheck`,
`uvm_fault_lower`, `uvm_fault_upper`, `uvmfault_promote`, `uvmfault_amapcopy`,
`uvmfault_unlockall`).

## Lock hierarchy (confirmed, Phase 2 Stage 4a)

`AddressSpace` has two top-level locks plus per-object locks:

- **`entries_lock`** (RwLock) — protects the `entries` `ArrayList(*Entry)`,
  and (as of the page-table lock gap fix below) is also the lock that
  serializes any page-table mutation for a range against a concurrent
  `unmap()`/`changeProtection()` on that same range.
- **`page_table_lock`** (Mutex) — nests *inside* `entries_lock` wherever
  both are held (see below); on its own it protects `mapSinglePage()`
  calls that population code makes directly, outside `unmap()`/
  `changeProtection()`'s own paths (which don't take it at all).
- Per-`Object`/per-`AnonMap` **`.lock`** (RwLock-like) — owned by the object,
  not the address space.

**Confirmed order when more than one is held**: `entries_lock` (outermost)
→ `page_table_lock` / `Object.lock` / `AnonMap.lock` (inner, mutually
exclusive with each other in current usage). The `entries_lock` →
`page_table_lock` nesting was already established by `FaultInfo`'s
demand-paging fault path (takes `page_table_lock` while `entries_lock` is
held, `FaultInfo.zig` lines ~301/~426) before the page-table lock gap fix
extended the same nesting to `vmem_map`/`framebuffer_map`. The
`entries_lock` → `Object.lock`/`AnonMap.lock` nesting is seen in
`AddressSpace.map()` (takes `Object.lock.writeLock()` to bump refcount
while `entries_lock.writeLock()` is held), `AddressSpace.performUnmap()`
(same, plus `AnonMap.lock`), and `Entry.merge()`/`Entry.split()` (refcount
inc/dec under the owning object's own lock — callers already hold
whatever protects the entries list). `FaultInfo.unlockAll()` releases in
the matching reverse order: object lock, then anon-map lock, then always
`entries_lock` last.

`AddressSpace.zig`'s lifecycle functions (`retarget`,
`reinitializeAndUnmapAll`, `deinit`) debug-assert
`!page_table_lock.isLocked()` before taking `entries_lock` — this remains
true (these functions require the address space to be entirely idle, not
mid-mapping) and does not conflict with the nesting above, since those
functions never take `page_table_lock` themselves either.

## Page-table lock gap — FIXED

Originally found (Stage 4a) as a documented-not-fixed gap; fixed in a
follow-up pass once the project owner asked for it.

The page table used to be mutated by two disjoint code paths sharing no
common lock:

- **`AddressSpace.unmap()`** and **`AddressSpace.changeProtection()`**
  mutate the page table directly (`innigkeit.memory.unmap()` /
  `innigkeit.memory.changeProtection()` in `memory/root.zig`, neither of
  which takes any lock itself) while holding only `entries_lock.writeLock()`.
  `page_table_lock` is asserted **unlocked** during these calls.
- **`vmem_map`/`framebuffer_map`** (`user/handlers/{vmem,framebuffer}.zig`)
  populated the page table via `mapSinglePage()` while holding only
  `page_table_lock`, taken *after* `AddressSpace.map()` had already released
  `entries_lock`.

Since a process can have multiple threads (`spawn_thread`) scheduled
concurrently on different executors (SMP), this was reachable: thread A
calls `vmem_map`, which inserts a new `Entry` under `entries_lock` and then
released it; before or while A subsequently took `page_table_lock` to run
`mapSinglePage` on that range, thread B (a sibling thread in the same
process) could call `unmap`/`changeProtection` targeting an overlapping
range, take `entries_lock.writeLock()` (now free), see the entry A just
inserted, and mutate the same page-table structure via
`innigkeit.memory.unmap()`/`changeProtection()` — with no lock serializing A
and B against each other.

**The fix**: `MapOptions` gained a `keep_entries_locked: bool` field. When
`true`, `map()` returns with `entries_lock` still held (write) instead of
releasing it, paired with a new `unlockEntriesAfterMap()` the caller must
call exactly once when done. `vmem_map`, `framebufferMap`, and
`framebufferMapGpu` now pass `keep_entries_locked = true` and hold
`entries_lock` across their `page_table_lock`-guarded `mapSinglePage()`
loop, releasing `page_table_lock` then `entries_lock` (in that order —
inner lock first) before returning or falling through to `unmap()`'s own
cleanup on a population failure (calling `unmap()` while still holding
`entries_lock` would self-deadlock, since `unmap()` takes it itself).

This closes the gap by extending the *already-established*
`entries_lock` (outer) → `page_table_lock` (inner) nesting that
`FaultInfo`'s demand-paging fault path already used (`FaultInfo.zig` lines
~301, ~426 take `page_table_lock` while `entries_lock` is held) to these
two handler call sites, rather than inventing a new lock order — so no
new deadlock ordering was introduced. Verified: `zig build verify
-Darm=true`, x64 139/139 and arm 99/99 (unchanged pass count from before
this fix; no dedicated concurrency stress test was added since exercising
the specific race deterministically would need a new multi-threaded
harness in the spirit of `testing/smp.test.zig` — flagged as a
recommended follow-up, not done here).

## Object-backed fault path is still unimplemented

`FaultInfo.faultObjectOrZeroFill()`'s object-backed branch is an
unconditional `@panic("NOT IMPLEMENTED")` (`if (true) { @panic(...) } else
.need_io`). Confirmed still true as of Stage 4a (not just assumed from an old
comment): `promote()`'s dependency on this path being stubbed out is still
valid. If the object-backed path is ever implemented, revisit `promote()`'s
handling and this note.

## Fault-isolation kill path is not worsened by AddressSpace locking

`memory/root.zig`'s `onPageFault()` → `AddressSpace.handlePageFault()` →
(on unrecoverable fault) `process.terminateCallingThread(139)` only kills
the faulting thread, not siblings — an already-known, already-documented
gap (see `Process.terminateCallingThread`'s own TODO about needing
IPI-based sibling force-termination). Confirmed by tracing every error/
restart return path in `FaultInfo.zig` (the Protection-violation branch,
`faultLookup`'s not-found branch, every OOM/Restart branch in
`faultObjectOrZeroFill`/`faultUpper`): every one releases `entries_lock`
and any held `Object`/`AnonMap` lock before returning. No memory-subsystem
lock is ever left held across a fault-triggered thread termination, so this
existing gap is not made worse (a lock left held here would deadlock any
sibling thread that needed it).

## Refcounting (every manual inc/dec pair, enumerated Stage 4b)

`Object`/`AnonMap`/`AnonPage` refcounts are always incremented/decremented
under the owning object's own `.lock` (never bare). Every site, confirmed
balanced:

- **`Entry.merge()`** — direct `object.reference_count -= 1` /
  `anonymous_map.reference_count -= 1` (bypasses the assert-wrapped
  `decrementReferenceCount` helper, but takes the same lock). Asserts
  `>= 2` first, so this never triggers destruction inline — correct, since
  a merge only ever collapses two entries that were both already
  referencing the same object/amap into one, so at least one reference
  always survives the merge.
- **`Entry.split()`** — direct `anonymous_map.reference_count += 1` /
  `object.reference_count += 1` under the same locks, when one entry
  becomes two independent references to the same object/amap.
- **`AddressSpace.map()`** — `object.incrementReferenceCount()` when a
  fresh `Entry` attaches to an existing `Object`.
- **`AddressSpace.performUnmap()`** — for each removed entry:
  `anonymous_map.decrementReferenceCount()` and
  `object.decrementReferenceCount()`, releasing that entry's holds.
- **`AnonMap.copy()`** (`amap_copy`) — the sole-owner and no-existing-map
  paths take no inc/dec (a freshly-`create()`d `AnonMap` starts owned at
  refcount 1). The shared-copy path: `anon_page.incrementReferenceCount()`
  per copied page (new_map now also holds a reference to that physical
  page); on an `ensureChunk` OOM mid-copy, the just-incremented page is
  explicitly decremented back down, and `new_map.decrementReferenceCount()`
  unwinds every *previously* successfully-copied page via `new_map`'s own
  `destroy()` (below) — the partial-failure path is a correct, traced
  undo, not a leak. At the end, `old_map.decrementReferenceCount()`
  releases the entry's own prior hold on the old map.
- **`AnonMap.destroy()`** (`amap_wipeout`, only reachable at refcount 0) —
  `page.decrementReferenceCount()` for every populated page slot, releasing
  this now-dead map's hold on each.
- **`FaultInfo.faultUpper()`**'s CoW path — `anonymous_page.
  decrementReferenceCount()` on the old page immediately before calling
  `Reference.add(..., .replace)`; the new page starts owned at the default
  refcount of 1 from `AnonPage.create()`, so no explicit increment is
  needed for it.
- **`AnonMap.Reference.add()`**'s `.replace` branch documents (does not
  perform) that the caller must have already decremented the old page's
  refcount before calling it — verified true at the one call site
  (`faultUpper`, above).
- **`Object.decrementReferenceCount()`**'s refcount-reaches-zero branch is
  an explicit `@panic` (`@branchHint(.cold)`) — self-documented dead code,
  since no `Object` can currently be created while the object-backed fault
  path above is stubbed out. Consistent with that finding, not a separate
  gap.

No unbalanced pair found across `Entry.zig`, `AddressSpace.zig`,
`AnonMap.zig`, `AnonPage.zig`, `FaultInfo.zig`. `Object.zig` and
`chunk_map.zig` are otherwise simple and clean — `chunk_map.zig` is a bare
sparse-array helper with no refcounting of its own.

## `memory/arena/`, `memory/cache/`, `memory/heap/`, `memory/page/` (Stage 5)

`arena/Arena.zig` implements a Bonwick vmem-style boundary-tag resource
arena (spans, freelists by power-of-two size class, quantum caching).
`cache/RawCache.zig` implements a Bonwick slab allocator on top of it.
`heap/` composes three arenas (`heap_address_space_arena` →
`heap_page_arena` → `heap_arena`) into the general-purpose kernel
`std.mem.Allocator`. `page/BuddyAllocator.zig` is the physical-page buddy
allocator (well-tested, has its own `test` blocks). `compress.zig` is a
complete, tested, **currently-unwired** raw-LZ4 block compressor +
`CompressPool` for a future page-compression/swap feature — nothing in the
kernel constructs a `CompressPool` today, so treat it as scaffolding, not
a live path.

### `Arena.deinit()`'s quantum-cache cleanup used the wrong tag names — fixed

`Arena(quantum_caching).deinit()`'s cleanup switch read:
```zig
switch (quantum_caching) {
    .no => {},
    .yes => innigkeit.memory.heap.allocator.free(self.quantum_caches.allocation),
    .heap => innigkeit.memory.phys.allocator.deallocate(self.quantum_caches.allocation),
}
```
`QuantumCaching`'s actual tags are `.none`/`.normal`/`.heap` (see its
definition at the bottom of `Arena.zig`) — `.no`/`.yes` don't exist, and
`innigkeit.memory.phys` doesn't exist anywhere in the codebase (the real
namespace is `innigkeit.memory.PhysicalPage`). This compiled cleanly
because **no code anywhere calls `Arena(...).deinit()`** — Zig only
type-checks a generic function's body when it's instantiated *and
referenced*, so this broken switch was invisible to `check`/`build_all`/
`verify`. Fixed to use the real tag names and namespace. Still unverified
by the build (still uncalled) — if any future caller adds a `deinit()`
call, watch for it to surface then, or add a test that constructs and
tears down an `Arena(.{.normal = n})`/`Arena(.{.heap = n})` to close this
blind spot.

### `AllocatorImplementation.free()` cannot recover the true allocation base for over-aligned allocations (Found, documented rather than fixed)

For `alignment > heap_arena_quantum` (16), `alloc()` over-allocates
(`len + alignment - 1`) from the arena and returns
`alignForward(arena_base, alignment)` — a pointer that may sit anywhere up
to `alignment - 1` bytes after the arena's actual allocation base. Nothing
records that true base anywhere. `free()` tries to reconstruct it purely
from `(pointer, len, alignment)`:
```zig
unaligned_range.address.moveBackward(.one).alignBackward(alignment)
```
This is mathematically wrong whenever the true arena base isn't itself a
multiple of `alignment` (the common case — the arena only guarantees
16-byte quantum alignment, not `alignment`-byte alignment) — and it is
*also* wrong in the "lucky" case where the true base already happens to be
`alignment`-aligned, since the `-1` unconditionally rounds down to the
**previous** multiple of `alignment`, one full `alignment` below the real
base. There is no way to recover an arbitrary arena-chosen base from
`(pointer, len, alignment)` alone without a stored header — the reverse
mapping is underdetermined by construction, not just an off-by-one in this
one formula.

Consequence: `heap_arena.deallocate()`'s exact-address hash-table lookup
(`removeFromAllocationTable`) will not find the tag at the wrong
reconstructed address, panicking `"no allocation at '{}' found!"` — or, if
some other allocation happens to sit at that wrong address, silently
freeing/corrupting an unrelated live allocation instead.

**Confirmed reachable, not just theoretical**: `acpi/uacpi_kernel_api.zig`
heap-allocates `innigkeit.sync.Mutex` and `innigkeit.sync.TicketSpinLock`
via `heap.allocator.create(...)` (lines 391, 584) — both types carry a
`_: void align(std.atomic.cache_line)` field (64-byte alignment on x64,
per `docs/DESIGN.md`'s false-sharing-defense convention), so `alignment = 64 >
16` unconditionally. Both are later torn down via
`heap.allocator.destroy(...)` (lines 400, 595), which calls this exact
broken `free()` path. The current 138/138 x64 test baseline does not
exercise uACPI's mutex/spinlock teardown paths, so this hasn't fired
during any test run to date — it is a live landmine in the uACPI
integration, not yet observed.

Not fixed inline: correctly fixing this requires storing the true arena
base (and length) in a header immediately before the aligned pointer —
exactly the pattern `heap/c.zig`'s `mallocWithNonSizedFree`/`nonSizedFree`
already uses for the same underlying problem (recovering an allocation's
true extent from just a pointer). That's a real, if small, redesign of
`AllocatorImplementation.alloc`/`free`'s over-aligned branch — the single
most heavily-depended-on allocator in the kernel — with **zero existing
test coverage of the over-aligned path to validate a fix against** (no
test in the entire tree allocates/frees a heap object with
alignment > 16). Recommend: add a round-trip test for an over-aligned
heap alloc/free *before* landing the fix, then apply the header-based fix
mirroring `heap/c.zig`'s existing precedent. Needs project-owner sign-off
per this project's delivery model for design-level changes to
long-stable, widely-depended-on code.
