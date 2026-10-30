---
paths:
  - "src/architecture/arm/**"
  - "docs/aarch64-port.md"
---

# AArch64-specific constraints

## Open: garbage saved context on a 512 MiB arm guest

`PANIC - arm64: exception: current-EL SP_EL1 synchronous` (ESR `0x8600000f`, `ELR == FAR` inside the early kernel heap, `X30 == ELR`) from `switchTask` resuming a task whose saved callee-saved area is not a real context. Triggered only by raising the arm test guest from 256 to 512 MiB (about 2 in 6 boots). Cause unknown. **Mitigation: arm test boots stay at 256 MiB** (`QEMU.zig`'s per-arch switch). Repro: set 512 and run `zig build test_arm` 3 to 6 times; extend `vectors.zig`'s `dumpAndPanic` to print `x29`/`x30`/`x0`. Details: `docs/bug-archive.md`.

## Open: concurrent spawns

- The second of two back-to-back spawns fails on arm with `loadAndJump failed: BadAddress` (2 of 2). Not root-caused. x64 is probabilistic under host load.
- Gated in `testing/integration.test.zig` (`if (true) return error.SkipZigTest`): the two single-shot tests that spawn a second process before waiting on the first, and the 20-cycle spawn/kill loop. Un-gating the loop on x64 hung twice (2026-09-26); it was re-gated. Re-gate nothing else, un-gate when fixed.
- A genuine kernel panic during a QEMU test boot has no host-side watchdog: the guest halts and `zig build` hangs until killed.

## Process reference accounting (invariant)

`create()` +1, `createThread()` +1, `spawnFromInitfs`'s own `defer` -1, `TaskCleanup` -1 when the thread is destroyed. Never add another decrement on a load-failure path (`loadAndStart` once did, double-dropping the reference on every failed load: refcount wrap, use-after-free, leaked process). Regression: `integration: a spawn whose ELF fails to load ends cleanly and leaves its process slot reusable`.

## EL0 synchronous exceptions: SVC dispatch and fault isolation — IMPLEMENTED (was Phase 3 Stage 9)

Previously: `vectors.zig`'s `arm_handle_exception` dispatched purely on
`vector_idx`, never on `ESR_EL1`'s Exception Class field, so vector 8
("lower-EL AArch64 synchronous" — where the CPU sends *every* EL0
synchronous exception: SVC, data aborts, instruction aborts, undefined
instructions) always fell through to an unconditional `@panic()` for
anything that wasn't a recognized data abort.

**Now**: `arm_handle_exception`'s `4, 8` case decodes `ESR_EL1.EC`
(`EsrEl1.ExceptionClass` gained `svc_aarch64 = 0x15` and
`unknown_reason = 0x00` alongside the existing two data-abort tags) and
routes:
- `.svc_aarch64` from vector 8 → `handleSvc`: builds an `arm.SyscallFrame`
  from the already-saved `InterruptFrame`'s GPRs, calls the generic
  `innigkeit.user.onSyscall` (the same entry point x64's `syscallDispatch`
  uses), writes the result back. Deliberately does **not** call
  `onInterruptEntry`/`onInterruptExit` the way the IRQ/data-abort branches
  do — `onSyscall` asserts `interrupt_disable_count == 0` on entry, which
  `onInterruptEntry`'s bump would violate; this mirrors how x64's own
  `syscall` path bypasses its IDT/interrupt machinery entirely.
- Anything else from vector 8 (illegal instruction, alignment fault, an
  undecoded EC) → `handleUserFault`: isolates to the calling process via
  `process.terminateCallingThread(...)` instead of panicking, using a
  local `exceptionDisposition(ec) u8` mapping (`.unknown_reason` → sigill,
  everything else → the safe default sigsegv — non-exhaustive, so an EC
  nobody named explicitly still isolates rather than panics or hits
  `unreachable`, matching x64's `exceptionDisposition()` *philosophy*,
  not its shared type — arm's stays local to `vectors.zig`).
- The same exceptions from vector 4 (kernel-mode) still always panic —
  no isolation without a calling user process. An SVC from vector 4 (the
  kernel itself executing `svc`) is treated as a bug, not dispatched.

Both `testing/integration.test.zig` tests (`itest_spawn_wait`,
`itest_illegal_instruction`) now run on aarch64 (still `SkipZigTest`-gated
on riscv64, which has no syscall dispatch of its own yet). Verified via a
real `zig build verify -Darm=true -Dtpm=true` run, not just a clean
compile — the illegal-instruction test's log line confirms the isolate
path actually fires: `unhandled user-mode exception ec=unknown_reason,
killing process (exit status 132)`.

**What's still approximate**: only `unknown_reason` maps to a specific
signal; every other undecoded `ESR.EC` (alignment faults, instruction
aborts, etc.) isolates via the generic `sigsegv` default rather than a
precisely name-matched one. Add more named `ExceptionClass` tags (and
`exceptionDisposition` arms) as something actually exercises them —
this was a deliberate "don't preemptively name ECs nothing tests yet"
call, not an oversight.

**Also fixed in the same pass, unrelated but blocking**: `drivers/virtio/gpu.zig` had
three bare `asm volatile ("mfence" ...)` and one `asm volatile ("sfence" ...)`
calls with no arch guard at all — a pre-existing x86-64-only bug, invisible
until arm's syscall dispatch (now real) made `syscalls.dispatch()`'s
generated table actually reach this driver's code for the first time on an
arm build. Fixed with a `deviceBarrier()` helper mirroring
`drivers/tpm/crb.zig`'s existing per-arch pattern (`mfence` / `dsb sy` /
plain compiler barrier). Same "Zig's lazy analysis hides bugs in
never-reached code" lesson this project has hit repeatedly, this time for
inline asm specifically — caught by `build_all`, not `check` (which never
validates asm).

## `test` blocks written directly inside `src/architecture/{x64,arm}/*.zig` never run (Phase 3 Stage 9)

Confirmed by direct experiment: a `test` block added to `arm/timer.zig`
never appeared in the `test_arm` serial log, and a pre-existing `test` block
in `x64/registers/Cr4.zig` (`"cr4: SMEP is enforced..."`/`"cr4: SMAP is
enforced..."`) never appeared in the `test_x64` log either — both silently
dead. Root cause (documented at the top of `testing/syscall_frame.test.zig`,
which already works around it): the kernel test binary's root module is
`innigkeit`, and `architecture` is a *separate* Zig module `innigkeit`
imports — Zig's test-block collection only walks the root module's own file
graph, never a dependency module's. The `Cr4.zig` tests were fully redundant
with already-passing tests in `testing/security.test.zig` anyway, so they
were deleted rather than moved. **The fix for any future arch-specific
test**: put it under `src/innigkeit/testing/*.test.zig` (referenced from
`testing/root.zig`'s comptime import list) and reach the arch-specific
behavior through `architecture.current_decls`/`architecture.current_functions`
(the generic interface), exactly like `syscall_frame.test.zig` does — not as
an inline `test` block next to the arch code itself, no matter how natural
that placement looks.
