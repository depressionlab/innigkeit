---
paths:
  - "build/**"
---

# `build/` invariants

Drafted during Phase 3 Stage 22 (`docs/phase3-review-plan.md`, Tier 4).

## Two build-graph shapes exist for a reason, but one has a real, unaddressed gap

`KernelModule` (`src/root.zig`'s `modules` list: `architecture`, `boot`,
`innigkeit`) and `LibraryDescription` (`library/root.zig`'s `libraries`
list: `core`, `filesystem`, `uuid`, `bitjuggle`, etc.) look similar --
both are declarative, both feed a `resolveComponentGraph`/`getLibraries`
topological-sort pass, but they produce structurally different build
graphs. `Library.resolveLibrary()` (`build/Library.zig`) registers, per
architecture, a dedicated host-runnable test exe wired to
`{name}_host_{arch}` and the aggregate `{name}` step (`zig build core`
really builds and runs `core`'s tests, reporting a pass/fail count).
`Kernel.buildTestKernel()` (`build/Kernel.zig`) has no equivalent per-module
step: it builds one test binary rooted at the `innigkeit` module, and Zig's
`zig test` discovery only walks that module's own relative-import file
tree. Files reached only by crossing into the separate `architecture` or
`boot` `*std.Build.Module` (each with its own `root_source_file`, created
in `configureComponents()`) are invisible to that discovery.

**Confirmed empirically in Stage 21**: `test` blocks added under
`src/boot/limine/*.zig` never appear in the kernel test suite's `test.log`,
and `zig build check` stays clean even with one of those tests' underlying
bugs deliberately reintroduced, `check` doesn't even compile the test
bodies. Neither `test_x64`/`test_arm`'s QEMU-boot suite nor `check` gives
any signal for a `test` block written inside `src/boot/` or
`src/architecture/`.

**This is a real gap, not a false alarm**, but closing it is an
architectural call this pass is deliberately not making unilaterally,
per `docs/DESIGN.md` Part 5 ("genuinely hard calls... get flagged to the
project owner rather than resolved silently"). Two shapes a fix could take,
each with real tradeoffs:

1. **Give `KernelModule` the same per-component host test step
   `LibraryDescription` already has** (mirror `Library.resolveLibrary`'s
   `test_exe`/`{name}_host_{arch}` wiring in `Kernel.zig`'s
   `resolveComponentGraph`/`configureComponents`). Straightforward
   structurally, but `architecture`/`boot` contain freestanding-only code
   (raw arch `asm`, bootloader-protocol structs) that may not build for a
   host target at all the way `core`/`filesystem` do, unclear without
   trying whether `freestanding_only`-style gating (already a
   `LibraryDescription` field) is sufficient or whether real host-target
   stubs would be needed.
2. **Fold `architecture`/`boot`'s test blocks into the existing
   `test_x64`/`test_arm` QEMU-boot suite's discovery** instead of adding a
   host-side step. Keeps one test-discovery story instead of two, but
   requires understanding exactly why `buildTestKernel`'s `zig test`
   invocation doesn't already collect them (root-module-relative import
   walk, not a configurable flag) and whether that's changeable without
   restructuring the module graph itself.

Until one of these lands: **treat any `test` block written inside
`src/boot/` or `src/architecture/` as unverified by any build command
in this repo.** Confirm correctness by direct `zig run`/standalone
reproduction (the technique used throughout Stage 21) rather than trusting
`zig build check` or `zig build verify` to mean anything for that code.

## `Initfs.zig` is dead scaffold, not a bug

`build/Initfs.zig` (9 lines) is entirely commented out: a `getInitfs`
stub that was never finished or wired in. No current caller references it
(initfs archive construction actually happens elsewhere in the tool
pipeline). Left as-is: harmless, self-evidently incomplete, and deleting a
placeholder nobody asked to remove isn't this review's call to make
unilaterally either, flagged here so a future pass doesn't mistake it for
live code.

## Everything else in `build/` reviewed clean

All 23 files read in full this stage: `KernelModule.zig`, `Library.zig`,
`LibraryDescription.zig`, `App.zig`, `AppDescription.zig`, `Tool.zig`,
`ToolDescription.zig`, `RustApp.zig`, `Bundle.zig`, `Options.zig`,
`options/{EmulatorOptions,FilesystemOptions}.zig`, `QEMU.zig`,
`VerdictStep.zig`, `TpmHarness.zig`, `Verify.zig`, `Wrapper.zig`,
`Platform.zig`, `LimineConfigStep.zig`, `ImageManifestStep.zig`,
`ImageStep.zig`, `Kernel.zig`, `Initfs.zig`. No further compile-error-class
or logic bugs found beyond the `Kernel.zig` test-discovery comment (now
corrected to state the gap accurately) and the empty, unreferenced
`QEMUProfiler.zig` (deleted: confirmed zero references anywhere in the
repo, created in a commit titled "testing is broken").
