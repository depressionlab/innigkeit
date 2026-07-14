---
paths:
  - "library/core/**"
---

# `library/core/` invariants

Drafted during Phase 3 Stage 19 (`docs/phase3-review-plan.md`, Tier 4), same
convention `.claude/rules/library.md` established for `library/innigkeit/`.

## Generic/comptime code here hides bugs until instantiated — same class as `library/innigkeit/futex.zig`, found three times in one stage

`library/innigkeit/futex.zig`'s bug (an uncalled function's type error
invisible to `zig build check` because nothing forced its analysis) is not
a one-off — this exact pattern recurred three times in `library/core/`
alone, because so much of this directory is generic (`comptime T: type`)
or otherwise-unreferenced code that Zig only analyzes once something
actually instantiates it with concrete types:

- **`root.zig`'s `readIntPartial()`** — correct for its one real caller
  (`hash.zig`'s `microhash`, always `.little`) but wrong for `.big`: the
  real bytes were always left-aligned in the zero-padded buffer regardless
  of `endian`, which only produces the intended "zero-extend the low-order
  bytes" semantics for `.little`. For `.big`, the missing high-order bytes
  need to be at the *start* of the buffer, not the end, or the real value
  ends up shifted into the high-order position. Confirmed empirically with
  a standalone `zig run` before fixing (0x0102 vs the buggy 0x01020000 for
  `input=[0x01,0x02]` read as `.big` into a `u32`). Fixed to branch on
  `endian`; added a regression test since the existing test only ever
  exercised the native (little, on every arch this project targets) case.
- **`containers/TypeErasedCall.zig`'s `usizeFromArg()`** — the signed-enum
  branch did `@bitCast(@intFromEnum(arg))` straight from the enum's
  `tag_type` (e.g. `i8`) to `usize` (64 bits) — a same-size-only `@bitCast`
  across a width mismatch, a **compile error** for any signed-tag-type enum
  ever passed through `TypeErasedCall`/`prepare()`. Invisible because no
  current caller does that (this generic function is only analyzed for the
  concrete argument types it's actually instantiated with). The sibling
  `.int` branch already had the correct pattern
  (`@bitCast(@as(isize, arg))` — widen to `isize` first, *then* bitcast) but
  it wasn't applied to `.@"enum"`. Confirmed the compile error with a
  standalone repro before fixing; fixed to match the `.int` branch's
  pattern; added a test that actually calls `TypeErasedCall.prepare`/
  `.call()` with a signed-tag-type enum argument, forcing this path to be
  analyzed on every future build instead of staying dormant.
- **`queue.zig`** — `const CopyPtrAttrs = @import("util");`, where `"util"`
  is not a module name registered anywhere in the build graph (confirmed:
  no `addImport("util", ...)` exists in the repo). A genuine compile error,
  invisible because the file exports no `pub` declarations and nothing
  references this top-level `const`, so nothing ever forced it to resolve.
  Unlike the two bugs above, this file provided no real functionality at
  all (a stray, never-implemented fragment — `core.queue` was re-exported
  from `root.zig` but never used anywhere) — deleted the file and its
  re-export rather than fixing the import, since there was nothing worth
  keeping.

**The lesson, restated for this directory specifically**: when reviewing
`library/core/` (or any comptime-generic utility code), do not trust
`zig build check`'s clean exit as proof a function is correct or even
compiles — check whether it has ever actually been instantiated/called
with the argument shape you're worried about. If it hasn't, force it: write
a minimal call site (a test, or a temporary `comptime { _ = &fn; }` block
to verify a suspicion before committing to a fix) rather than reasoning
from the type signature alone.

## `containers/BoundedArray.zig` is a vendored copy, not this repo's own code

Explicitly documented in its own doc comment: "Copy of
`std.BoundedArrayAligned` after its removal in
[ziglang/zig#24699](https://github.com/ziglang/zig/pull/24699)." Treated
like `ElfFile.zig` (`.claude/rules` — Stage 18) and uACPI (Stage 10b/10c):
inherited-and-already-scrutinized upstream code, not a fresh target for
this repo's own bug hunt, unless a change here specifically diverges from
the original `std` behavior.

## `containers/RedBlackTree.zig`'s correctness rests on its own `verify()` + fuzz test, not a full manual audit

At 1,356 lines this is the largest, most intricate file in the directory:
a from-scratch, parent-pointer-compressed (side/color/isolated packed into
the low bits alongside a truncated 61-bit parent pointer, asserting 8-byte
node alignment) red-black tree with the standard textbook 6-case
insert/delete rebalancing structure. Reviewed at the structural level
(packed-pointer trick is internally consistent, rebalancing cases match
the standard algorithm shape) rather than via an exhaustive manual proof of
every rotation case, because the file already carries its own
self-verification (`verify()`/`verifyRecurse()`: checks BST ordering,
parent-pointer consistency, side tags, red-node-has-black-children, and
equal black-height across every root-to-leaf path) plus a `test "fuzz"`
block using Zig 0.16's built-in fuzzing. If a bug is ever suspected here,
lean on running the fuzz test longer rather than re-deriving the six cases
by hand.
