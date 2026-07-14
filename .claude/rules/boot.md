---
paths:
  - "src/boot/**"
---

# `src/boot/` invariants

Drafted during Phase 3 Stage 21 (`docs/phase3-review-plan.md`, Tier 4).

## Debug `print()`/`format()` helpers are this directory's hot spot — 7 bugs found, all in code nothing calls

Nearly every Limine response wrapper (`limine/*.zig`) carries a `print()`/
`format()` pair purely for human-readable debug dumps. Nothing in the
kernel's actual boot path calls any of them — confirmed by their total
absence from the kernel test suite's `test.log` even after adding tests
that exercise them (see the build-system gap below). This makes them the
least-analyzed code in the whole subsystem, and it showed:

- **`limine/MP.zig`'s `riscv64.MPInfo.format()`** — `self.print(self,
  writer, 0)`, a double-self-argument call (4 args to a 3-parameter
  function) via method-call syntax, which already supplies `self`
  implicitly. Compile error, fixed to `self.print(writer, 0)` matching
  every sibling arch's identical function in the same file.
- **`limine/MP.zig`'s `aarch64.format()` and `loongarch64.format()`** —
  both called `writer.any()`, a method that does not exist on this Zig
  version's `std.Io.Writer` (leftover from an older `std.io.Writer` API
  that had a type-erasure `.any()` — the Zig 0.16 `std.Io.Writer` is
  already non-generic, so there's nothing to erase). Fixed by removing the
  `.any()` call. `loongarch64` is not one of this project's supported
  architectures at all (see `CLAUDE.md`: x86-64/AArch64/RISC-V64 only, no
  loongarch anywhere in `build.zig`/`build/`/`src/architecture/`) — this
  fix can never be exercised by any build this repo actually produces, the
  same "explicitly out of scope" status the plan already gives other
  unsupported targets.
- **`limine/Framebuffer.zig`'s `LimineFramebuffer.format()`** and
  **`limine/EFIMemoryMap.zig`'s `Response.format()`** — the identical
  double-self bug as the `riscv64.MPInfo` one above, in two more files.
  Same fix.
- **`limine/File.zig`'s `print()`** — `if (self.tftp_ipv4 != 0)` compares a
  `[4]u8` array against a scalar integer literal, which Zig does not
  allow (`incompatible types: '[4]u8' and 'comptime_int'`). Fixed with
  `std.mem.allEqual(u8, &self.tftp_ipv4, 0)`, matching the file's own
  correct pattern one line below for UUID zero-checks (`.eql(.nil)`).

**The pattern behind all of it**: `pub inline fn format(...)` bodies are
only semantically analyzed when actually *called*, not when merely
referenced (`_ = &Type.format;` does **not** force body analysis for an
`inline fn` — confirmed empirically: a deliberately-reintroduced bug
compiled cleanly under a bare reference, and only failed once the function
was actually invoked). Every fix above was confirmed real via a standalone
`zig run` reproduction before being applied, and a test that actually
*calls* `.format()` on a constructed instance was added for each fixed
file (`MP.zig`, `Framebuffer.zig`, `EFIMemoryMap.zig`, `File.zig`) —
matching the `library.md`/`core.md` precedent of forcing resolution rather
than trusting a clean `zig build check` to mean anything for code nothing
calls.

## A real, unrelated build-system gap this stage surfaced: `src/boot/`'s (and likely `src/architecture/`'s) own `test` blocks never run

While adding the regression tests above, discovered that none of them
show up in the kernel test suite's `test.log` — not before, not after.
Reintroducing one of the fixed bugs and running `zig build check` again
confirmed it: **`check` doesn't even compile these test bodies**, and
`verify`'s `test_x64`/`test_arm` don't execute them either. `boot` and
`architecture` are registered as `KernelModule`s (`src/root.zig`), a
different build-graph shape from `library/core`/`library/filesystem`/etc.
(`LibraryDescription`s, each of which gets its own dedicated
`zig build <name>` test step — confirmed working for `core` in Stage 19).
No equivalent dedicated test step exists for kernel modules, and their
`test` blocks apparently aren't included in the `test_x64`/`test_arm`
QEMU-boot suite's discovery either (only `innigkeit`-module tests show up
there, per the test.log). The tests added this stage are correct and
*would* catch a regression *if* something made them run — but nothing
currently does. **Flagged as a concrete, high-priority item for Stage 22
(`build/`)**: give `boot`/`architecture` the same per-module test wiring
`core`/`filesystem`/etc. already have, or fold their test blocks into
`test_x64`/`test_arm`'s discovery. Until then, treat any `test` block
written inside `src/boot/` or `src/architecture/` as unverified by CI/the
verify gate — confirm correctness by direct `zig run` reproduction (as
done for every fix in this stage) rather than trusting the test to ever
execute.

## `kernelExecutableFile()`'s null-vs-empty-slice bug is the one fix with real (if narrow) security relevance

`limine/interface.zig`'s `kernelExecutableFile()` returned an empty slice
(`&.{}`) instead of `null` when the bootloader provided no
`executable_file` response — every sibling function in the same file
(`kernelBaseAddress`, `rsdp`, `tpmEventLog`, etc.) correctly does
`orelse return null`. Two real callers exist:
`drivers/tpm/root.zig`'s measured-boot code
(`if (boot.kernelExecutableFile()) |kernel_image| { measure(tpm,
"kernel-image", kernel_image); }`) would silently measure `SHA-256("")`
into PCR 11 instead of correctly detecting "no image available" and
logging a warning — a predictable, attacker-known PCR value standing in
for the real kernel measurement, undermining that one measurement's
purpose. `debug/SelfInfo.zig`'s backtrace-symbolication path would get a
less-informative parse error instead of the intended
`error.MissingDebugInfo`. Fixed by returning `null`, matching every
sibling function. Not covered by a test (this function's behavior depends
on live Limine-bootloader response state that isn't easily constructed in
isolation) — verified by code inspection and cross-referencing both real
call sites, not by execution.

## Stage 15's flagged `stage1.zig`/`cpuDescriptors()` concern is resolved — confirmed safe, not a bug

Stage 15's findings report flagged (but didn't chase, being out of that
stage's file list) whether `boot.cpuDescriptors()`'s reported `count()`
could ever disagree with its actual `next()` iteration count. Now
confirmed safe by construction: `limine/interface.zig`'s
`CpuDescriptorIterator.count()` returns `entries.len`, and `next()`'s
termination check (`index >= entries.len`) derives from the exact same
slice — both read from one shared source of truth, not two independently
tracked counters that could drift. No fix needed.
