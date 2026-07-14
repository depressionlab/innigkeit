# TODO review: full dedicated pass (2026-07-09)

This is not a "close every TODO" pass. Most TODOs in an early-stage
OS kernel correctly describe real, not-yet-implemented work — the
useful output of a review is separating "real, already-scoped,
correctly-deferred work" from "actually fixable now" and "stale/wrong,
should be corrected," not manufacturing artificial urgency around
every marker.

## Fixed this pass (5)

- **`src/innigkeit/task/sched/Eevdf.zig`** — a whole test was commented
  out (`// TODO: fix these test errors`) with a wrong hand-calculated
  expected value: `calcDeltaFair(1_000_000, 88761)` is **11536**, not
  the disabled test's `11540` (confirmed via direct calculation:
  `1_000_000 * 1024 / 88761 = 11536` integer division). The sibling
  "light task" test's expected value was already correct. Fixed the
  constant and re-enabled both tests.
- **`src/innigkeit/task/Stack.zig:33`** — replaced `// TODO: are these
  two checks needed as we don't use SIMD?` with the actual answer:
  16-byte stack alignment is a SysV AMD64 / AAPCS64 **ABI** requirement
  on both supported architectures, not a SIMD-only concern. The asserts
  were already correctly verifying the function's own documented
  precondition; the TODO's premise (SIMD-only) was just wrong.
- **`src/innigkeit/memory/arena/Arena.zig:423`** — removed a stale
  self-doubt TODO (`// TODO: is there a better way to handle this?`)
  attached to code that already does the right thing (returns a proper
  typed error, `AllocateError.RequestedLengthUnavailable`, per
  `docs/DESIGN.md`'s "return error sets, not bool"). Nothing left to
  improve; the comment wasn't identifying an actual defect.
- **`src/innigkeit/memory/core/init.zig:12`** — replaced `// TODO: do
  we actually need this to panic? we could just set these to sensible
  values` with the real reasoning: every offset computed downstream
  (virtual/physical offset, direct map) derives from this address, so
  a substituted "sensible" default wouldn't just be imprecise — it
  would silently corrupt the whole memory layout instead of failing at
  the actual problem. The panic is correct; the TODO's suggested
  alternative would have been a regression.
- **`src/innigkeit/memory/address_space/AddressSpace.zig`** (3 sites,
  lines 1142/1151/1159) — replaced `// TODO: why is this @errorCast
  needed?` with the empirically-confirmed answer: `narrow_err`'s
  switch-narrowed type is a bare error set, not an error union, so it
  doesn't coerce into the function's `!void` return on its own even
  though its members are a subset of `HandlePageFaultError`. Confirmed
  by actually removing the cast and rebuilding — `zig build check`
  fails with `expected error union type, found 'error{OutOfMemory}'`.

All five verified with `zig build check`; the Eevdf fix additionally
verified via the real test run (`zig build verify -Darm=true`, see
below).

## Reviewed and correctly left alone: self-documenting stub/deferred clusters

These aren't "not yet triaged" — they're clusters already confirmed
correct-as-is, either by this pass or a prior review stage:

- **`library/filesystem/ext.zig`** (~19 TODOs) — confirmed dead,
  unused, self-documented WIP per `.claude/rules/filesystem-library.md`
  ("Stage 20 found no additional bugs"). Not a target until something
  actually consumes the file.
- **`src/architecture/x64/info/cpu_id.zig:3902-3967`** (40 TODOs) — a
  deliberate catalog of not-yet-decoded CPUID leaves (SGX, PQOS, cache
  topology, etc.), each one line, self-evidently a future-work list
  rather than a bug. No action needed unless a specific leaf is
  actually required by new code.
- **`src/innigkeit/capabilities/types/GpuBuffer.zig`** (2 TODOs,
  single-page alloc/free) — verified consistent and safe: `create()`
  explicitly rejects `page_count > 1` with a comment explaining exactly
  why (a contiguous-allocator gap that would otherwise let GPU access
  past the first page corrupt unrelated physical memory). The two
  TODOs describe genuine future work (a real contiguous-page
  allocator), not a live bug — the unsafe case is already guarded.
- **`src/innigkeit/task/SchedCap.zig`** (4 TODOs) — already documented
  in `.claude/rules/scheduler.md` ("Two Stage 8 cleanup notes") as
  self-documented, not a live path since nothing wires capability-based
  scheduling changes into a syscall handler yet.
- **`build/Kernel.zig:184,213`, `build/QEMU.zig:212,214`** — the
  optimize-mode-tuning and LLVM-backend-forcing TODOs, and the
  arm-single-core-for-now note, are already tracked decisions
  (`docs/verification-and-ci.md` §6, and the arm SMP/M3 milestone
  throughout `docs/roadmap.md`) — genuine design/tuning judgment calls
  or explicitly staged future work, not oversights.
- **`src/innigkeit/memory/address_space/FaultInfo.zig`**'s ~8
  `@panic("NOT IMPLEMENTED")` sites (each tied to a specific OpenBSD
  `uvm_fault.c` line reference) — already reviewed in Phase 2 and
  carries a documented `zlinter-disable-next-line` suppression; a real,
  scoped, known gap (unimplemented VM-fault paths), not a fixable
  one-liner.

## Reviewed, real gaps, correctly deferred (evidence-gated per `docs/DESIGN.md` Part 7)

Grouped by theme rather than one line per site — each of these is a
genuine "not yet done" rather than a bug, and turning any of them into
real work needs either a concrete performance target or a concrete
consumer, neither of which exists yet:

- **Perf/optimization markers with no profiling data behind them**:
  `memory/root.zig:115,184` (two named-but-unimplemented mapping
  optimizations), `memory/cache/RawCache.zig:607` (search vs. closed-form
  slab sizing), `memory/core/FlushRequest.zig:28-29` (broadcast-all vs.
  targeted TLB-shootdown IPI), `memory/heap/AllocatorImplementation.zig:81`
  (resize() could consult arena free-space tracking). Per Part 7, these
  need a named hot path and measurement before they're worth the added
  complexity — appropriately left alone.
- **Feature-incomplete, scoped, low-priority**: `AddressSpace.zig:46`
  (entries stored in a plain `ArrayList`, not yet a better structure),
  `:456,848,889` (free-range tracking / merge-efficiency), `AnonMap.zig`
  (shared anonymous maps unsupported), `memory/page/init.zig:44` (a
  real but currently-unreachable edge case: physical pages beyond
  `u32`'s range on a system with implausibly large RAM).
- **Architecture completeness gaps (arm/riscv secondary/early per
  `CLAUDE.md`'s stated priority order)**: `riscv/interface.zig`,
  `sbi_debug_console.zig` (riscv is explicitly early/unfinished),
  `apic/init.zig:49-50` (task priority / error interrupt not wired),
  `ioapic/root.zig:30,35,56` (single-CPU routing only, panics instead
  of a propagated error), `x64/init/root.zig:337,370,456` (register
  setup thoroughness, PCID, PIT/KVMCLOCK), `x64/paging/PageTable.zig:11,
  46,1305`, `x64/user/root.zig:14-15`. Expected, tracked gaps given
  arm/riscv's stated secondary/early status — not oversights.
- **ACPI/UART completeness**: `acpi/root.zig:3`, `DBG2.zig`, `SPCR.zig`
  (unimplemented debug-port subtypes), `uacpi_kernel_api.zig:411` (a
  dummy event-API stub — uACPI's event API isn't exercised by anything
  yet), `init/output/uart/root.zig` (hardcoded clock-frequency
  assumption, no early-MMIO support yet), `init/output/Output.zig`,
  `framebuffer.zig` (terminal-mode switching, dynamic sizing) — all
  real, low-priority, no live consumer forcing the issue yet.
- **Userspace/library alignment with real Zig `std`** — directly
  relevant to `CLAUDE.md`'s *current* stated focus (std/std.Io stubs):
  `library/innigkeit/entry.zig:6,82` ("align this more with zig's
  standard library: `start.zig`!!!", "make it so we can use
  `std.process.Args`") — worth flagging to the test-expansion/std-support
  initiative rather than fixing standalone here, since it's really
  part of that larger effort, not an isolated TODO.
- **FAT/GPT image-builder assumptions** (`tools/image_builder/fat/*`:
  long-name support, single-cluster-directory assumption, the
  `sectors_per_fat = 0x3f1` magic number, hardcoded `volume_id`) —
  covered by the same reasoning as `.claude/rules/filesystem-library.md`'s
  existing finding: build-time-only, trusted-input tooling, not an
  attacker-facing parser. Real limitations of a minimal FAT writer, not
  bugs.
- **Everything else** (`Endpoint.zig`'s reply-token perf idea,
  `config.zig:49`'s tuning constant, `debug/SelfInfo.zig:277`'s
  debug-info allocator sizing heuristic, `filesystem/root.zig:9`'s VFS
  abstraction gap, `boot/limine/interface.zig:236`'s revision-0
  fallback, `boot/root.zig:63`'s vague "reorganize boot.*",
  `Executor.zig:51`'s panic-buffer generalization, `Process.zig:457`/
  `Thread.zig:233`'s user-controlled-string `format()` TODOs — reviewed,
  not a real injection risk since these feed `std.Io.Writer.print`, not
  a format-string interpreter, just a "should there be a name
  allowlist" design question — `apps/shader_demo`'s RNG wishlist,
  `apps/shell/completions.zig`'s autogeneration wishlist,
  `library/innigkeit-rs/src/sys.rs:52`'s not-yet-wrapped TCP syscalls)
  are each genuine, low-priority, already-scoped future work. Read in
  full; none hide a live bug.

## Not re-litigated

`build/Kernel.zig`'s test-discovery gap (`.claude/rules/build.md`) and
the `SchedClass.pick_next`'s unused `prev` parameter
(`.claude/rules/scheduler.md`) are pre-existing, already-flagged
architectural calls turned up by earlier review stages, not new
findings from this TODO-specific pass — not repeated here.

## Verification

`zig build check` clean after each fix; full gate
(`zig build verify -Darm=true`) run after the batch: x64 148/148, arm
104 passed + 14 skipped — unchanged from baseline, confirming the
Eevdf test re-enable didn't regress anything and the other four fixes
(comment-only or trivial-removal) didn't either.
