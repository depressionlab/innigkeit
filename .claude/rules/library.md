---
paths:
  - "library/innigkeit/**"
---

# `library/innigkeit/` invariants

Drafted during Phase 3 Stage 16 (`docs/phase3-review-plan.md`), same
convention `.claude/rules/pci.md`/`filesystem.md`/`acpi.md`/`drivers.md`
established for their subsystems.

## Uncalled library functions can hide a real compile error indefinitely under Zig's lazy analysis

`futex.zig`'s `wait`/`waitTimeout`/`wake` all had `innigkeit.innigkeit.Error.Syscall`
as their return type — a self-reference through the library module's own
name, invalid because a relatively-imported file (`@import("innigkeit")`
from inside a file reached via `@import("futex.zig")` from the module root)
resolves to the module's own top-level declarations directly, not a nested
`.innigkeit` field (see `build/Library.zig`'s `createModule()`:
`module.addImport(description.name, module)` — the module imports itself
under its own name once, at the root, not recursively at every file).

This compiled cleanly for an unknown period because **nothing in this
codebase calls these three functions** (the kernel has its own, unrelated
`sync/futex.zig`) — Zig only type-checks a function's signature and body
when something forces analysis of it (a call site, an `_ = &fn` reference,
`std.testing.refAllDecls`, etc.), and none of those existed for this file.
`root.zig`'s `refAllDecls(@This())` walks re-exported *declarations*, not
transitively into every function body of every file behind them, so it
did not catch this either.

**The fix, and the pattern to apply elsewhere in this directory**: a
`comptime { _ = &fn1; _ = &fn2; ... }` block at the bottom of any file whose
public functions have no in-tree caller, forcing signature resolution so a
future regression fails the build immediately instead of lying dormant.
Before adding one, verify the suspected error is real by temporarily adding
the forcing block and running `zig build check` — do not assume a
compile error exists (or doesn't) from inspection alone when the code path
is provably unanalyzed; this file's bug was confirmed exactly this way.

If a file in this directory is ever wired up to a real caller (making the
forcing block redundant), it's fine to remove the block at that point —
its only job is covering the gap between "written" and "first real caller."
