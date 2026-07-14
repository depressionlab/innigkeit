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

## `sdk/example/`'s `innigkeit_hello` app's build failure — FIXED (2026-07-13), was misdiagnosed as a Zig backend limitation

Building `sdk/example/`'s own worked example used to fail with
`error: failed to select fpext f128 f64` inside `ubsan_rt.zig`/
`std.Io.Writer.print`, under the freestanding soft-float x86_64 target,
and this file previously called it "a Zig compiler backend limitation,
not a bug in `sdk/`'s own code." That framing was wrong. The real cause,
found while root-causing the *identical* symptom in the monorepo's own
`build/App.zig` this session: `sdk/build.zig`'s `createApp()` never set
`sanitize_c` on `app_mod`/`prelude_mod`, so both silently took Zig's
implicit Debug-mode default (`.full`) instead of `.off` — pulling in
`ubsan_rt.zig`'s f128 float-reporting path, which the freestanding
soft-float backend genuinely can't codegen (that specific limitation is
real; the bug was in never avoiding the code path that hits it). Fixed
by setting `sanitize_c = .off` on both modules (`createApp` has no
C-linking capability at all, unlike `build/App.zig`'s `app_module`, so
this is unconditional rather than derived from C-source presence).
Verified: `cd sdk/example && zig build` now compiles `innigkeit_hello`
cleanly, failing only at the codesign step for the expected, unrelated
reason (no local `keys/codesign_private.key` present in this sandbox).
