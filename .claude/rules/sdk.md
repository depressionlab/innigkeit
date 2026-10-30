---
paths:
  - "sdk/**"
---

# `sdk/` invariants

Drafted during Phase 3 Stage 24 (`docs/phase3-review-plan.md`, Tier 4,
final stage).

## The SDK deliberately duplicates two things from the monorepo — keep them in sync by hand

`sdk/` is a self-contained Zig package (`sdk/build.zig.zon`'s `.paths` list
is just `build.zig`, `build.zig.zon`, `codesign` — no access to the
monorepo's internal `build/*.zig` files) so that an out-of-tree app can
depend on `innigkeit_sdk` without vendoring the whole kernel build graph.
Two things this forces to be duplicated rather than shared:

1. **`sdk/build.zig`'s `resolveTarget()` vs. `build/Bundle.zig`'s
   `Architecture.kernelTarget()`** — the same three freestanding
   cross-compilation target queries (x64/arm/riscv), same `cpu_model`,
   same `cpu_features_sub`/`cpu_features_add` lists, copy-pasted rather
   than shared because `sdk/` can't import `build/Bundle.zig`. Confirmed
   in sync as of Stage 24 (diffed line-by-line). Nothing in the build
   graph enforces this staying true — if `build/Bundle.zig`'s target
   construction changes (a new CPU feature added/removed, a different
   `cpu_model`), `sdk/build.zig` needs the identical change made by hand,
   or out-of-tree apps built via the SDK will target a subtly different
   CPU baseline than the kernel itself was built for.
2. **`sdk/codesign/main.zig` vs. `tools/codesign/main.zig`** — the SDK
   bundles its own copy of the codesign tool's source so an out-of-tree
   app can sign against a private key without depending on the monorepo's
   `tools/` directory. This one *did* drift once (a missing
   `std.process.exit(0)` call after the "Signed..." print) — found and
   fixed earlier in this session's Tier 4 pass, outside the Stage 17/24
   file lists proper. **Re-diff this pair whenever either file changes.**

Both are the same underlying risk: **there is no test that catches drift
between an `sdk/` file and its monorepo counterpart.** A future change to
`build/Bundle.zig` or `tools/codesign/main.zig` needs a manual check
against `sdk/`'s copy — this rules file exists so that check isn't
forgotten again.

## `createApp()`'s dependency resolution deliberately reaches through the SDK's own dependency graph, not the caller's

`sdk.builder.dependency("innigkeit", .{})` inside `createApp()` (called
from an *external* app's `build.zig`) resolves `innigkeit` as declared in
**the SDK's own** `build.zig.zon` (`.innigkeit = .{ .path = ".." }` for
local development, replaced with a git+URL for publishing) — not
whatever the calling app's `build.zig.zon` might separately declare. This
is intentional and correct: it's how `library/innigkeit/{root,prelude}.zig`
get located relative to the monorepo regardless of the external app's own
dependency graph shape. Don't "simplify" this to `b.dependency(...)`
(the *caller's* dependency graph) — that would break unless the calling
app happened to also declare an identically-named `innigkeit` dependency,
which isn't guaranteed by the SDK's contract.

## `createApp()` disables UBSan on its modules

`sdk/build.zig`'s `createApp()` sets `sanitize_c = .off` on both the app and prelude modules. Left at Zig's Debug default (`.full`), it pulls in `ubsan_rt.zig`'s f128 reporting path, which the freestanding soft-float x86-64 backend cannot codegen. The same rule applies to `build/App.zig` (see `docs/verification-and-ci.md` §6).
