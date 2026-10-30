---
paths:
  - "src/innigkeit/memory/cache/**"
  - "src/innigkeit/memory/address_space/**"
  - "src/innigkeit/user/Process.zig"
  - "src/innigkeit/user/Thread.zig"
  - "src/innigkeit/user/FdTable.zig"
  - "src/innigkeit/task/**"
  - "src/architecture/**/PerThread.zig"
---

# Slab reuse (a recurring class of security bug)

A `Cache(T, constructor)` runs the constructor **once per slot**, when the slab is built, never per allocation. `cache.allocate()` hands back whatever the previous occupant left. Field defaults in the struct declaration are applied only by the constructor's `item.* = .{...}`, so they are **not** reapplied on reuse either. This class has bitten the tree repeatedly (stale entitlements, live file handles, a set `terminating` flag, a scrambled capability free list: cross-process leaks and privilege carry-over).

## Rules for any slab-cached type

1. Every field must be handled by the allocating function (`create`/`init`), either one `item.* = .{ ... }` rewrite or an explicit reset. "The default value covers it" is wrong.
2. State that must end its life idle (locks, queued flags, maps, notify refs) is reset by the destroy/cleanup path **and asserted idle in `create()` under `core.is_debug`**.
3. A field that is genuinely reuse-safe gets a `/// slab-reuse-ok: <reason>` doc comment. A whole type can carry it on its `const T = @This();` line.
4. A new field means re-reading `create()`. Add the reset in the same change.
5. Resources hanging off the object (heap pointers, caps, refs) are released in cleanup, never inherited.

## What enforces this

- `zig build lint` rule `slab_reuse_field` (`lint/rules/slab_reuse_field.zig`) warns on a field of a file's root type that the allocating function, a `*construct*` function or an inline `Cache(...)` constructor never mentions. It proves a decision was made, not that the reset is correct: read the reset.
- Debug builds poison freed items of constructor-less caches with `0xAA` (`Cache.poison`), so a stale read fails loudly.
- Review checklist for diffs touching these files: `REVIEW.md`.
